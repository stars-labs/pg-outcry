-- Demo liquidity: two house makers so the public demo isn't a dead exchange.
--
-- An evaluator opening the demo to an empty book and a blank chart learns
-- nothing about the engine. This provisions the accounts a market-making bot
-- (scripts/demo-market-maker.mjs) quotes from.
--
-- Both makers are type='MASTER' on purpose. Funding a CUSTOMER entity without a
-- matching chain deposit is exactly what the chain-backed funding enforcement
-- reverses (funding_reconciliation_report flags MASTER->CUSTOMER deposits with no
-- chain_deposit). House liquidity is not customer funding, so typing them as
-- MASTER keeps `select * from reconcile()` and custody_funding_exposure clean.
--
-- Two of them because the engine refuses self-trades
-- (get_potential_self_trade_volume), so one account cannot cross its own quotes.
--
-- This is DEMO liquidity: synthetic, clearly labelled in the UI, and it should
-- not be installed on a venue holding real customer funds.

do $$
declare
  mk text;
  cur text;
begin
  foreach mk in array array['DEMO_MM_A','DEMO_MM_B'] loop
    if not exists (select 1 from app_entity where pub_id = mk) then
      insert into app_entity(pub_id, external_id, type, status)
        values (mk, mk, 'MASTER', 'ACTIVE');
    end if;
    -- cash + base accounts, and an instrument account to quote from
    foreach cur in array array['EUR','BTC'] loop
      begin perform create_currency_account(mk, cur); exception when others then null; end;
    end loop;
    -- instrument_account is not per-pair; it just needs the entity (see engine's
    -- create_app_entity). No helper exists for an already-created entity, so insert.
    if not exists (select 1 from instrument_account ia join app_entity e on e.id = ia.app_entity_id
                   where e.pub_id = mk) then
      insert into instrument_account(app_entity_id) select id from app_entity where pub_id = mk;
    end if;
  end loop;
end $$;

-- Fund the makers from MASTER. These are MASTER->MASTER transfers, so they are
-- issuance moved between house accounts, not customer deposits.
do $$
declare mk text; bal numeric;
begin
  foreach mk in array array['DEMO_MM_A','DEMO_MM_B'] loop
    select coalesce(max(ca.amount),0) into bal
      from currency_account ca join app_entity e on e.id = ca.app_entity_id
      where e.pub_id = mk and ca.currency_name = 'EUR';
    if bal < 100000 then
      perform process_transfer('DEPOSIT','MASTER',500000,'EUR',mk,'demo liquidity','house maker float',null);
    end if;
    select coalesce(max(ca.amount),0) into bal
      from currency_account ca join app_entity e on e.id = ca.app_entity_id
      where e.pub_id = mk and ca.currency_name = 'BTC';
    if bal < 100 then
      perform process_transfer('DEPOSIT','MASTER',500,'BTC',mk,'demo liquidity','house maker float',null);
    end if;
  end loop;
exception when others then
  raise warning 'demo liquidity funding skipped: %', sqlerrm;
end $$;

-- Resolve a maker's instrument account for the bot (service_role only).
create or replace function demo_maker_account(maker_param text)
  returns text
  language sql
  stable
  security definer
  set search_path = public, pg_temp
as $$
  select ia.pub_id
  from instrument_account ia
  join app_entity e on e.id = ia.app_entity_id
  where e.pub_id = maker_param
  limit 1
$$;
revoke execute on function demo_maker_account(text) from public, anon, authenticated;
grant  execute on function demo_maker_account(text) to service_role;
