-- Perpetual futures (pure SQL, MVP) — position-based linear perp, EUR-margined.
-- Open/close a signed position with posted margin, mark-to-market uPnL, periodic
-- funding (pg_cron), and a liquidation monitor (pg_cron). The house (MASTER) is
-- the counterparty/insurance for this MVP. All cash moves via process_transfer so
-- reconciliation holds; perp_position holds the off-ledger position state.
--
-- Mark price: set by an oracle (update_perp_mark, pg_cron) from the spot last
-- trade of the index symbol — or override perp_market.mark_price directly (and via
-- pg_net for a real external index). Numbered >9900 so 9900_lockdown keeps grants.
--
-- SIMPLIFIED vs production: one (netted) position per market, open-from-flat only;
-- liquidation seizes remaining margin at the mark (no partial close / book routing
-- / ADL); funding/PnL settle against the house, not netted long-vs-short.
-- See docs/DERIVATIVES.md.

create table if not exists perp_market (
  symbol            text primary key,        -- e.g. 'BTC-PERP'
  index_symbol      text not null,           -- spot to read for the index, e.g. 'BTC_EUR'
  margin_currency   text not null default 'EUR',
  mark_price        numeric,                 -- set by the oracle / update_perp_mark
  funding_rate      numeric not null default 0,   -- per funding interval (long pays short if >0)
  max_leverage      numeric not null default 10,
  maintenance_ratio numeric not null default 0.05,
  updated_at        timestamptz not null default now()
);
insert into perp_market(symbol, index_symbol) values ('BTC-PERP', 'BTC_EUR') on conflict do nothing;

create table if not exists perp_position (
  app_entity_id bigint not null references app_entity(id) on delete cascade,
  symbol        text   not null references perp_market(symbol),
  size          numeric not null,            -- signed: + long, - short (base units)
  entry_price   numeric not null,
  margin        numeric not null,            -- trader's claim on the margin pool (margin_currency)
  updated_at    timestamptz not null default now(),
  primary key (app_entity_id, symbol),
  check (size <> 0 and margin >= 0)
);

create table if not exists perp_event (
  id bigint generated always as identity primary key,
  app_entity_id bigint, symbol text, kind text,      -- 'liquidation' | 'funding'
  detail jsonb, at timestamptz not null default now()
);

-- oracle: refresh marks from the spot last trade (or set externally / via pg_net)
create or replace function update_perp_mark() returns int
  language plpgsql security definer set search_path = public, pg_temp as $$
declare m perp_market%rowtype; px numeric; n int := 0;
begin
  for m in select * from perp_market loop
    select t.price into px from trade t join instrument i on i.id = t.instrument_id
      where i.name = m.index_symbol order by t.created_at desc limit 1;
    if px is not null then
      update perp_market set mark_price = px, updated_at = now() where symbol = m.symbol; n := n + 1;
    end if;
  end loop;
  return n;
end $$;
do $$ begin perform cron.schedule('update-perp-mark', '10 seconds', 'select update_perp_mark()');
exception when others then null; end $$;

-- open a position from flat: post `margin`, take a signed `size` at the current mark
create or replace function open_perp(symbol_param text, size_param numeric, margin_param numeric) returns json
  language plpgsql security definer set search_path = public, pg_temp as $$
declare eid bigint := current_app_entity_id(); pub text; mk perp_market%rowtype; notional numeric; required numeric;
begin
  if eid is null then raise exception 'not_authenticated'; end if;
  if size_param = 0 or margin_param <= 0 then raise exception 'invalid_size_or_margin'; end if;
  select * into mk from perp_market where symbol = symbol_param;
  if not found then raise exception 'unknown_market: %', symbol_param; end if;
  if mk.mark_price is null then raise exception 'no_mark_price'; end if;
  if exists (select 1 from perp_position where app_entity_id = eid and symbol = symbol_param) then
    raise exception 'position_exists_close_first';
  end if;
  notional := abs(size_param) * mk.mark_price;
  required := notional / mk.max_leverage;
  if margin_param < required - 1e-9 then
    raise exception 'insufficient_margin: need % got %', required, margin_param;
  end if;
  select pub_id into pub from app_entity where id = eid;
  perform process_transfer('WITHDRAWAL', pub, margin_param, mk.margin_currency, 'MASTER', 'perp', 'open margin', null);
  insert into perp_position(app_entity_id, symbol, size, entry_price, margin)
    values (eid, symbol_param, size_param, mk.mark_price, margin_param);
  return json_build_object('symbol', symbol_param, 'size', size_param, 'entry', mk.mark_price,
    'margin', margin_param, 'leverage', round(notional / margin_param, 2));
end $$;

-- close the whole position at the mark, realize PnL, return margin+pnl (clamped ≥0)
create or replace function close_perp(symbol_param text) returns json
  language plpgsql security definer set search_path = public, pg_temp as $$
declare eid bigint := current_app_entity_id(); pub text; mk perp_market%rowtype; pos perp_position%rowtype;
        pnl numeric; payout numeric;
begin
  if eid is null then raise exception 'not_authenticated'; end if;
  select * into mk from perp_market where symbol = symbol_param;
  select * into pos from perp_position where app_entity_id = eid and symbol = symbol_param for update;
  if not found then raise exception 'no_position'; end if;
  pnl := pos.size * (mk.mark_price - pos.entry_price);
  payout := round(greatest(pos.margin + pnl, 0), 2);
  if payout > 0 then
    select pub_id into pub from app_entity where id = eid;
    perform process_transfer('DEPOSIT', 'MASTER', payout, mk.margin_currency, pub, 'perp', 'close payout', null);
  end if;
  delete from perp_position where app_entity_id = eid and symbol = symbol_param;
  return json_build_object('pnl', round(pnl, 2), 'payout', payout);
end $$;

-- funding (pg_cron): long pays short when funding_rate>0; adjusts the margin claim
create or replace function apply_perp_funding() returns int
  language plpgsql security definer set search_path = public, pg_temp as $$
declare p record; mk perp_market%rowtype; pay numeric; n int := 0;
begin
  for p in select * from perp_position loop
    select * into mk from perp_market where symbol = p.symbol;
    if mk.funding_rate = 0 or mk.mark_price is null then continue; end if;
    pay := mk.funding_rate * p.size * mk.mark_price;   -- long (size>0) pays when rate>0
    update perp_position set margin = greatest(margin - pay, 0), updated_at = now()
      where app_entity_id = p.app_entity_id and symbol = p.symbol;
    insert into perp_event(app_entity_id, symbol, kind, detail)
      values (p.app_entity_id, p.symbol, 'funding', jsonb_build_object('rate', mk.funding_rate, 'paid', round(pay,2)));
    n := n + 1;
  end loop;
  return n;
end $$;
do $$ begin perform cron.schedule('apply-perp-funding', '1 hour', 'select apply_perp_funding()');
exception when others then null; end $$;

-- liquidation monitor (pg_cron): seize margin when equity ≤ maintenance
create or replace function check_perp_liquidations() returns int
  language plpgsql security definer set search_path = public, pg_temp as $$
declare p record; mk perp_market%rowtype; equity numeric; maint numeric; n int := 0;
begin
  for p in select * from perp_position loop
    select * into mk from perp_market where symbol = p.symbol;
    if mk.mark_price is null then continue; end if;
    equity := p.margin + p.size * (mk.mark_price - p.entry_price);
    maint  := abs(p.size) * mk.mark_price * mk.maintenance_ratio;
    if equity <= maint then
      delete from perp_position where app_entity_id = p.app_entity_id and symbol = p.symbol;
      insert into perp_event(app_entity_id, symbol, kind, detail)
        values (p.app_entity_id, p.symbol, 'liquidation',
                jsonb_build_object('mark', mk.mark_price, 'equity', round(equity,2)));
      n := n + 1;
    end if;
  end loop;
  return n;
end $$;
do $$ begin perform cron.schedule('check-perp', '15 seconds', 'select check_perp_liquidations()');
exception when others then null; end $$;

-- caller's positions with live uPnL/equity
create or replace view my_perp as
  select p.symbol, p.size, p.entry_price, m.mark_price,
         round(p.size * (m.mark_price - p.entry_price), 2) as upnl,
         p.margin,
         round(p.margin + p.size * (m.mark_price - p.entry_price), 2) as equity
  from perp_position p join perp_market m on m.symbol = p.symbol
  where p.app_entity_id = current_app_entity_id();
alter view my_perp set (security_invoker = on);
create or replace view perp_markets as
  select symbol, index_symbol, margin_currency, mark_price, funding_rate, max_leverage, maintenance_ratio from perp_market;

alter table perp_position enable row level security;
drop policy if exists own_perp on perp_position;
create policy own_perp on perp_position for select to authenticated
  using (app_entity_id = current_app_entity_id());

grant select on my_perp, perp_markets to anon, authenticated;
grant execute on function open_perp(text,numeric,numeric), close_perp(text) to authenticated;
grant execute on function update_perp_mark(), apply_perp_funding(), check_perp_liquidations() to service_role;
revoke execute on function open_perp(text,numeric,numeric), close_perp(text) from public, anon;
revoke execute on function update_perp_mark(), apply_perp_funding(), check_perp_liquidations() from public, anon, authenticated;
