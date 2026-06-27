-- In-database deposit watching (pure Postgres, no external gateway).
--
-- Deposits can be credited entirely in-DB: a pg_cron job polls a chain RPC/
-- explorer via pg_net and calls credit_chain_deposit() for each confirmed tx to a
-- watched address. THIS migration is the chain-agnostic, fully-tested CORE
-- (config + idempotent credit + confirmation gating + RLS). The per-chain pollers
-- (Sepolia / Tron Nile / Solana testnet) live in supabase/chain/pollers.sql — they
-- need pg_net + pg_cron + a live RPC URL, so they're opt-in, not run in CI/hosted.
--
-- Withdrawals are NOT here: signing needs secp256k1/keccak (a signing extension or
-- external signer). See docs/CHAIN.md.
--
-- Numbered >9900 so 9900_lockdown does not strip grants.

-- per-chain config (RPC url + required confirmations). Disabled until you set rpc_url.
create table if not exists chain (
  name          text primary key,         -- e.g. 'ethereum-sepolia'
  kind          text not null,            -- 'evm' | 'tron' | 'solana'
  rpc_url       text,
  confirmations int  not null default 12,
  enabled       boolean not null default false
);
insert into chain(name, kind, confirmations) values
  ('ethereum-sepolia', 'evm',    12),
  ('tron-nile',        'tron',   19),
  ('solana-testnet',   'solana', 32)
on conflict do nothing;

-- map an on-chain asset to an exchange currency (token = 'native' or a contract/mint)
create table if not exists chain_asset (
  chain    text not null references chain(name) on delete cascade,
  token    text not null,                 -- 'native' or contract/mint address (lowercased)
  currency text not null,                 -- exchange currency, e.g. 'EUR' (demo) / 'ETH'
  decimals int  not null default 18,
  primary key (chain, token)
);

-- addresses we watch for incoming deposits, owned by an entity
create table if not exists watched_address (
  id            bigint generated always as identity primary key,
  app_entity_id bigint not null references app_entity(id) on delete cascade,
  chain         text   not null references chain(name) on delete cascade,
  address       text   not null,
  created_at    timestamptz not null default now(),
  unique (chain, address)
);
create index if not exists watched_address_entity_idx on watched_address(app_entity_id);

-- per-chain scan progress (block height / slot)
create table if not exists chain_cursor (
  chain        text primary key references chain(name) on delete cascade,
  last_scanned numeric not null default 0
);

-- observed deposits, idempotent by (chain, txid, log_index)
create table if not exists chain_deposit (
  id            bigint generated always as identity primary key,
  chain         text   not null references chain(name) on delete cascade,
  txid          text   not null,
  log_index     int    not null default 0,
  address       text   not null,
  currency      text   not null,
  amount        numeric not null check (amount > 0),
  confirmations int    not null default 0,
  credited_at   timestamptz,
  created_at    timestamptz not null default now(),
  unique (chain, txid, log_index)
);

-- user registers an address they will deposit to (for chains where the user holds
-- their own wallet; HD-derived addresses can instead be inserted by an operator).
create or replace function register_deposit_address(chain_param text, address_param text)
  returns json language plpgsql security definer set search_path = public, pg_temp
as $$
declare eid bigint := current_app_entity_id();
begin
  if eid is null then raise exception 'not_authenticated'; end if;
  if not exists (select 1 from chain where name = chain_param) then raise exception 'unknown_chain'; end if;
  if coalesce(trim(address_param),'') = '' then raise exception 'address_required'; end if;
  insert into watched_address(app_entity_id, chain, address)
    values (eid, chain_param, address_param)
    on conflict (chain, address) do nothing;
  return json_build_object('chain', chain_param, 'address', address_param, 'watching', true);
end $$;

-- CORE: idempotently record + (once confirmed) credit a chain deposit. Called by
-- the pollers; service_role only. Credits as a DEPOSIT transfer from MASTER, exactly
-- like the manual approve path. Safe under concurrency (row lock via the upsert).
create or replace function credit_chain_deposit(
    chain_param text, txid_param text, log_index_param int,
    address_param text, currency_param text, amount_param numeric, confirmations_param int)
  returns text language plpgsql security definer set search_path = public, pg_temp
as $$
declare owner_eid bigint; owner_pub text; need int; dep chain_deposit%rowtype;
begin
  select app_entity_id into owner_eid from watched_address
    where chain = chain_param and address = address_param;
  if owner_eid is null then return 'unwatched'; end if;
  select confirmations into need from chain where name = chain_param;

  insert into chain_deposit(chain, txid, log_index, address, currency, amount, confirmations)
    values (chain_param, txid_param, log_index_param, address_param, currency_param, amount_param, confirmations_param)
    on conflict (chain, txid, log_index)
      do update set confirmations = excluded.confirmations
    returning * into dep;                       -- row is now locked until commit

  if dep.credited_at is not null then return 'duplicate'; end if;
  if confirmations_param < coalesce(need, 12) then return 'pending'; end if;

  select pub_id into owner_pub from app_entity where id = owner_eid;
  perform process_transfer('DEPOSIT', 'MASTER', amount_param, currency_param, owner_pub,
                           chain_param || ':' || txid_param, 'chain deposit', null);
  update chain_deposit set credited_at = now() where id = dep.id;
  return 'credited';
end $$;

-- own views
create or replace view my_deposit_addresses as
  select chain, address, created_at from watched_address;
alter view my_deposit_addresses set (security_invoker = on);
create or replace view my_chain_deposits as
  select d.chain, d.txid, d.currency, d.amount, d.confirmations, d.credited_at, d.created_at
  from chain_deposit d
  where d.address in (select address from watched_address);  -- RLS on watched_address scopes this
alter view my_chain_deposits set (security_invoker = on);

alter table watched_address enable row level security;
drop policy if exists own_watched_address on watched_address;
create policy own_watched_address on watched_address for select to authenticated
  using (app_entity_id = current_app_entity_id());

grant select on my_deposit_addresses, my_chain_deposits to authenticated;
grant execute on function register_deposit_address(text, text) to authenticated;
grant execute on function credit_chain_deposit(text, text, int, text, text, numeric, int) to service_role;
revoke execute on function register_deposit_address(text, text) from public, anon;
revoke execute on function credit_chain_deposit(text, text, int, text, text, numeric, int) from public, anon, authenticated;
