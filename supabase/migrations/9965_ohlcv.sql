-- Server-side OHLCV (candlestick) datafeed — pure SQL.
--
-- Buckets public trades into open/high/low/close/volume candles for any resolution,
-- so non-WASM clients (TradingView Lightweight Charts, mobile, TradingView UDF later)
-- get real server-computed candles instead of aggregating raw trades client-side.
--
-- Reads the security_invoker `trade_history` view (already anon-readable), so this
-- function runs with the caller's privileges and exposes nothing the caller can't
-- already select. `date_bin` (PG14+) aligns buckets to the epoch so a 60s candle
-- always starts on a whole minute, matching the chart library's timeframe grid.

create or replace function ohlcv(
  p_instrument  text,
  p_resolution  int,                                    -- bucket size in seconds
  p_from        timestamptz default now() - interval '7 days',
  p_to          timestamptz default now()
)
returns table(t bigint, o numeric, h numeric, l numeric, c numeric, v numeric)
language sql
stable
set search_path = public, pg_temp
as $$
  with bucketed as (
    select date_bin(make_interval(secs => greatest(p_resolution, 1)),
                    th.created_at, timestamptz 'epoch') as bucket,
           th.price, th.amount, th.created_at
    from trade_history th
    where th.instrument = p_instrument
      and th.created_at >= p_from
      and th.created_at <= p_to
  )
  select (extract(epoch from bucket))::bigint                      as t,
         (array_agg(price order by created_at,      price))[1]     as o,
         max(price)                                                as h,
         min(price)                                                as l,
         (array_agg(price order by created_at desc, price desc))[1] as c,
         sum(amount)                                               as v
  from bucketed
  group by bucket
  order by bucket
$$;

-- public market data: explicit grant (Supabase auto-grants to anon, but be explicit;
-- this migration is >9900 so 9900_lockdown has already run and won't strip it).
revoke execute on function ohlcv(text, int, timestamptz, timestamptz) from public;
grant  execute on function ohlcv(text, int, timestamptz, timestamptz)
  to anon, authenticated, service_role;

comment on function ohlcv(text, int, timestamptz, timestamptz) is
  'Server-side OHLCV candles from trade_history; resolution in seconds, epoch-aligned.';
