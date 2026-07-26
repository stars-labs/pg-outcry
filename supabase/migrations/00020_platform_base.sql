-- Platform base: engine grants, realtime, seed data, read API
--
-- Squashed from the pre-launch incremental migrations, concatenated in their
-- original apply order (so the resulting schema is identical). Section headers
-- below name the migration each block came from.


-- ══ 00430_grants_security_definer.sql ══════════════════════════════════════════

-- Stage 1: expose the matching engine through PostgREST.
--
-- The engine functions are SECURITY INVOKER by default, so a PostgREST call as
-- the `anon` role would hit the tables with no privileges. For local
-- verification we run every engine function as SECURITY DEFINER (owner = the
-- migration role, which owns the tables) with a pinned search_path, and grant
-- EXECUTE to the API roles. RLS + per-user ownership is Stage 3, not this stage.

do $$
declare
  fn record;
begin
  for fn in
    select n.nspname, p.proname,
           pg_get_function_identity_arguments(p.oid) as args
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.prokind = 'f'
  loop
    execute format(
      'alter function %I.%I(%s) security definer set search_path = public, pg_temp',
      fn.nspname, fn.proname, fn.args);
    execute format(
      'grant execute on function %I.%I(%s) to anon, authenticated',
      fn.nspname, fn.proname, fn.args);
  end loop;
end $$;


-- ══ 00440_realtime.sql ══════════════════════════════════════════

-- Stage 1: drive the client feed with supabase-realtime instead of a Go relay.
--
-- The engine has no pg_notify today; here we publish the relevant tables to the
-- `supabase_realtime` publication so Realtime's Postgres Changes broadcasts every
-- new trade / order-book row over websockets. RLS stays off for this stage, so
-- the changes are public and easy to observe.

alter publication supabase_realtime add table trade;
alter publication supabase_realtime add table trade_order;
alter publication supabase_realtime add table book_order;

-- emit full row images on update/delete too (handy when watching the book)
alter table trade replica identity full;
alter table trade_order replica identity full;
alter table book_order replica identity full;


-- ══ 00450_seed_dev.sql ══════════════════════════════════════════

-- Stage 1 seed (adapted from open-outcry pkg/conf/seeds_dev.sql).
-- Currencies, the MASTER funding entity, and two instruments.

INSERT INTO currency(name, precision)
VALUES ('EUR', 2),
       ('USD', 2),
       ('BTC', 5);

INSERT INTO app_entity (pub_id, external_id, type)
VALUES ('MASTER', 'MASTER', 'MASTER');

-- MASTER needs accounts for every currency it funds clients with
SELECT create_currency_account('MASTER', 'EUR');
SELECT create_currency_account('MASTER', 'BTC');

INSERT INTO instrument(name, base_currency, quote_currency, fx_instrument)
VALUES ('BTC_EUR', 'BTC', 'EUR', TRUE);

INSERT INTO instrument(name, quote_currency)
VALUES ('SPX', 'EUR');


-- ══ 00460_api_helpers.sql ══════════════════════════════════════════

-- Stage 1: read access + small convenience RPCs so the whole flow is
-- drivable through PostgREST. RLS / per-user scoping is Stage 3.

grant usage on schema public to anon, authenticated;
grant select on all tables in schema public to anon, authenticated;
alter default privileges in schema public
  grant select on tables to anon, authenticated;

-- Resolve an external client id to its instrument-account pub_id (the handle
-- process_trade_order expects). SECURITY DEFINER so it can read the tables.
create or replace function find_instrument_account(external_id_param text)
  returns text
  language sql
  security definer
  set search_path = public, pg_temp
as $$
  select ia.pub_id
  from instrument_account ia
  join app_entity ae on ae.id = ia.app_entity_id
  where ae.external_id = external_id_param
  limit 1;
$$;

grant execute on function find_instrument_account(text) to anon, authenticated;


-- ══ 00470_stage2_concurrency_and_reads.sql ══════════════════════════════════════════

-- Stage 2 (part 1): concurrency safety + read API.
--
-- The original engine relied on the Go layer opening a SERIALIZABLE transaction
-- per call. PostgREST runs each RPC in its own (READ COMMITTED) transaction and
-- does NOT retry serialization failures, so we serialize matching per instrument
-- with a transaction-scoped advisory lock. Same-instrument orders queue; other
-- instruments stay fully parallel.

create or replace function submit_order(
    instrument_account_id_param text,
    instrument_name_param       text,
    order_type_param            text,
    side_param                  order_side,
    price_param                 numeric,
    amount_param                numeric,
    time_in_force_param         text
  )
  returns text                       -- taker trade_order pub_id
  language plpgsql
  security definer
  set search_path = public, pg_temp
as $$
declare
  iid bigint;
begin
  select id into iid from instrument where name = instrument_name_param;
  if iid is null then
    raise exception 'instrument_not_found: %', instrument_name_param;
  end if;
  perform pg_advisory_xact_lock(iid);  -- serialize matching for this instrument
  return process_trade_order(
    instrument_account_id_param, instrument_name_param, order_type_param,
    side_param, price_param, amount_param, time_in_force_param, 0);
end $$;

create or replace function submit_cancel(trade_order_id_param text)
  returns void
  language plpgsql
  security definer
  set search_path = public, pg_temp
as $$
declare
  iid bigint;
begin
  select instrument_id into iid from trade_order where pub_id = trade_order_id_param;
  if iid is null then
    raise exception 'trade_order_not_found: %', trade_order_id_param;
  end if;
  perform pg_advisory_xact_lock(iid);
  perform cancel_trade_order(trade_order_id_param);
end $$;

grant execute on function submit_order(text,text,text,order_side,numeric,numeric,text) to anon, authenticated;
grant execute on function submit_cancel(text) to anon, authenticated;

-- ---------------------------------------------------------------------------
-- Read API (PostgREST exposes these views automatically). RLS scoping = Stage 3.

-- L2 order book: aggregated resting volume per price level.
create or replace view order_book_l2 as
  select i.name as instrument, pl.side, pl.price, pl.volume
  from price_level pl
  join instrument i on i.id = pl.instrument_id
  where pl.volume > 0;

-- Open / working orders.
create or replace view open_orders as
  select o.pub_id, ia.pub_id as instrument_account, i.name as instrument,
         o.side, o.order_type, o.time_in_force, o.price, o.amount, o.open_amount,
         o.status, o.created_at
  from trade_order o
  join instrument i on i.id = o.instrument_id
  join instrument_account ia on ia.id = o.instrument_account_id
  where o.status in ('OPEN','PARTIALLY_FILLED');

-- Public trade tape.
create or replace view trade_history as
  select t.pub_id, i.name as instrument, t.price, t.amount, t.created_at
  from trade t
  join instrument i on i.id = t.instrument_id;

-- Cash balances per entity (available vs reserved).
create or replace view cash_balances as
  select ae.pub_id as app_entity, ca.currency_name as currency,
         ca.amount, ca.amount_reserved,
         (ca.amount - ca.amount_reserved) as available
  from currency_account ca
  join app_entity ae on ae.id = ca.app_entity_id;

-- Instrument (base-asset) holdings per entity.
create or replace view instrument_balances as
  select ae.pub_id as app_entity, i.name as instrument,
         h.amount, h.amount_reserved,
         (h.amount - h.amount_reserved) as available
  from instrument_account_holding h
  join instrument_account ia on ia.id = h.instrument_account
  join app_entity ae on ae.id = ia.app_entity_id
  join instrument i on i.id = h.instrument_id;

grant select on order_book_l2, open_orders, trade_history, cash_balances, instrument_balances
  to anon, authenticated;


-- ══ 00480_realtime_marketdata.sql ══════════════════════════════════════════

-- Stage 2 (part 2): public market-data push.
-- price_level is the aggregated L2 book; streaming it gives clients live
-- order-book updates without replaying every raw book_order row.

alter publication supabase_realtime add table price_level;
alter table price_level replica identity full;
