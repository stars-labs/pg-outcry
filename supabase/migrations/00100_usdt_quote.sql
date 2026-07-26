-- Quote everything in USDT.
--
-- The venue previously quoted in EUR (BTC_EUR, USDC_EUR, USDT_EUR) and used EUR as
-- the numeraire for margin and perps. A crypto venue quotes in a stablecoin, so
-- USDT becomes both the quote currency and the valuation unit, and the EUR-quoted
-- pairs are retired.
--
-- Pre-launch change: existing EUR balances and BTC_EUR trade history are left in
-- place (disabling an instrument keeps its trades referencable) but EUR is no
-- longer quoted, valued, or offered.

-- ── the pair ────────────────────────────────────────────────────────────────
insert into instrument (name, base_currency, quote_currency, fx_instrument)
values ('BTC_USDT', 'BTC', 'USDT', true)
on conflict (name) do nothing;

-- retire the EUR-quoted pairs (keep the rows so historical trades still resolve)
update instrument set enabled = false where quote_currency = 'EUR';
update instrument set enabled = true  where name = 'BTC_USDT';

-- pre-trade risk limits for the new pair, mirroring what BTC_EUR had
insert into instrument_risk (instrument_id, max_order_amount, max_order_notional, price_band_pct)
select i.id, 100, 100000, 10 from instrument i where i.name = 'BTC_USDT'
on conflict (instrument_id) do nothing;

-- ── USDT as the valuation unit ──────────────────────────────────────────────
-- value of 1 unit of `cur` in USDT (USDT=1; else last trade of <cur>_USDT; else 0)
create or replace function _margin_price(cur text) returns numeric
  language sql stable security definer set search_path = public, pg_temp as $$
  select case when cur = 'USDT' then 1
    else coalesce((select t.price from trade t join instrument i on i.id = t.instrument_id
                   where i.name = cur || '_USDT' order by t.created_at desc limit 1), 0) end;
$$;

alter table perp_market alter column margin_currency set default 'USDT';
update perp_market set margin_currency = 'USDT', index_symbol = 'BTC_USDT'
 where index_symbol = 'BTC_EUR' or margin_currency = 'EUR';

-- ── USDT wherever EUR was the default cash currency ─────────────────────────
insert into withdrawal_limit (currency, window_hours, max_amount) values ('USDT', 24, 50000)
on conflict (currency) do nothing;
insert into stake_pool (currency, apr) values ('USDT', 0.10)
on conflict (currency) do nothing;

do $$ begin perform create_currency_account('MASTER', 'USDT'); exception when others then null; end $$;

-- house makers quote the new pair, so they need USDT float
do $$
declare mk text; bal numeric;
begin
  foreach mk in array array['DEMO_MM_A','DEMO_MM_B'] loop
    if exists (select 1 from app_entity where pub_id = mk) then
      begin perform create_currency_account(mk, 'USDT'); exception when others then null; end;
      select coalesce(max(ca.amount),0) into bal
        from currency_account ca join app_entity e on e.id = ca.app_entity_id
        where e.pub_id = mk and ca.currency_name = 'USDT';
      if bal < 100000 then
        perform process_transfer('DEPOSIT','MASTER',500000,'USDT',mk,'demo liquidity','house maker float',null);
      end if;
    end if;
  end loop;
exception when others then
  raise warning 'USDT maker float skipped: %', sqlerrm;
end $$;
