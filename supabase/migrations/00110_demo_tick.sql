-- Keep the demo alive without an external process.
--
-- scripts/demo-market-maker.mjs needs someone to run it; the moment it stops the
-- demo goes quiet again (the public demo had gone a month without a trade). This
-- is the same logic as an in-DB function on pg_cron, so the book, tape and candles
-- keep moving on their own.
--
-- DEMO ONLY. Synthetic liquidity between two house (type='MASTER') accounts — see
-- 00090. Do not schedule this on a venue holding real customer funds.

create or replace function demo_market_tick()
  returns int
  language plpgsql
  security definer
  set search_path = public, pg_temp
as $$
declare
  A text; B text; m numeric; i int; n int := 0; sym text := 'BTC_USDT';
begin
  select demo_maker_account('DEMO_MM_A') into A;
  select demo_maker_account('DEMO_MM_B') into B;
  if A is null or B is null then return 0; end if;

  -- Requote means cancel-then-place. Without this every tick's resting orders
  -- stack up and their reservations eat the makers' balance until quoting fails
  -- with insufficient_funds (which is exactly what happened on the demo).
  perform demo_market_prune();

  -- walk from the last print, or start at a plausible BTC level
  select coalesce((select t.price from trade t join instrument i on i.id = t.instrument_id
                   where i.name = sym order by t.created_at desc limit 1), 64000) into m;

  for i in 1..3 loop
    m := m * (1 + (random() - 0.5) * 0.003);
    -- two-sided depth
    perform submit_orders(A, sym, jsonb_build_array(
      jsonb_build_object('type','LIMIT','side','BUY','price',round(m*0.9992,2),'amount',0.05,'tif','GTC'),
      jsonb_build_object('type','LIMIT','side','BUY','price',round(m*0.9980,2),'amount',0.09,'tif','GTC'),
      jsonb_build_object('type','LIMIT','side','BUY','price',round(m*0.9965,2),'amount',0.14,'tif','GTC')));
    perform submit_orders(B, sym, jsonb_build_array(
      jsonb_build_object('type','LIMIT','side','SELL','price',round(m*1.0008,2),'amount',0.05,'tif','GTC'),
      jsonb_build_object('type','LIMIT','side','SELL','price',round(m*1.0020,2),'amount',0.09,'tif','GTC'),
      jsonb_build_object('type','LIMIT','side','SELL','price',round(m*1.0035,2),'amount',0.14,'tif','GTC')));
    -- cross to print a trade
    if random() < 0.8 then
      if random() < 0.5 then
        perform submit_orders(A, sym, jsonb_build_array(jsonb_build_object(
          'type','LIMIT','side','BUY','price',round(m*1.0009,2),
          'amount',round((0.01 + random()*0.05)::numeric,5),'tif','IOC')));
      else
        perform submit_orders(B, sym, jsonb_build_array(jsonb_build_object(
          'type','LIMIT','side','SELL','price',round(m*0.9991,2),
          'amount',round((0.01 + random()*0.05)::numeric,5),'tif','IOC')));
      end if;
      n := n + 1;
    end if;
  end loop;
  return n;
exception when others then
  raise warning 'demo_market_tick: %', sqlerrm;
  return 0;
end $$;

revoke execute on function demo_market_tick() from public, anon, authenticated;
grant  execute on function demo_market_tick() to service_role;

-- Cancel the makers' resting orders. Called at the start of every tick (requote)
-- and on its own schedule as a safety net.
create or replace function demo_market_prune()
  returns int
  language plpgsql
  security definer
  set search_path = public, pg_temp
as $$
declare r record; n int := 0;
begin
  for r in
    select o.pub_id from trade_order o
    join instrument_account ia on ia.id = o.instrument_account_id
    join app_entity e on e.id = ia.app_entity_id
    where e.pub_id in ('DEMO_MM_A','DEMO_MM_B')
      and o.status in ('OPEN','PARTIALLY_FILLED')
    limit 500
  loop
    begin perform submit_cancel(r.pub_id); n := n + 1; exception when others then null; end;
  end loop;
  return n;
end $$;
revoke execute on function demo_market_prune() from public, anon, authenticated;
grant  execute on function demo_market_prune() to service_role;

-- Opt-in, NOT scheduled by the migration: synthetic liquidity would otherwise run
-- on every self-host and in CI, where it pollutes tests that assert on trade
-- prices. The public demo turns it on explicitly.
create or replace function demo_enable_liquidity() returns boolean
  language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform cron.schedule('demo-market-tick',  '* * * * *',   'select demo_market_tick()');
  perform cron.schedule('demo-market-prune', '*/10 * * * *','select demo_market_prune()');
  return true;
exception when others then
  raise warning 'demo_enable_liquidity: %', sqlerrm; return false;
end $$;

create or replace function demo_disable_liquidity() returns boolean
  language plpgsql security definer set search_path = public, pg_temp as $$
begin
  begin perform cron.unschedule('demo-market-tick');  exception when others then null; end;
  begin perform cron.unschedule('demo-market-prune'); exception when others then null; end;
  return true;
end $$;

revoke execute on function demo_enable_liquidity(), demo_disable_liquidity() from public, anon, authenticated;
grant  execute on function demo_enable_liquidity(), demo_disable_liquidity() to service_role;

-- a migration re-run must not silently re-arm it
do $$ begin perform cron.unschedule('demo-market-tick');  exception when others then null; end $$;
do $$ begin perform cron.unschedule('demo-market-prune'); exception when others then null; end $$;
