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
