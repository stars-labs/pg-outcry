-- Stage 3 of in-DB custody: native-coin deposit detection, fully in Postgres.
--
-- Model: BALANCE-DELTA. Each tick, for every watched per-user deposit address (from
-- 9985), fetch the on-chain native balance over HTTP (the `http` extension — verified
-- to egress from hosted Supabase) and credit any INCREASE since we last saw it. This
-- is simpler + more robust than log-parsing for native ETH/SOL/TRX sent from an
-- injected wallet, and uniform across chains. (The token log-pollers in
-- supabase/chain/pollers.sql remain for ERC-20/TRC-20/SPL.)
--
-- Polling only touches chains with chain.enabled = true and a chain.rpc_url set, so
-- this is inert in CI/local (no chain enabled) and live only once configured on hosted
-- via admin_set_chain_config. Numbered >9900 so 9900_lockdown has already run.

create extension if not exists http with schema extensions;

-- hex (no 0x) -> numeric, overflow-safe for 256-bit EVM words (also in pollers.sql).
create or replace function hex_to_numeric(h text) returns numeric
  language sql immutable as $$
  select coalesce(sum(('x' || substr(h, i, 1))::bit(4)::int * power(16::numeric, length(h) - i)), 0)
  from generate_series(1, length(h)) i;
$$;

-- ── pure balance decoders (no network) — unit-testable from fixtures ─────────────
create or replace function decode_evm_balance(resp jsonb) returns numeric
  language sql immutable as $$
  select case when resp->>'result' is null then null
              else hex_to_numeric(substr(resp->>'result', 3)) end;  -- wei
$$;
create or replace function decode_solana_balance(resp jsonb) returns numeric
  language sql immutable as $$ select (resp->'result'->>'value')::numeric; $$;   -- lamports
create or replace function decode_tron_balance(resp jsonb) returns numeric
  language sql immutable as $$ select coalesce((resp->'data'->0->>'balance')::numeric, 0); $$;  -- sun

-- last on-chain balance we have already credited, per (chain,address)
create table if not exists chain_balance_cursor (
  chain        text not null references chain(name),
  address      text not null,
  credited_raw numeric not null default 0,
  updated_at   timestamptz not null default now(),
  primary key (chain, address)
);

-- credit the increase of a watched address's native balance to its owner.
create or replace function credit_balance_delta(chain_param text, address_param text, new_raw numeric)
  returns text language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare owner_eid bigint; owner_pub text; prior numeric; delta_raw numeric; cur text; dec int; amt numeric;
begin
  if new_raw is null then return 'no_data'; end if;
  select app_entity_id into owner_eid from watched_address where chain = chain_param and address = address_param;
  if owner_eid is null then return 'unwatched'; end if;

  select credited_raw into prior from chain_balance_cursor where chain = chain_param and address = address_param;
  prior := coalesce(prior, 0);
  if new_raw <= prior then
    insert into chain_balance_cursor(chain, address, credited_raw) values (chain_param, address_param, new_raw)
      on conflict (chain, address) do update set credited_raw = excluded.credited_raw, updated_at = now();
    return 'no_change';
  end if;

  select currency, decimals into cur, dec from chain_asset where chain = chain_param and token = 'native';
  if cur is null then return 'unmapped'; end if;

  delta_raw := new_raw - prior;
  amt := delta_raw / power(10, dec);
  select pub_id into owner_pub from app_entity where id = owner_eid;
  -- ensure the destination account exists (manual transfers don't auto-create it)
  begin perform create_currency_account(owner_pub, cur); exception when others then null; end;
  perform process_transfer('DEPOSIT', 'MASTER', amt, cur, owner_pub,
            chain_param || ':' || address_param || ':' || new_raw::text, 'chain deposit (balance delta)', null);

  insert into chain_balance_cursor(chain, address, credited_raw) values (chain_param, address_param, new_raw)
    on conflict (chain, address) do update set credited_raw = excluded.credited_raw, updated_at = now();
  return 'credited';
end $$;

-- ── per-kind native-balance pollers (one HTTP call per watched address) ──────────
create or replace function poll_native_evm(chain_param text) returns int
  language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare cfg chain%rowtype; w record; resp jsonb; nb int := 0;
begin
  select * into cfg from chain where name = chain_param and enabled and kind = 'evm' and rpc_url is not null;
  if not found then return 0; end if;
  for w in select address from watched_address where chain = chain_param loop
    resp := (extensions.http_post(cfg.rpc_url,
      jsonb_build_object('jsonrpc','2.0','id',1,'method','eth_getBalance',
        'params', jsonb_build_array(w.address, 'latest'))::text, 'application/json')).content::jsonb;
    if credit_balance_delta(chain_param, w.address, decode_evm_balance(resp)) = 'credited' then nb := nb + 1; end if;
  end loop;
  return nb;
end $$;

create or replace function poll_native_solana(chain_param text) returns int
  language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare cfg chain%rowtype; w record; resp jsonb; nb int := 0;
begin
  select * into cfg from chain where name = chain_param and enabled and kind = 'solana' and rpc_url is not null;
  if not found then return 0; end if;
  for w in select address from watched_address where chain = chain_param loop
    resp := (extensions.http_post(cfg.rpc_url,
      jsonb_build_object('jsonrpc','2.0','id',1,'method','getBalance',
        'params', jsonb_build_array(w.address))::text, 'application/json')).content::jsonb;
    if credit_balance_delta(chain_param, w.address, decode_solana_balance(resp)) = 'credited' then nb := nb + 1; end if;
  end loop;
  return nb;
end $$;

create or replace function poll_native_tron(chain_param text) returns int
  language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare cfg chain%rowtype; w record; resp jsonb; nb int := 0;
begin
  select * into cfg from chain where name = chain_param and enabled and kind = 'tron' and rpc_url is not null;
  if not found then return 0; end if;
  for w in select address from watched_address where chain = chain_param loop
    resp := (extensions.http_get(cfg.rpc_url || '/v1/accounts/' || w.address)).content::jsonb;
    if credit_balance_delta(chain_param, w.address, decode_tron_balance(resp)) = 'credited' then nb := nb + 1; end if;
  end loop;
  return nb;
end $$;

create or replace function poll_native_balances() returns void
  language plpgsql security definer set search_path = public, pg_temp as $$
declare c chain%rowtype;
begin
  for c in select * from chain where enabled and rpc_url is not null loop
    begin
      perform case c.kind when 'evm' then poll_native_evm(c.name)
                          when 'solana' then poll_native_solana(c.name)
                          when 'tron' then poll_native_tron(c.name) end;
    exception when others then
      raise warning 'poll_native % failed: %', c.name, sqlerrm;   -- one bad chain never blocks others
    end;
  end loop;
end $$;

-- map each testnet native coin to an exchange currency (demo: EUR). Configurable via
-- admin_set_chain_asset. Decimals: ETH 18, SOL 9, TRX 6.
insert into chain_asset(chain, token, currency, decimals) values
  ('ethereum-sepolia', 'native', 'EUR', 18),
  ('solana-testnet',   'native', 'EUR', 9),
  ('tron-nile',        'native', 'EUR', 6)
on conflict (chain, token) do nothing;

-- schedule (inert until a chain is enabled with an rpc_url). 30s cadence.
do $$ begin
  perform cron.schedule('poll-native-balances', '30 seconds', 'select poll_native_balances()');
exception when others then null; end $$;

revoke execute on function
  credit_balance_delta(text,text,numeric),
  poll_native_evm(text), poll_native_solana(text), poll_native_tron(text), poll_native_balances()
  from public, anon, authenticated;
grant execute on function
  credit_balance_delta(text,text,numeric),
  poll_native_evm(text), poll_native_solana(text), poll_native_tron(text), poll_native_balances()
  to service_role;
