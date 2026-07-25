-- Referral / affiliate program (pure-SQL).
--
-- OPEX dedicates a whole microservice to this; here it's a few tables + a trigger:
--   * each entity has a referral_code
--   * a new user attributes themselves to a referrer ONCE (set_my_referrer)
--   * an AFTER-INSERT trigger on `trade` accrues commission for the taker's
--     referrer as a referral_earning row (a percentage of traded notional)
--   * an admin RPC pays accrued earnings out as a real ledger transfer from MASTER
--
-- Numbered >9900 so 9900_lockdown does not strip the grants.

create table if not exists referral_code (
  app_entity_id bigint primary key references app_entity(id) on delete cascade,
  code          text unique not null,
  created_at    timestamptz not null default now()
);

create table if not exists referral (
  referred_entity bigint primary key references app_entity(id) on delete cascade,
  referrer_entity bigint not null references app_entity(id) on delete cascade,
  created_at      timestamptz not null default now(),
  check (referred_entity <> referrer_entity)
);
create index if not exists referral_referrer_idx on referral(referrer_entity);

create table if not exists referral_earning (
  id              bigint generated always as identity primary key,
  referrer_entity bigint not null references app_entity(id) on delete cascade,
  referred_entity bigint not null references app_entity(id) on delete cascade,
  trade_id        bigint not null,
  currency        text not null,
  amount          numeric not null check (amount >= 0),
  paid_at         timestamptz,
  created_at      timestamptz not null default now()
);
create index if not exists referral_earning_referrer_idx on referral_earning(referrer_entity) where paid_at is null;

-- commission rate as a fraction of traded notional (quote). Reference default:
-- 2 bps. A production venue would base this on the taker fee instead.
create table if not exists referral_config (
  id smallint primary key default 1 check (id = 1),
  commission_rate numeric not null default 0.0002
);
insert into referral_config(id) values (1) on conflict do nothing;

-- accrue commission for the taker's referrer on every trade
create or replace function accrue_referral_commission() returns trigger
  language plpgsql security definer set search_path = public, pg_temp
as $$
declare taker_eid bigint; ref_eid bigint; quote text; prec int; rate numeric;
begin
  select ia.app_entity_id into taker_eid
    from trade_order o join instrument_account ia on ia.id = o.instrument_account_id
    where o.id = new.taker_order_id;
  if taker_eid is null then return new; end if;

  select referrer_entity into ref_eid from referral where referred_entity = taker_eid;
  if ref_eid is null then return new; end if;

  select i.quote_currency into quote from instrument i where i.id = new.instrument_id;
  select c.precision into prec from currency c where c.name = quote;
  select commission_rate into rate from referral_config where id = 1;

  insert into referral_earning(referrer_entity, referred_entity, trade_id, currency, amount)
    values (ref_eid, taker_eid, new.id, quote,
            banker_round(new.price * new.amount * rate, coalesce(prec, 2)));
  return new;
end $$;

drop trigger if exists trg_referral_commission on trade;
create trigger trg_referral_commission after insert on trade
  for each row execute function accrue_referral_commission();

-- get (creating if absent) the caller's referral code
create or replace function my_referral_code() returns text
  language plpgsql security definer set search_path = public, pg_temp
as $$
declare eid bigint := current_app_entity_id(); c text;
begin
  if eid is null then raise exception 'not_authenticated'; end if;
  select code into c from referral_code where app_entity_id = eid;
  if c is null then
    c := upper(substr(encode(extensions.gen_random_bytes(6), 'hex'), 1, 8));
    insert into referral_code(app_entity_id, code) values (eid, c)
      on conflict (app_entity_id) do update set code = referral_code.code
      returning code into c;
  end if;
  return c;
end $$;

-- one-time attribution to a referrer
create or replace function set_my_referrer(code_param text) returns boolean
  language plpgsql security definer set search_path = public, pg_temp
as $$
declare eid bigint := current_app_entity_id(); ref_eid bigint;
begin
  if eid is null then raise exception 'not_authenticated'; end if;
  if exists (select 1 from referral where referred_entity = eid) then
    raise exception 'referrer_already_set';
  end if;
  select app_entity_id into ref_eid from referral_code where code = upper(code_param);
  if ref_eid is null then raise exception 'invalid_referral_code'; end if;
  if ref_eid = eid then raise exception 'cannot_refer_self'; end if;
  insert into referral(referred_entity, referrer_entity) values (eid, ref_eid);
  return true;
end $$;

-- caller's own referral summary
create or replace view referral_summary as
  select
    ae.id as app_entity_id,
    (select code from referral_code rc where rc.app_entity_id = ae.id) as my_code,
    (select count(*) from referral r where r.referrer_entity = ae.id) as referred_count,
    coalesce((select sum(amount) from referral_earning e
              where e.referrer_entity = ae.id), 0) as total_earned,
    coalesce((select sum(amount) from referral_earning e
              where e.referrer_entity = ae.id and e.paid_at is null), 0) as unpaid_earned
  from app_entity ae
  where ae.id = current_app_entity_id();

-- admin: pay out a referrer's unpaid earnings as a real ledger transfer from MASTER
create or replace function pay_referral_earnings(entity_pub text, currency_param text)
  returns numeric language plpgsql security definer set search_path = public, pg_temp
as $$
declare eid bigint; total numeric;
begin
  select id into eid from app_entity where pub_id = entity_pub;
  if eid is null then raise exception 'entity_not_found'; end if;
  select coalesce(sum(amount), 0) into total from referral_earning
    where referrer_entity = eid and currency = currency_param and paid_at is null;
  if total <= 0 then return 0; end if;
  perform process_transfer('DEPOSIT', 'MASTER', total, currency_param, entity_pub,
                           'referral', 'referral payout', null);
  update referral_earning set paid_at = now()
    where referrer_entity = eid and currency = currency_param and paid_at is null;
  return total;
end $$;

-- RLS: own referral data only
alter table referral_code   enable row level security;
alter table referral        enable row level security;
alter table referral_earning enable row level security;
drop policy if exists own_referral_code on referral_code;
create policy own_referral_code on referral_code for select to authenticated
  using (app_entity_id = current_app_entity_id());
drop policy if exists own_referral on referral;
create policy own_referral on referral for select to authenticated
  using (referrer_entity = current_app_entity_id() or referred_entity = current_app_entity_id());
drop policy if exists own_referral_earning on referral_earning;
create policy own_referral_earning on referral_earning for select to authenticated
  using (referrer_entity = current_app_entity_id());

grant select on referral_summary to authenticated;
grant execute on function my_referral_code(), set_my_referrer(text) to authenticated;
grant execute on function pay_referral_earnings(text, text) to service_role;
-- authenticated-only (revoke the Supabase default anon grant); payout is admin-only
revoke execute on function my_referral_code(), set_my_referrer(text) from public, anon;
revoke execute on function pay_referral_earnings(text, text) from public, anon, authenticated;
