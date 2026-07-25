-- Performance: asynchronous, coalesced market-data fan-out.
--
-- Instead of emitting a Postgres Changes event for every price_level row change
-- (one WS message + logical-decode + FULL replica identity per change), the
-- matching tx only marks the instrument dirty. A ticker calls broadcast_md()
-- which coalesces each dirty book into ONE realtime.send() L2 snapshot on topic
-- md:<symbol>. This moves fan-out off the matching critical path, bounds the
-- message rate, and lets price_level leave the Postgres Changes publication
-- (less WAL). Public data -> private=false (anon may subscribe, no auth).

create table md_dirty (instrument_id bigint primary key references instrument(id));
grant select on md_dirty to service_role;

create or replace function mark_md_dirty() returns trigger
  language plpgsql security definer set search_path = public, pg_temp as $$
begin
  insert into md_dirty(instrument_id) values (coalesce(new.instrument_id, old.instrument_id))
    on conflict do nothing;
  return null;
end $$;

create trigger price_level_dirty
  after insert or update or delete on price_level
  for each row execute function mark_md_dirty();

-- Coalesce every dirty book into one L2 broadcast. Call from a ticker (or pg_cron).
-- SKIP LOCKED so overlapping ticker runs never double-send the same instrument.
create or replace function broadcast_md() returns integer
  language plpgsql security definer set search_path = public, pg_temp as $$
declare r record; bids jsonb; asks jsonb; n int := 0;
begin
  for r in
    select d.instrument_id, i.name
    from md_dirty d join instrument i on i.id = d.instrument_id
    for update of d skip locked
  loop
    select coalesce(jsonb_agg(jsonb_build_object('price', price, 'volume', volume) order by price desc), '[]'::jsonb)
      into bids from (
        select price, volume from price_level
        where instrument_id = r.instrument_id and side = 'BUY' and volume > 0
        order by price desc limit 50) b;
    select coalesce(jsonb_agg(jsonb_build_object('price', price, 'volume', volume) order by price asc), '[]'::jsonb)
      into asks from (
        select price, volume from price_level
        where instrument_id = r.instrument_id and side = 'SELL' and volume > 0
        order by price asc limit 50) a;

    perform realtime.send(
      jsonb_build_object('symbol', r.name, 'bids', bids, 'asks', asks),
      'l2', 'md:' || r.name, false);

    delete from md_dirty where instrument_id = r.instrument_id;
    n := n + 1;
  end loop;
  return n;
end $$;

grant execute on function broadcast_md() to service_role;

-- Public trade tape: also async broadcast. (trade is partitioned, and Postgres
-- Changes does not deliver from partitioned tables, so the tape moves to Broadcast
-- on the same md:<symbol> topic with event 'trade'.) One small message per trade.
create or replace function broadcast_trade() returns trigger
  language plpgsql security definer set search_path = public, pg_temp as $$
declare sym text;
begin
  select name into sym from instrument where id = new.instrument_id;
  perform realtime.send(
    jsonb_build_object('symbol', sym, 'price', new.price, 'amount', new.amount,
                       'pub_id', new.pub_id, 'ts', new.created_at),
    'trade', 'md:' || sym, false);
  return null;
end $$;

create trigger trade_broadcast after insert on trade
  for each row execute function broadcast_trade();

-- both heavy tables now fan out via Broadcast; remove from Postgres Changes
-- (cuts logical-decode WAL + frees them for partitioning).
do $$
begin
  alter publication supabase_realtime drop table price_level;
  alter publication supabase_realtime drop table trade;
exception when others then
  raise notice 'publication drop skipped: %', sqlerrm;
end $$;
