-- Staking (pure SQL) — the first "derivative-ish" feature, reusing the
-- double-entry ledger. Stake a currency, earn rewards (APR) via a reward-per-token
-- accumulator (the MasterChef pattern, settled lazily on each interaction — no
-- accrual cron needed), unstake with an unbonding period processed via pgmq.
--
-- Extensions used: pgmq (unbonding queue) + pg_cron (drain it). Reuses
-- process_transfer for all money movement so reconciliation invariants hold:
--   stake   = WITHDRAWAL user→MASTER  (locks principal; insufficient_funds enforced)
--   reward  = DEPOSIT  MASTER→user    (issuance, like a faucet/referral payout)
--   unbond  = DEPOSIT  MASTER→user    (returns principal after the unbonding delay)
--
-- Numbered >9900 so 9900_lockdown does not strip grants.

create extension if not exists pgmq;
do $$ begin perform pgmq.create('stake_unbonding'); exception when others then null; end $$;

create table if not exists stake_pool (
  currency             text primary key,
  apr                  numeric not null default 0,      -- annual fraction, e.g. 0.10 = 10%
  acc_reward_per_token numeric not null default 0,      -- cumulative reward per 1 unit staked
  total_staked         numeric not null default 0,
  updated_at           timestamptz not null default now()
);
insert into stake_pool(currency, apr) values ('EUR', 0.10), ('BTC', 0.05) on conflict do nothing;

create table if not exists stake_position (
  app_entity_id bigint not null references app_entity(id) on delete cascade,
  currency      text   not null references stake_pool(currency),
  amount        numeric not null default 0 check (amount >= 0),
  reward_debt   numeric not null default 0,             -- amount * acc at last settle
  updated_at    timestamptz not null default now(),
  primary key (app_entity_id, currency)
);

create table if not exists stake_config (id smallint primary key default 1 check (id = 1),
  unbond_seconds int not null default 604800);          -- 7 days
insert into stake_config(id) values (1) on conflict do nothing;

-- advance a pool's accumulator to now() (lazy; reward-per-token = apr/sec * elapsed)
create or replace function _stake_update_pool(cur text) returns numeric
  language plpgsql security definer set search_path = public, pg_temp as $$
declare p stake_pool%rowtype; elapsed numeric;
begin
  select * into p from stake_pool where currency = cur for update;
  if not found then raise exception 'no_stake_pool: %', cur; end if;
  elapsed := extract(epoch from now() - p.updated_at);
  if elapsed > 0 and p.apr > 0 then
    update stake_pool
      set acc_reward_per_token = acc_reward_per_token + (apr / 31557600.0) * elapsed,
          updated_at = now()
      where currency = cur
      returning acc_reward_per_token into p.acc_reward_per_token;
  end if;
  return p.acc_reward_per_token;
end $$;

-- settle a position's pending reward into the user's balance, reset reward_debt
create or replace function _stake_settle(eid bigint, cur text) returns numeric
  language plpgsql security definer set search_path = public, pg_temp as $$
declare acc numeric; pos stake_position%rowtype; pub text; prec int; pending numeric;
begin
  acc := _stake_update_pool(cur);
  select * into pos from stake_position where app_entity_id = eid and currency = cur for update;
  if not found or pos.amount = 0 then return 0; end if;
  select precision into prec from currency where name = cur;
  pending := banker_round(pos.amount * acc - pos.reward_debt, coalesce(prec, 2));
  if pending > 0 then
    select pub_id into pub from app_entity where id = eid;
    perform process_transfer('DEPOSIT', 'MASTER', pending, cur, pub, 'staking', 'stake reward', null);
  end if;
  update stake_position set reward_debt = amount * acc, updated_at = now()
    where app_entity_id = eid and currency = cur;
  return pending;
end $$;

create or replace function stake(currency_param text, amount_param numeric) returns numeric
  language plpgsql security definer set search_path = public, pg_temp as $$
declare eid bigint := current_app_entity_id(); pub text; acc numeric;
begin
  if eid is null then raise exception 'not_authenticated'; end if;
  if amount_param <= 0 then raise exception 'amount_must_be_positive'; end if;
  perform _stake_settle(eid, currency_param);                 -- pay accrued before changing size
  acc := _stake_update_pool(currency_param);
  select pub_id into pub from app_entity where id = eid;
  perform process_transfer('WITHDRAWAL', pub, amount_param, currency_param, 'MASTER', 'staking', 'stake', null);
  insert into stake_position(app_entity_id, currency, amount, reward_debt)
    values (eid, currency_param, amount_param, amount_param * acc)
    on conflict (app_entity_id, currency) do update
      set amount = stake_position.amount + excluded.amount,
          reward_debt = (stake_position.amount + excluded.amount) * acc,
          updated_at = now();
  update stake_pool set total_staked = total_staked + amount_param where currency = currency_param;
  return amount_param;
end $$;

create or replace function claim_stake_rewards(currency_param text) returns numeric
  language plpgsql security definer set search_path = public, pg_temp as $$
declare eid bigint := current_app_entity_id();
begin
  if eid is null then raise exception 'not_authenticated'; end if;
  return _stake_settle(eid, currency_param);
end $$;

-- unstake: settle rewards, reduce position, enqueue the principal for unbonding
create or replace function unstake(currency_param text, amount_param numeric) returns text
  language plpgsql security definer set search_path = public, pg_temp as $$
declare eid bigint := current_app_entity_id(); pos stake_position%rowtype; ub int; pub text;
begin
  if eid is null then raise exception 'not_authenticated'; end if;
  if amount_param <= 0 then raise exception 'amount_must_be_positive'; end if;
  perform _stake_settle(eid, currency_param);
  select * into pos from stake_position where app_entity_id = eid and currency = currency_param for update;
  if not found or pos.amount < amount_param then raise exception 'insufficient_staked'; end if;
  select unbond_seconds into ub from stake_config where id = 1;
  select pub_id into pub from app_entity where id = eid;
  update stake_position set amount = amount - amount_param,
       reward_debt = (amount - amount_param) * _stake_update_pool(currency_param), updated_at = now()
    where app_entity_id = eid and currency = currency_param;
  update stake_pool set total_staked = total_staked - amount_param where currency = currency_param;
  perform pgmq.send('stake_unbonding',
    jsonb_build_object('pub', pub, 'currency', currency_param, 'amount', amount_param), coalesce(ub, 604800));
  return 'unbonding';
end $$;

-- pg_cron drains matured unbonding messages, returning principal to the user
create or replace function process_unbonding() returns int
  language plpgsql security definer set search_path = public, pg_temp as $$
declare m record; n int := 0;
begin
  for m in select * from pgmq.read('stake_unbonding', 30, 100) loop
    perform process_transfer('DEPOSIT', 'MASTER', (m.message->>'amount')::numeric,
              m.message->>'currency', m.message->>'pub', 'staking', 'unbond release', null);
    perform pgmq.delete('stake_unbonding', m.msg_id);
    n := n + 1;
  end loop;
  return n;
end $$;
do $$ begin perform cron.schedule('process-unbonding', '60 seconds', 'select process_unbonding()');
exception when others then null; end $$;

-- caller's own positions (with live pending reward) + public pools
create or replace view my_stakes as
  select sp.currency, sp.amount,
         banker_round(sp.amount * (p.acc_reward_per_token + (p.apr/31557600.0)*extract(epoch from now()-p.updated_at))
                      - sp.reward_debt, 8) as pending_reward,
         p.apr
  from stake_position sp join stake_pool p on p.currency = sp.currency
  where sp.app_entity_id = current_app_entity_id() and sp.amount > 0;
alter view my_stakes set (security_invoker = on);
create or replace view stake_pools as select currency, apr, total_staked from stake_pool;

alter table stake_position enable row level security;
drop policy if exists own_stake on stake_position;
create policy own_stake on stake_position for select to authenticated
  using (app_entity_id = current_app_entity_id());

grant select on my_stakes, stake_pools to anon, authenticated;
grant execute on function stake(text,numeric), unstake(text,numeric), claim_stake_rewards(text) to authenticated;
grant execute on function process_unbonding() to service_role;
revoke execute on function stake(text,numeric), unstake(text,numeric), claim_stake_rewards(text) from public, anon;
revoke execute on function process_unbonding(), _stake_update_pool(text), _stake_settle(bigint,text) from public, anon, authenticated;
