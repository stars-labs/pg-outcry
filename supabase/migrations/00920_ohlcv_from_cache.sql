-- ohlcv() now serves candles from the persistent 1m cache (00880) instead of
-- re-scanning trade history on every call.
--
-- candle_1m is maintained incrementally by refresh_candle_1m() (pg_cron, 1/min),
-- so it can lag by up to a minute. The tail is therefore filled from live trades:
-- cached buckets strictly before the cache's own high-water mark, plus a live
-- aggregate for everything at or after it. That keeps the newest candle correct
-- without rescanning history, and stays correct if cron is paused (the live part
-- simply covers a longer span).
--
-- Resolutions above 60s are rolled up from the 1m base by re-binning, which is
-- exact: a 1m bucket never straddles a coarser bucket boundary (all supported
-- resolutions are multiples of 60 and epoch-aligned).

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
  inst as (
    select i.id from instrument i where i.name = p_instrument
  ),
  -- how far the cache is known to be complete
  hwm as (
    select coalesce(
             date_bin('60 seconds', (select last_created_at from candle_refresh_cursor),
                      timestamptz 'epoch'),
             timestamptz 'epoch') as cached_to
  ),
  -- 1m base rows: cached history, then live trades for the uncached tail
  base as (
    select k.bucket, k.o, k.h, k.l, k.c, k.v
    from candle_1m k, win, hwm, inst
    where k.instrument_id = inst.id
      and k.bucket >= win.t_from and k.bucket <= win.t_to
      and k.bucket < hwm.cached_to
    union all
    select date_bin('60 seconds', th.created_at, timestamptz 'epoch') as bucket,
           (array_agg(th.price order by th.created_at,      th.price))[1],
           max(th.price), min(th.price),
           (array_agg(th.price order by th.created_at desc, th.price desc))[1],
           sum(th.amount)
    from trade_history th, win, hwm
    where th.instrument = p_instrument
      and th.created_at >= greatest(win.t_from, hwm.cached_to)
      and th.created_at <= win.t_to
    group by 1
  ),
  rolled as (
    select date_bin(make_interval(secs => win.res), b.bucket, timestamptz 'epoch') as bucket,
           b.o, b.h, b.l, b.c, b.v, b.bucket as base_bucket
    from base b, win
  )
  select (extract(epoch from bucket))::bigint                        as t,
         (array_agg(o order by base_bucket))[1]                      as o,
         max(h)                                                      as h,
         min(l)                                                      as l,
         (array_agg(c order by base_bucket desc))[1]                 as c,
         sum(v)                                                      as v
  from rolled
  group by bucket
  order by bucket
$$;

comment on function ohlcv(text, int, timestamptz, timestamptz) is
  'Server-side OHLCV candles: 1m cache (candle_1m) rolled up to the requested resolution, with the uncached tail filled from live trades. Resolution allow-listed, window capped at 5000 buckets.';
