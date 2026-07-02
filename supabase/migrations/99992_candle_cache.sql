-- Persistent 1m candle cache (no TimescaleDB on hosted Supabase).
-- refresh_candle_1m() incrementally re-aggregates only the buckets touched by
-- trades since the cursor (idempotent upsert), so ohlcv-style reads can come from
-- a small indexed table instead of rescanning trade history. pg_cron every minute.

create table if not exists candle_1m (
  instrument_id bigint not null,
  bucket        timestamptz not null,
  o numeric not null, h numeric not null, l numeric not null, c numeric not null,
  v numeric not null,
  primary key (instrument_id, bucket)
);
alter table candle_1m enable row level security;
drop policy if exists read_candle_1m on candle_1m;
create policy read_candle_1m on candle_1m
  for select to anon, authenticated using (true);
grant select on candle_1m to anon, authenticated, service_role;

create table if not exists candle_refresh_cursor (
  id boolean primary key default true check (id),
  last_created_at timestamptz not null default 'epoch'
);
insert into candle_refresh_cursor default values on conflict do nothing;

create or replace function refresh_candle_1m()
  returns int
  language plpgsql
  security definer
  set search_path = public, pg_temp
as $$
declare cutoff timestamptz; n int := 0;
begin
  select last_created_at into cutoff from candle_refresh_cursor for update;
  with touched as (
    select distinct t.instrument_id,
           date_bin('60 seconds', t.created_at, timestamptz 'epoch') as bucket
    from trade t where t.created_at > cutoff
  ),
  agg as (
    select t.instrument_id, tc.bucket,
           (array_agg(t.price order by t.created_at,      t.price))[1]      as o,
           max(t.price) as h, min(t.price) as l,
           (array_agg(t.price order by t.created_at desc, t.price desc))[1] as c,
           sum(t.amount) as v
    from touched tc
    join trade t on t.instrument_id = tc.instrument_id
                and t.created_at >= tc.bucket
                and t.created_at <  tc.bucket + interval '60 seconds'
    group by t.instrument_id, tc.bucket
  )
  insert into candle_1m(instrument_id, bucket, o, h, l, c, v)
  select instrument_id, bucket, o, h, l, c, v from agg
  on conflict (instrument_id, bucket) do update
    set o = excluded.o, h = excluded.h, l = excluded.l,
        c = excluded.c, v = excluded.v;
  get diagnostics n = row_count;
  update candle_refresh_cursor
    set last_created_at = coalesce((select max(created_at) from trade), cutoff);
  return n;
end $$;
revoke execute on function refresh_candle_1m() from public, anon, authenticated;
grant execute on function refresh_candle_1m() to service_role;

do $$ begin
  perform cron.unschedule('candle-1m-refresh');
exception when others then null; end $$;
do $$ begin
  perform cron.schedule('candle-1m-refresh', '* * * * *', 'select refresh_candle_1m()');
exception when others then null; end $$;
