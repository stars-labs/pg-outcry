-- Spot margin (pure SQL, MVP) — borrow against collateral, with lazy interest
-- accrual and a liquidation monitor. Cross-margin, valued in the quote currency
-- (EUR) via last trade prices. All money movement reuses process_transfer so
-- reconciliation holds: borrow = DEPOSIT MASTER→user (the house lends), repay =
-- WITHDRAWAL user→MASTER, liquidation = seize collateral → MASTER. The loan is
-- tracked in margin_loan (a liability table, separate from the cash ledger).
--
-- SIMPLIFIED vs production: liquidation is a forced settlement at the mark price
-- (seize collateral, clear debt, shortfall borne by the house) rather than routing
-- a market order through the book; no partial liquidation / insurance fund / ADL.
-- See docs/DERIVATIVES.md. Numbered >9900 so 9900_lockdown keeps grants.

create table if not exists margin_config (
  id smallint primary key default 1 check (id = 1),
  max_leverage      numeric not null default 3,     -- total debt ≤ equity*(L-1)
  maintenance_ratio numeric not null default 0.1,   -- liquidate when equity ≤ debt*ratio
  borrow_apr        numeric not null default 0.10
);
insert into margin_config(id) values (1) on conflict do nothing;

create table if not exists margin_loan (
  app_entity_id bigint not null references app_entity(id) on delete cascade,
  currency      text   not null,
  principal     numeric not null default 0 check (principal >= 0),
  accrued       numeric not null default 0 check (accrued >= 0),
  updated_at    timestamptz not null default now(),
  primary key (app_entity_id, currency)
);

create table if not exists margin_liquidation (
  id bigint generated always as identity primary key,
  app_entity_id bigint not null,
  debt_value numeric, collateral_value numeric, at timestamptz not null default now()
);

-- value of 1 unit of `cur` in the EUR quote (EUR=1; else last trade of <cur>_EUR; else 0)
create or replace function _margin_price(cur text) returns numeric
  language sql stable security definer set search_path = public, pg_temp as $$
  select case when cur = 'EUR' then 1
    else coalesce((select t.price from trade t join instrument i on i.id = t.instrument_id
                   where i.name = cur || '_EUR' order by t.created_at desc limit 1), 0) end;
$$;

-- accrue interest on all of an entity's loans (lazy)
create or replace function _margin_accrue(eid bigint) returns void
  language plpgsql security definer set search_path = public, pg_temp as $$
declare apr numeric;
begin
  select borrow_apr into apr from margin_config where id = 1;
  update margin_loan set
    accrued = accrued + (principal + accrued) * (apr / 31557600.0) * extract(epoch from now() - updated_at),
    updated_at = now()
  where app_entity_id = eid and (principal + accrued) > 0;
end $$;

-- (collateral_value, debt_value, equity) in EUR
create or replace function _margin_state(eid bigint, out collateral numeric, out debt numeric, out equity numeric)
  language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  select coalesce(sum(amount * _margin_price(currency_name)), 0) into collateral
    from currency_account where app_entity_id = eid;
  select coalesce(sum((principal + accrued) * _margin_price(currency)), 0) into debt
    from margin_loan where app_entity_id = eid;
  equity := collateral - debt;
end $$;

create or replace function borrow(currency_param text, amount_param numeric) returns numeric
  language plpgsql security definer set search_path = public, pg_temp as $$
declare eid bigint := current_app_entity_id(); pub text; cfg margin_config%rowtype; st record; addv numeric;
begin
  if eid is null then raise exception 'not_authenticated'; end if;
  if amount_param <= 0 then raise exception 'amount_must_be_positive'; end if;
  select * into cfg from margin_config where id = 1;
  perform _margin_accrue(eid);
  select * into st from _margin_state(eid);
  addv := amount_param * _margin_price(currency_param);
  if addv = 0 then raise exception 'unpriced_currency: %', currency_param; end if;
  -- borrowing leaves equity unchanged (collateral and debt both += addv); cap total debt
  if st.debt + addv > st.equity * (cfg.max_leverage - 1) + 1e-9 then
    raise exception 'exceeds_max_leverage: debt % + new % > equity % * (L-1)', st.debt, addv, st.equity;
  end if;
  select pub_id into pub from app_entity where id = eid;
  begin perform create_currency_account(pub, currency_param); exception when others then null; end;
  perform process_transfer('DEPOSIT', 'MASTER', amount_param, currency_param, pub, 'margin', 'borrow', null);
  insert into margin_loan(app_entity_id, currency, principal) values (eid, currency_param, amount_param)
    on conflict (app_entity_id, currency) do update set principal = margin_loan.principal + excluded.principal;
  return amount_param;
end $$;

create or replace function repay(currency_param text, amount_param numeric) returns numeric
  language plpgsql security definer set search_path = public, pg_temp as $$
declare eid bigint := current_app_entity_id(); pub text; ln margin_loan%rowtype; pay numeric; ca numeric;
begin
  if eid is null then raise exception 'not_authenticated'; end if;
  perform _margin_accrue(eid);
  select * into ln from margin_loan where app_entity_id = eid and currency = currency_param for update;
  if not found then raise exception 'no_loan: %', currency_param; end if;
  select pub_id into pub from app_entity where id = eid;
  select amount - amount_reserved into ca from currency_account where app_entity_id = eid and currency_name = currency_param;
  pay := least(amount_param, ln.principal + ln.accrued, coalesce(ca, 0));
  if pay <= 0 then raise exception 'nothing_to_repay_or_insufficient_balance'; end if;
  perform process_transfer('WITHDRAWAL', pub, pay, currency_param, 'MASTER', 'margin', 'repay', null);
  -- pay interest first, then principal
  if pay >= ln.accrued then
    update margin_loan set principal = principal - (pay - accrued), accrued = 0, updated_at = now()
      where app_entity_id = eid and currency = currency_param;
  else
    update margin_loan set accrued = accrued - pay, updated_at = now()
      where app_entity_id = eid and currency = currency_param;
  end if;
  delete from margin_loan where app_entity_id = eid and currency = currency_param and principal <= 0 and accrued <= 0;
  return pay;
end $$;

-- liquidation monitor (pg_cron): seize collateral of under-margined accounts
create or replace function check_margin_liquidations() returns int
  language plpgsql security definer set search_path = public, pg_temp as $$
declare e bigint; cfg margin_config%rowtype; st record; pub text; c record; n int := 0;
begin
  select * into cfg from margin_config where id = 1;
  for e in select distinct app_entity_id from margin_loan where principal + accrued > 0 loop
    perform _margin_accrue(e);
    select * into st from _margin_state(e);
    if st.debt > 0 and st.equity <= st.debt * cfg.maintenance_ratio then
      select pub_id into pub from app_entity where id = e;
      -- forced settlement at mark: seize all free collateral to the house, clear debt
      for c in select currency_name, amount - amount_reserved as free from currency_account
               where app_entity_id = e and amount - amount_reserved > 0 loop
        perform process_transfer('WITHDRAWAL', pub, c.free, c.currency_name, 'MASTER', 'margin', 'liquidation', null);
      end loop;
      delete from margin_loan where app_entity_id = e;
      insert into margin_liquidation(app_entity_id, debt_value, collateral_value)
        values (e, st.debt, st.collateral);
      n := n + 1;
    end if;
  end loop;
  return n;
end $$;
do $$ begin perform cron.schedule('check-margin', '30 seconds', 'select check_margin_liquidations()');
exception when others then null; end $$;

create or replace view my_margin as
  select l.currency, l.principal, l.accrued, (l.principal + l.accrued) as debt
  from margin_loan l where l.app_entity_id = current_app_entity_id();
alter view my_margin set (security_invoker = on);
create or replace view margin_terms as select max_leverage, maintenance_ratio, borrow_apr from margin_config;

-- caller's account health (collateral / debt / equity in EUR) — auth-callable wrapper
-- around the internal _margin_state (which stays operator-only)
create or replace function my_margin_health(out collateral numeric, out debt numeric, out equity numeric)
  language plpgsql security definer set search_path = public, pg_temp as $$
declare eid bigint := current_app_entity_id();
begin
  if eid is null then raise exception 'not_authenticated'; end if;
  perform _margin_accrue(eid);
  select * into collateral, debt, equity from _margin_state(eid);
end $$;

alter table margin_loan enable row level security;
drop policy if exists own_margin_loan on margin_loan;
create policy own_margin_loan on margin_loan for select to authenticated
  using (app_entity_id = current_app_entity_id());

grant select on my_margin, margin_terms to authenticated;
grant execute on function borrow(text,numeric), repay(text,numeric), my_margin_health() to authenticated;
revoke execute on function my_margin_health() from public, anon;
grant execute on function check_margin_liquidations() to service_role;
revoke execute on function borrow(text,numeric), repay(text,numeric) from public, anon;
revoke execute on function check_margin_liquidations(), _margin_accrue(bigint), _margin_state(bigint), _margin_price(text)
  from public, anon, authenticated;
