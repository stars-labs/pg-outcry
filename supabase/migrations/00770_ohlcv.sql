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
  -- Guardrails (anon-callable): clamp the resolution to a small allow-list (default
  -- 60s if invalid) and bound the window to at most 5000 buckets, so a hostile or
  -- careless caller (e.g. resolution=1 over a year) can't force a huge scan/result.
  with cfg as (
    select case when p_resolution in (60,300,900,1800,3600,14400,86400)
                then p_resolution else 60 end as res,
           least(p_to, now())                 as t_to
  ),
  win as (
    select res, t_to,
           greatest(p_from, t_to - make_interval(secs => res::bigint * 5000)) as t_from
    from cfg
  ),
  bucketed as (
    select date_bin(make_interval(secs => win.res),
                    th.created_at, timestamptz 'epoch') as bucket,
           th.price, th.amount, th.created_at
    from win, trade_history th
    where th.instrument = p_instrument
      and th.created_at >= win.t_from
      and th.created_at <= win.t_to
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

revoke execute on function ohlcv(text, int, timestamptz, timestamptz) from public;
grant  execute on function ohlcv(text, int, timestamptz, timestamptz)
  to anon, authenticated, service_role;

comment on function ohlcv(text, int, timestamptz, timestamptz) is
  'Server-side OHLCV candles from trade_history; resolution allow-listed, window capped at 5000 buckets.';
