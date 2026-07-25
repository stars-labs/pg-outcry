-- Performance: hot-data-in-memory + WAL reduction for the live book.
--
-- book_order and price_level are the live order book — pure derived state,
-- rebuildable from the durable trade_order rows. Make them UNLOGGED: writes skip
-- WAL (big saving on the matching hot path) and the data effectively lives in
-- memory. Trade-off: UNLOGGED tables are TRUNCATEd on crash recovery and are not
-- logically replicated — neither is client-facing on Realtime anymore (L2 is
-- broadcast from price_level reads, the private feed uses trade_order), so this
-- is safe. rebuild_book() reconstructs them after a crash.

-- book_order is not consumed by any Realtime client; drop it so it can be UNLOGGED.
do $$ begin
  alter publication supabase_realtime drop table book_order;
exception when others then null; end $$;

alter table book_order  set unlogged;
alter table price_level set unlogged;

-- Crash recovery: rebuild the in-memory book from durable open orders.
-- Run once on startup after an unclean shutdown (UNLOGGED tables come back empty).
create or replace function rebuild_book()
  returns void language plpgsql security definer set search_path = public, pg_temp
as $$
begin
  truncate book_order;
  delete from price_level;
  insert into book_order (trade_order_id)
    select id from trade_order where status in ('OPEN','PARTIALLY_FILLED');
  insert into price_level (instrument_id, side, price, volume)
    select instrument_id, side, price, sum(open_amount)
    from trade_order
    where status in ('OPEN','PARTIALLY_FILLED')
    group by instrument_id, side, price;
end $$;

grant execute on function rebuild_book() to service_role;
