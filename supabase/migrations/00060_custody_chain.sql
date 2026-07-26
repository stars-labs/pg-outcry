-- HD custody, chain pollers, in-DB transaction signing and broadcast
--
-- Squashed from the pre-launch incremental migrations, concatenated in their
-- original apply order (so the resulting schema is identical). Section headers
-- below name the migration each block came from.


-- ══ 00790_admin_derivatives_controls.sql ══════════════════════════════════════════

-- Admin controls for the feature surface added after the core back-office:
-- staking pools/config, spot-margin terms, perp market parameters, and manual
-- maintenance job triggers. Kept service_role-only.

create or replace function admin_set_stake_pool(
    currency_param text,
    apr_param numeric,
    unbond_seconds_param int default null)
  returns void
  language plpgsql
  security definer
  set search_path = public, pg_temp
as $$
begin
  if coalesce(trim(currency_param), '') = '' then raise exception 'currency_required'; end if;
  if apr_param is null or apr_param < 0 then raise exception 'invalid_apr'; end if;
  perform 1 from currency where name = currency_param;
  if not found then raise exception 'unknown_currency: %', currency_param; end if;

  if exists (select 1 from stake_pool where currency = currency_param) then
    perform _stake_update_pool(currency_param);
    update stake_pool set apr = apr_param, updated_at = now() where currency = currency_param;
  else
    insert into stake_pool(currency, apr) values (currency_param, apr_param);
  end if;

  if unbond_seconds_param is not null then
    if unbond_seconds_param < 0 then raise exception 'invalid_unbond_seconds'; end if;
    insert into stake_config(id, unbond_seconds) values (1, unbond_seconds_param)
      on conflict (id) do update set unbond_seconds = excluded.unbond_seconds;
  end if;

  insert into admin_audit_log(action, target, detail)
    values ('SET_STAKE_POOL', currency_param,
            jsonb_build_object('apr', apr_param, 'unbond_seconds', unbond_seconds_param));
end $$;

create or replace function admin_set_margin_terms(
    max_leverage_param numeric,
    maintenance_ratio_param numeric,
    borrow_apr_param numeric)
  returns void
  language plpgsql
  security definer
  set search_path = public, pg_temp
as $$
declare e bigint;
begin
  if max_leverage_param is null or max_leverage_param <= 1 then raise exception 'invalid_max_leverage'; end if;
  if maintenance_ratio_param is null or maintenance_ratio_param <= 0 or maintenance_ratio_param >= 1 then
    raise exception 'invalid_maintenance_ratio';
  end if;
  if borrow_apr_param is null or borrow_apr_param < 0 then raise exception 'invalid_borrow_apr'; end if;

  -- Accrue existing loans under the old APR before changing the global term.
  for e in select distinct app_entity_id from margin_loan where principal + accrued > 0 loop
    perform _margin_accrue(e);
  end loop;

  insert into margin_config(id, max_leverage, maintenance_ratio, borrow_apr)
    values (1, max_leverage_param, maintenance_ratio_param, borrow_apr_param)
  on conflict (id) do update
    set max_leverage = excluded.max_leverage,
        maintenance_ratio = excluded.maintenance_ratio,
        borrow_apr = excluded.borrow_apr;

  insert into admin_audit_log(action, target, detail)
    values ('SET_MARGIN_TERMS', 'margin_config',
            jsonb_build_object('max_leverage', max_leverage_param,
                               'maintenance_ratio', maintenance_ratio_param,
                               'borrow_apr', borrow_apr_param));
end $$;

create or replace function admin_set_perp_market(
    symbol_param text,
    index_symbol_param text default null,
    margin_currency_param text default null,
    mark_price_param numeric default null,
    funding_rate_param numeric default null,
    max_leverage_param numeric default null,
    maintenance_ratio_param numeric default null)
  returns void
  language plpgsql
  security definer
  set search_path = public, pg_temp
as $$
declare existing perp_market%rowtype;
begin
  if coalesce(trim(symbol_param), '') = '' then raise exception 'symbol_required'; end if;
  if mark_price_param is not null and mark_price_param <= 0 then raise exception 'invalid_mark_price'; end if;
  if max_leverage_param is not null and max_leverage_param <= 1 then raise exception 'invalid_max_leverage'; end if;
  if maintenance_ratio_param is not null and (maintenance_ratio_param <= 0 or maintenance_ratio_param >= 1) then
    raise exception 'invalid_maintenance_ratio';
  end if;

  select * into existing from perp_market where symbol = symbol_param;
  if not found and coalesce(trim(index_symbol_param), '') = '' then
    raise exception 'index_symbol_required_for_new_market';
  end if;

  if index_symbol_param is not null then
    perform 1 from instrument where name = index_symbol_param;
    if not found then raise exception 'unknown_index_symbol: %', index_symbol_param; end if;
  end if;
  if margin_currency_param is not null then
    perform 1 from currency where name = margin_currency_param;
    if not found then raise exception 'unknown_margin_currency: %', margin_currency_param; end if;
  end if;

  insert into perp_market(symbol, index_symbol, margin_currency, mark_price, funding_rate, max_leverage, maintenance_ratio, updated_at)
    values (symbol_param,
            coalesce(index_symbol_param, existing.index_symbol),
            coalesce(margin_currency_param, existing.margin_currency, 'EUR'),
            mark_price_param,
            coalesce(funding_rate_param, existing.funding_rate, 0),
            coalesce(max_leverage_param, existing.max_leverage, 10),
            coalesce(maintenance_ratio_param, existing.maintenance_ratio, 0.05),
            now())
  on conflict (symbol) do update
    set index_symbol = coalesce(excluded.index_symbol, perp_market.index_symbol),
        margin_currency = coalesce(excluded.margin_currency, perp_market.margin_currency),
        mark_price = coalesce(excluded.mark_price, perp_market.mark_price),
        funding_rate = excluded.funding_rate,
        max_leverage = excluded.max_leverage,
        maintenance_ratio = excluded.maintenance_ratio,
        updated_at = now();

  insert into admin_audit_log(action, target, detail)
    values ('SET_PERP_MARKET', symbol_param,
            jsonb_build_object('index_symbol', index_symbol_param,
                               'margin_currency', margin_currency_param,
                               'mark_price', mark_price_param,
                               'funding_rate', funding_rate_param,
                               'max_leverage', max_leverage_param,
                               'maintenance_ratio', maintenance_ratio_param));
end $$;

create or replace function admin_run_derivative_jobs(
    update_marks boolean default true,
    apply_funding boolean default false,
    check_perps boolean default true,
    check_margin boolean default true,
    process_unbonds boolean default true)
  returns jsonb
  language plpgsql
  security definer
  set search_path = public, pg_temp
as $$
declare
  mark_count int := null;
  funding_count int := null;
  perp_liq_count int := null;
  margin_liq_count int := null;
  unbond_count int := null;
begin
  if update_marks then mark_count := update_perp_mark(); end if;
  if apply_funding then funding_count := apply_perp_funding(); end if;
  if check_perps then perp_liq_count := check_perp_liquidations(); end if;
  if check_margin then margin_liq_count := check_margin_liquidations(); end if;
  if process_unbonds then unbond_count := process_unbonding(); end if;

  insert into admin_audit_log(action, target, detail)
    values ('RUN_DERIVATIVE_JOBS', 'derivatives',
            jsonb_build_object('update_marks', mark_count,
                               'apply_funding', funding_count,
                               'check_perps', perp_liq_count,
                               'check_margin', margin_liq_count,
                               'process_unbonds', unbond_count));

  return jsonb_build_object('update_marks', mark_count,
                            'apply_funding', funding_count,
                            'check_perps', perp_liq_count,
                            'check_margin', margin_liq_count,
                            'process_unbonds', unbond_count);
end $$;

grant execute on function
  admin_set_stake_pool(text,numeric,int),
  admin_set_margin_terms(numeric,numeric,numeric),
  admin_set_perp_market(text,text,text,numeric,numeric,numeric,numeric),
  admin_run_derivative_jobs(boolean,boolean,boolean,boolean,boolean)
  to service_role;

revoke execute on function
  admin_set_stake_pool(text,numeric,int),
  admin_set_margin_terms(numeric,numeric,numeric),
  admin_set_perp_market(text,text,text,numeric,numeric,numeric,numeric),
  admin_run_derivative_jobs(boolean,boolean,boolean,boolean,boolean)
  from public, anon, authenticated;


-- ══ 00800_admin_wallet_chain_api_ops.sql ══════════════════════════════════════════

-- Admin controls for operator surfaces outside the trading terminal:
-- chain deposit config/manual credit and service-role API key revocation.
-- Withdrawal queue status is readable directly by service_role from wallet_request;
-- broadcast/confirm actions use the existing signer RPCs from 9925.

create or replace function admin_set_chain_config(
    chain_param text,
    rpc_url_param text default null,
    confirmations_param int default null,
    enabled_param boolean default null)
  returns void
  language plpgsql
  security definer
  set search_path = public, pg_temp
as $$
begin
  if coalesce(trim(chain_param), '') = '' then raise exception 'chain_required'; end if;
  if confirmations_param is not null and confirmations_param < 0 then raise exception 'invalid_confirmations'; end if;

  update chain
     set rpc_url = coalesce(rpc_url_param, rpc_url),
         confirmations = coalesce(confirmations_param, confirmations),
         enabled = coalesce(enabled_param, enabled)
   where name = chain_param;
  if not found then raise exception 'unknown_chain: %', chain_param; end if;

  insert into admin_audit_log(action, target, detail)
    values ('SET_CHAIN_CONFIG', chain_param,
            jsonb_build_object('rpc_url_set', rpc_url_param is not null,
                               'confirmations', confirmations_param,
                               'enabled', enabled_param));
end $$;

create or replace function admin_set_chain_asset(
    chain_param text,
    token_param text,
    currency_param text,
    decimals_param int)
  returns void
  language plpgsql
  security definer
  set search_path = public, pg_temp
as $$
begin
  if coalesce(trim(chain_param), '') = '' then raise exception 'chain_required'; end if;
  if coalesce(trim(token_param), '') = '' then raise exception 'token_required'; end if;
  if coalesce(trim(currency_param), '') = '' then raise exception 'currency_required'; end if;
  if decimals_param is null or decimals_param < 0 then raise exception 'invalid_decimals'; end if;
  perform 1 from chain where name = chain_param;
  if not found then raise exception 'unknown_chain: %', chain_param; end if;
  perform 1 from currency where name = currency_param;
  if not found then raise exception 'unknown_currency: %', currency_param; end if;

  insert into chain_asset(chain, token, currency, decimals)
    values (chain_param, lower(token_param), currency_param, decimals_param)
  on conflict (chain, token) do update
    set currency = excluded.currency,
        decimals = excluded.decimals;

  insert into admin_audit_log(action, target, detail)
    values ('SET_CHAIN_ASSET', chain_param || ':' || lower(token_param),
            jsonb_build_object('currency', currency_param, 'decimals', decimals_param));
end $$;

create or replace function admin_revoke_api_key(key_id_param text)
  returns boolean
  language plpgsql
  security definer
  set search_path = public, pg_temp
as $$
declare n int;
begin
  if coalesce(trim(key_id_param), '') = '' then raise exception 'key_id_required'; end if;
  update api_key set revoked_at = now()
   where key_id = key_id_param and revoked_at is null;
  get diagnostics n = row_count;

  insert into admin_audit_log(action, target, detail)
    values ('REVOKE_API_KEY', key_id_param, jsonb_build_object('changed', n > 0));
  return n > 0;
end $$;

grant execute on function
  admin_set_chain_config(text,text,int,boolean),
  admin_set_chain_asset(text,text,text,int),
  admin_revoke_api_key(text)
  to service_role;

revoke execute on function
  admin_set_chain_config(text,text,int,boolean),
  admin_set_chain_asset(text,text,text,int),
  admin_revoke_api_key(text)
  from public, anon, authenticated;


-- ══ 00810_hd_custody.sql ══════════════════════════════════════════

-- Stage 2 of in-DB custody: master seed + per-user deposit address derivation,
-- entirely inside Postgres. Private keys are NEVER stored — re-derived on demand
-- from the vault-encrypted master seed (deterministic) when signing (Stage 4).
--
-- secp256k1 (EVM/Tron) uses the pure-PL/pgSQL primitives from 9970; ed25519 (Solana)
-- uses pgsodium. Addresses: EVM = 0x‖keccak(pub)[12:]; Tron = base58check(0x41‖keccak
-- (pub)[12:]); Solana = base58(ed25519 pub). TESTNET ONLY — the seed lives in the DB,
-- so DB access == fund control. Numbered >9900 so 9900_lockdown has already run.

create extension if not exists pgsodium;

-- ───────────────────────── base58 / base58check (Bitcoin alphabet) ─────────────
create or replace function base58_encode(data bytea) returns text
  language plpgsql immutable set search_path = public, pg_temp as $$
declare
  alpha constant text := '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';
  n numeric := 0; s text := ''; zeros int := 0; i int := 0; d int;
begin
  -- leading zero bytes become leading '1's
  while i < octet_length(data) and get_byte(data, i) = 0 loop zeros := zeros + 1; i := i + 1; end loop;
  n := public.secp_b2n(data);                  -- big-endian bytes -> numeric (from 9970)
  while n > 0 loop
    d := mod(n, 58)::int;
    s := substr(alpha, d + 1, 1) || s;
    n := div(n, 58);
  end loop;
  return repeat('1', zeros) || s;
end $$;

create or replace function base58check(payload bytea) returns text
  language sql immutable set search_path = public, extensions, pg_temp as $$
  select public.base58_encode(
    payload || substr(extensions.digest(extensions.digest(payload, 'sha256'), 'sha256'), 1, 4));
$$;

-- ───────────────────────── master seed (vault) ─────────────────────────────────
-- One random 32-byte seed, created once, stored encrypted in supabase_vault.
create or replace function _master_seed() returns bytea
  language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare h text;
begin
  select decrypted_secret into h from vault.decrypted_secrets where name = 'wallet_master_seed';
  if h is null then
    perform vault.create_secret(
      encode(extensions.gen_random_bytes(32), 'hex'),
      'wallet_master_seed',
      'pg-outcry in-DB HD wallet master seed (TESTNET ONLY)');
    select decrypted_secret into h from vault.decrypted_secrets where name = 'wallet_master_seed';
  end if;
  return decode(h, 'hex');
end $$;

-- ───────────────────────── per-user key derivation ─────────────────────────────
-- Deterministic: priv = HMAC-SHA512(master_seed, "<chain>:<entity_id>") -> mod n (secp)
-- or first 32 bytes (ed25519 seed). Not canonical BIP44, but stable + unique per user.
create or replace function _derive_secp_priv(eid bigint, chain_param text) returns bytea
  language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare
  n constant numeric := 115792089237316195423570985008687907852837564279074904382605163141518161494337;
  raw bytea;
begin
  raw := extensions.hmac((chain_param || ':' || eid)::bytea, public._master_seed(), 'sha512');
  return public.secp_n2bytea(mod(public.secp_b2n(substr(raw, 1, 32)), n - 1) + 1);  -- [1, n-1]
end $$;

create or replace function _derive_ed25519_seed(eid bigint) returns bytea
  language plpgsql security definer set search_path = public, extensions, pg_temp as $$
begin
  return substr(extensions.hmac(('solana:' || eid)::bytea, public._master_seed(), 'sha512'), 1, 32);
end $$;

-- ───────────────────────── address helpers ─────────────────────────────────────
create or replace function tron_address_from_priv(priv bytea) returns text
  language sql security definer set search_path = public, extensions, pg_temp as $$
  -- Tron addr = base58check(0x41 ‖ last20(keccak256(pubkey)))
  select public.base58check('\x41'::bytea || substr(public.keccak256(public.secp_pubkey(priv)), 13, 20));
$$;

create or replace function sol_address_from_eid(eid bigint) returns text
  language sql security definer set search_path = public, extensions, pg_temp as $$
  select public.base58_encode((pgsodium.crypto_sign_seed_new_keypair(public._derive_ed25519_seed(eid))).public);
$$;

-- ───────────────────────── per-user deposit wallet ─────────────────────────────
create table if not exists user_chain_wallet (
  app_entity_id bigint not null references app_entity(id) on delete cascade,
  chain         text   not null references chain(name),
  address       text   not null,
  created_at    timestamptz not null default now(),
  primary key (app_entity_id, chain)
);
alter table user_chain_wallet enable row level security;
drop policy if exists own_user_chain_wallet on user_chain_wallet;
create policy own_user_chain_wallet on user_chain_wallet for select to authenticated
  using (app_entity_id = current_app_entity_id());

-- Caller's deposit address for a chain: derive (first time) + persist + register into
-- watched_address so the in-DB poller credits inbound funds to this user. Idempotent.
create or replace function my_deposit_address(chain_param text) returns jsonb
  language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare eid bigint := current_app_entity_id(); k text; addr text; priv bytea;
begin
  if eid is null then raise exception 'not_authenticated'; end if;
  select kind into k from chain where name = chain_param;
  if k is null then raise exception 'unknown_chain: %', chain_param; end if;

  select address into addr from user_chain_wallet where app_entity_id = eid and chain = chain_param;
  if addr is null then
    if k = 'evm' then
      priv := public._derive_secp_priv(eid, chain_param);
      addr := public.evm_address(priv);
    elsif k = 'tron' then
      priv := public._derive_secp_priv(eid, chain_param);
      addr := public.tron_address_from_priv(priv);
    elsif k = 'solana' then
      addr := public.sol_address_from_eid(eid);
    else
      raise exception 'unsupported_chain_kind: %', k;
    end if;
    insert into user_chain_wallet(app_entity_id, chain, address) values (eid, chain_param, addr)
      on conflict (app_entity_id, chain) do update set address = excluded.address
      returning address into addr;
    insert into watched_address(app_entity_id, chain, address) values (eid, chain_param, addr)
      on conflict (chain, address) do nothing;
  end if;
  return jsonb_build_object('chain', chain_param, 'kind', k, 'address', addr);
end $$;

grant select on user_chain_wallet to authenticated;
grant execute on function my_deposit_address(text) to authenticated;
revoke execute on function my_deposit_address(text) from public, anon;
revoke execute on function
  base58_encode(bytea), base58check(bytea), _master_seed(),
  _derive_secp_priv(bigint, text), _derive_ed25519_seed(bigint),
  tron_address_from_priv(bytea), sol_address_from_eid(bigint)
  from public, anon, authenticated;


-- ══ 00820_chain_balance_poller.sql ══════════════════════════════════════════

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


-- ══ 00830_evm_withdrawal_signer.sql ══════════════════════════════════════════

-- Stage 4 (EVM) of in-DB custody: sign + broadcast Ethereum withdrawals ENTIRELY in
-- Postgres — no external signer. RLP + EIP-155 serialization in pure PL/pgSQL (validated
-- byte-identical to ethers across 120 random txs), signed with the 9970 secp256k1, and
-- broadcast over the `http` extension (egress verified from hosted Supabase).
--
-- The house "treasury" (HD index 0) holds the float and pays out; fund it from a faucet.
-- Withdrawals settle the EUR balance via the existing 9925 queue; on-chain we send the
-- native coin 1:1 with the nominal EUR amount (demo mapping). Numbered >9900.
-- Solana/Tron signing land in a follow-up; this slice is EVM (Sepolia) end-to-end.

-- ═══════════════════════ RLP + EIP-155 signed-tx builder (vs ethers, 120/120) ═════
create or replace function public.rlp_len_prefix(len int, base int) returns bytea
  language plpgsql immutable as $$
declare lenbytes bytea; n int;
begin
  if len <= 55 then return set_byte('\x00'::bytea, 0, base + len); end if;
  lenbytes := '\x'::bytea; n := len;
  while n > 0 loop
    lenbytes := set_byte('\x00'::bytea, 0, n & 255) || lenbytes; n := n >> 8;
  end loop;
  return set_byte('\x00'::bytea, 0, base + 55 + length(lenbytes)) || lenbytes;
end; $$;

create or replace function public.rlp_encode_bytes(b bytea) returns bytea
  language plpgsql immutable as $$
declare len int := length(b);
begin
  if len = 1 and get_byte(b, 0) <= 127 then return b; end if;
  return public.rlp_len_prefix(len, 128) || b;
end; $$;

create or replace function public.rlp_encode_list(items bytea[]) returns bytea
  language plpgsql immutable as $$
declare payload bytea := '\x'::bytea; it bytea;
begin
  foreach it in array items loop payload := payload || it; end loop;
  return public.rlp_len_prefix(length(payload), 192) || payload;
end; $$;

create or replace function public.uint_to_minimal_bytes(n numeric) returns bytea
  language plpgsql immutable as $$
declare out bytea := '\x'::bytea; q numeric := trunc(n); byte int;
begin
  if q < 0 then raise exception 'uint_to_minimal_bytes: negative value %', n; end if;
  if q = 0 then return '\x'::bytea; end if;
  while q > 0 loop
    byte := (q % 256)::int;
    out := set_byte('\x00'::bytea, 0, byte) || out;
    q := div(q, 256);
  end loop;
  return out;
end; $$;

create or replace function public.rlp_encode_uint(n numeric) returns bytea
  language plpgsql immutable as $$
begin return public.rlp_encode_bytes(public.uint_to_minimal_bytes(n)); end; $$;

create or replace function public.strip_leading_zeros(b bytea) returns bytea
  language plpgsql immutable as $$
declare i int := 0; n int := length(b);
begin
  while i < n and get_byte(b, i) = 0 loop i := i + 1; end loop;
  return substring(b from i + 1 for n - i);
end; $$;

create or replace function public.evm_build_signed_tx(
    priv bytea, nonce numeric, gas_price numeric, gas_limit numeric,
    to_addr text, value_wei numeric, chain_id int) returns text
  language plpgsql as $$
declare
  to_bytes bytea; data_enc bytea; sighash bytea; sig jsonb; v01 int;
  v_final numeric; r_bytes bytea; s_bytes bytea; signing bytea; final_tx bytea;
begin
  to_bytes := decode(regexp_replace(lower(to_addr), '^0x', ''), 'hex');
  if length(to_bytes) <> 20 then raise exception 'to_addr must be 20 bytes, got %', length(to_bytes); end if;
  data_enc := public.rlp_encode_bytes('\x'::bytea);

  signing := public.rlp_encode_list(array[
    public.rlp_encode_uint(nonce), public.rlp_encode_uint(gas_price),
    public.rlp_encode_uint(gas_limit), public.rlp_encode_bytes(to_bytes),
    public.rlp_encode_uint(value_wei), data_enc,
    public.rlp_encode_uint(chain_id), public.rlp_encode_uint(0), public.rlp_encode_uint(0)]);
  sighash := public.keccak256(signing);
  sig := public.secp_sign(priv, sighash);
  v01 := (sig->>'v')::int;
  v_final := chain_id::numeric * 2 + 35 + v01;
  r_bytes := public.strip_leading_zeros(decode(lpad(sig->>'r', 64, '0'), 'hex'));
  s_bytes := public.strip_leading_zeros(decode(lpad(sig->>'s', 64, '0'), 'hex'));

  final_tx := public.rlp_encode_list(array[
    public.rlp_encode_uint(nonce), public.rlp_encode_uint(gas_price),
    public.rlp_encode_uint(gas_limit), public.rlp_encode_bytes(to_bytes),
    public.rlp_encode_uint(value_wei), data_enc,
    public.rlp_encode_uint(v_final), public.rlp_encode_bytes(r_bytes), public.rlp_encode_bytes(s_bytes)]);
  return '0x' || encode(final_tx, 'hex');
end; $$;

-- ═══════════════════════ treasury (house float) ════════════════════════════════
-- HD index 0 is the house. Fund treasury_address('<chain>') from a faucet (Stage 6).
create or replace function treasury_address(chain_param text) returns text
  language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare k text;
begin
  select kind into k from chain where name = chain_param;
  if k = 'evm' then return public.evm_address(public._derive_secp_priv(0, chain_param));
  elsif k = 'tron' then return public.tron_address_from_priv(public._derive_secp_priv(0, chain_param));
  elsif k = 'solana' then return public.sol_address_from_eid(0);
  else raise exception 'unknown_or_unsupported_chain: %', chain_param; end if;
end; $$;

-- ═══════════════════════ EVM JSON-RPC over http ════════════════════════════════
create or replace function _evm_rpc(rpc_url text, method text, params jsonb) returns jsonb
  language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare resp jsonb;
begin
  resp := (extensions.http_post(rpc_url,
    jsonb_build_object('jsonrpc','2.0','id',1,'method',method,'params',params)::text,
    'application/json')).content::jsonb;
  if resp ? 'error' then raise exception 'rpc_error % : %', method, resp->'error'; end if;
  return resp->'result';
end; $$;

-- ═══════════════════════ sign + broadcast one EVM withdrawal ═══════════════════
create or replace function sign_and_broadcast_evm_withdrawal(request_pub text) returns text
  language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare
  wr record; chain_param text := 'ethereum-sepolia'; cfg chain%rowtype;
  priv bytea; from_addr text; nonce numeric; gas_price numeric; value_wei numeric;
  raw text; txhash text; dec int;
begin
  select pub_id, currency, amount, to_address, status, direction, broadcast_txid
    into wr from wallet_request where pub_id = request_pub for update;
  if not found then raise exception 'no_such_request'; end if;
  if wr.direction <> 'WITHDRAWAL' or wr.status <> 'APPROVED' then raise exception 'not_approved_withdrawal'; end if;
  if wr.broadcast_txid is not null then return wr.broadcast_txid; end if;
  if wr.to_address is null or left(wr.to_address, 2) <> '0x' then raise exception 'not_evm_address'; end if;

  select * into cfg from chain where name = chain_param;
  if cfg.rpc_url is null then raise exception 'chain_not_configured'; end if;
  select decimals into dec from chain_asset where chain = chain_param and token = 'native';

  priv := public._derive_secp_priv(0, chain_param);
  from_addr := public.evm_address(priv);
  nonce := hex_to_numeric(substr(_evm_rpc(cfg.rpc_url, 'eth_getTransactionCount',
             jsonb_build_array(from_addr, 'pending')) #>> '{}', 3));
  gas_price := hex_to_numeric(substr(_evm_rpc(cfg.rpc_url, 'eth_gasPrice', '[]'::jsonb) #>> '{}', 3));
  value_wei := trunc(wr.amount * power(10, dec));

  raw := public.evm_build_signed_tx(priv, nonce, gas_price, 21000, wr.to_address, value_wei, 11155111);
  txhash := '0x' || encode(public.keccak256(decode(substr(raw, 3), 'hex')), 'hex');
  perform _evm_rpc(cfg.rpc_url, 'eth_sendRawTransaction', jsonb_build_array(raw));
  perform mark_withdrawal_broadcast(request_pub, txhash);
  return txhash;
end; $$;

-- ═══════════════════════ cron drivers (claim → sign → broadcast → confirm) ═════
create or replace function process_evm_withdrawals() returns int
  language plpgsql security definer set search_path = public, pg_temp as $$
declare wr record; n int := 0;
begin
  for wr in
    select pub_id from wallet_request
    where direction = 'WITHDRAWAL' and status = 'APPROVED'
      and to_address like '0x%' and broadcast_txid is null
    for update skip locked
  loop
    begin
      perform sign_and_broadcast_evm_withdrawal(wr.pub_id); n := n + 1;
    exception when others then
      raise warning 'evm withdrawal % failed: %', wr.pub_id, sqlerrm;
    end;
  end loop;
  return n;
end; $$;

create or replace function process_evm_confirmations() returns int
  language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare wr record; cfg chain%rowtype; receipt jsonb; n int := 0;
begin
  select * into cfg from chain where name = 'ethereum-sepolia';
  if cfg.rpc_url is null then return 0; end if;
  for wr in
    select pub_id, broadcast_txid from wallet_request
    where direction = 'WITHDRAWAL' and broadcast_txid is not null and confirmed_at is null
      and to_address like '0x%'
    for update skip locked
  loop
    begin
      receipt := _evm_rpc(cfg.rpc_url, 'eth_getTransactionReceipt', jsonb_build_array(wr.broadcast_txid));
      if receipt is not null and jsonb_typeof(receipt) = 'object' and (receipt->>'status') = '0x1' then
        perform mark_withdrawal_confirmed(wr.pub_id); n := n + 1;
      end if;
    exception when others then
      raise warning 'evm confirm % failed: %', wr.pub_id, sqlerrm;
    end;
  end loop;
  return n;
end; $$;

do $$ begin
  perform cron.schedule('process-evm-withdrawals', '30 seconds', 'select process_evm_withdrawals()');
  perform cron.schedule('process-evm-confirmations', '45 seconds', 'select process_evm_confirmations()');
exception when others then null; end $$;

revoke execute on function
  treasury_address(text), _evm_rpc(text,text,jsonb),
  sign_and_broadcast_evm_withdrawal(text), process_evm_withdrawals(), process_evm_confirmations()
  from public, anon, authenticated;
grant execute on function
  treasury_address(text), sign_and_broadcast_evm_withdrawal(text),
  process_evm_withdrawals(), process_evm_confirmations()
  to service_role;


-- ══ 00840_solana_tron_withdrawal.sql ══════════════════════════════════════════

-- Stage 4 (Solana + Tron) of in-DB custody: sign + broadcast SOL and TRX withdrawals
-- entirely in Postgres, completing all three chains. Solana = ed25519 (pgsodium) over a
-- serialized transfer message (built in plpgsql, validated byte-identical to
-- @solana/web3.js, 30/30). Tron = secp256k1 (9970) signature over the txID that
-- TronGrid's createtransaction returns (no protobuf in-DB), validated vs TronWeb (60/60).
-- Broadcast over the http extension. Numbered >9900.

-- ── base58 DECODE (Solana addresses/blockhash, Tron addresses) ──────────────────
create or replace function base58_decode(s text) returns bytea
  language plpgsql immutable set search_path = public, pg_temp as $$
declare
  alpha constant text := '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';
  n numeric := 0; i int; c int; zeros int := 0; hexs text := '';
begin
  i := 1;
  while i <= length(s) and substr(s, i, 1) = '1' loop zeros := zeros + 1; i := i + 1; end loop;
  for i in 1..length(s) loop
    c := position(substr(s, i, 1) in alpha) - 1;
    if c < 0 then raise exception 'bad base58 char: %', substr(s, i, 1); end if;
    n := n * 58 + c;
  end loop;
  while n > 0 loop
    hexs := substr('0123456789abcdef', (mod(n, 16))::int + 1, 1) || hexs; n := div(n, 16);
  end loop;
  if length(hexs) % 2 = 1 then hexs := '0' || hexs; end if;
  return decode(repeat('00', zeros), 'hex') || decode(hexs, 'hex');
end $$;

-- ═══════════════════════ Solana: serialize + ed25519 sign (vs web3.js 30/30) ════
create or replace function public.sol_shortvec(v integer) returns bytea
  language plpgsql immutable set search_path = public, pg_temp as $$
declare out bytea := '\x'::bytea; n bigint := v;
begin
  if n < 0 then raise exception 'sol_shortvec: negative %', v; end if;
  loop
    if n < 128 then out := out || set_byte('\x00'::bytea, 0, (n & 127)::int); exit;
    else out := out || set_byte('\x00'::bytea, 0, ((n & 127) | 128)::int); n := n >> 7; end if;
  end loop;
  return out;
end $$;

create or replace function public.sol_u64le(v numeric) returns bytea
  language plpgsql immutable set search_path = public, pg_temp as $$
declare out bytea := '\x0000000000000000'::bytea; n numeric := trunc(v); i int;
begin
  if n < 0 then raise exception 'sol_u64le: negative %', v; end if;
  if n >= 18446744073709551616 then raise exception 'sol_u64le: exceeds u64 %', v; end if;
  for i in 0..7 loop out := set_byte(out, i, mod(n, 256)::int); n := div(n, 256); end loop;
  return out;
end $$;

create or replace function public.sol_build_signed_tx(
    seed bytea, to_pubkey bytea, lamports numeric, recent_blockhash bytea) returns text
  language plpgsql volatile set search_path = public, pg_temp as $$
declare
  kp record; from_pubkey bytea; secret bytea;
  system_program bytea := decode('0000000000000000000000000000000000000000000000000000000000000000','hex');
  header bytea; account_keys bytea; instr_data bytea; instruction bytea; message bytea; signature bytea; tx bytea;
begin
  if octet_length(seed) <> 32 then raise exception 'seed must be 32 bytes'; end if;
  if octet_length(to_pubkey) <> 32 then raise exception 'to_pubkey must be 32 bytes'; end if;
  if octet_length(recent_blockhash) <> 32 then raise exception 'blockhash must be 32 bytes'; end if;
  kp := pgsodium.crypto_sign_seed_new_keypair(seed);
  from_pubkey := kp.public; secret := kp.secret;
  header := set_byte(set_byte(set_byte('\x000000'::bytea, 0, 1), 1, 0), 2, 1);
  account_keys := public.sol_shortvec(3) || from_pubkey || to_pubkey || system_program;
  instr_data := decode('02000000','hex') || public.sol_u64le(lamports);
  instruction := set_byte('\x00'::bytea, 0, 2)
    || public.sol_shortvec(2) || set_byte('\x00'::bytea, 0, 0) || set_byte('\x00'::bytea, 0, 1)
    || public.sol_shortvec(octet_length(instr_data)) || instr_data;
  message := header || account_keys || recent_blockhash || public.sol_shortvec(1) || instruction;
  signature := pgsodium.crypto_sign_detached(message, secret);
  tx := public.sol_shortvec(1) || signature || message;
  return translate(encode(tx, 'base64'), E'\n', '');
end $$;

-- ═══════════════════════ Tron: secp signature over the txID (vs TronWeb 60/60) ══
create or replace function public.tron_sign(priv bytea, txid bytea) returns text
  language plpgsql immutable set search_path = public, pg_temp as $$
declare sig jsonb := public.secp_sign(priv, txid);
begin
  -- 65-byte recoverable sig: r(32) || s(32) || v(1), v = recovery id + 27 (TronWeb convention)
  return lower((sig->>'r') || (sig->>'s') || lpad(to_hex(((sig->>'v')::int) + 27), 2, '0'));
end $$;

-- ═══════════════════════ Solana broadcast orchestration ════════════════════════
create or replace function sign_and_broadcast_solana_withdrawal(request_pub text) returns text
  language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare
  wr record; cfg chain%rowtype; seed bytea; to_pub bytea; lamports numeric; dec int;
  bh text; resp jsonb; tx_b64 text; sig text;
begin
  select pub_id, amount, to_address, status, direction, broadcast_txid into wr
    from wallet_request where pub_id = request_pub for update;
  if not found then raise exception 'no_such_request'; end if;
  if wr.direction <> 'WITHDRAWAL' or wr.status <> 'APPROVED' then raise exception 'not_approved_withdrawal'; end if;
  if wr.broadcast_txid is not null then return wr.broadcast_txid; end if;

  select * into cfg from chain where name = 'solana-testnet';
  if cfg.rpc_url is null then raise exception 'chain_not_configured'; end if;
  select decimals into dec from chain_asset where chain = 'solana-testnet' and token = 'native';
  seed := public._derive_ed25519_seed(0);
  to_pub := public.base58_decode(wr.to_address);
  lamports := trunc(wr.amount * power(10, dec));

  resp := (extensions.http_post(cfg.rpc_url,
    jsonb_build_object('jsonrpc','2.0','id',1,'method','getLatestBlockhash',
      'params', jsonb_build_array(jsonb_build_object('commitment','finalized')))::text,
    'application/json')).content::jsonb;
  bh := resp->'result'->'value'->>'blockhash';
  if bh is null then raise exception 'no_blockhash: %', resp; end if;

  tx_b64 := public.sol_build_signed_tx(seed, to_pub, lamports, public.base58_decode(bh));
  resp := (extensions.http_post(cfg.rpc_url,
    jsonb_build_object('jsonrpc','2.0','id',1,'method','sendTransaction',
      'params', jsonb_build_array(tx_b64, jsonb_build_object('encoding','base64')))::text,
    'application/json')).content::jsonb;
  if resp ? 'error' then raise exception 'sol_send_error: %', resp->'error'; end if;
  sig := resp->>'result';
  perform mark_withdrawal_broadcast(request_pub, sig);
  return sig;
end $$;

-- ═══════════════════════ Tron broadcast orchestration ══════════════════════════
create or replace function sign_and_broadcast_tron_withdrawal(request_pub text) returns text
  language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare
  wr record; cfg chain%rowtype; owner text; amount_sun numeric; dec int;
  created jsonb; txid text; signed jsonb; bresp jsonb;
begin
  select pub_id, amount, to_address, status, direction, broadcast_txid into wr
    from wallet_request where pub_id = request_pub for update;
  if not found then raise exception 'no_such_request'; end if;
  if wr.direction <> 'WITHDRAWAL' or wr.status <> 'APPROVED' then raise exception 'not_approved_withdrawal'; end if;
  if wr.broadcast_txid is not null then return wr.broadcast_txid; end if;

  select * into cfg from chain where name = 'tron-nile';
  if cfg.rpc_url is null then raise exception 'chain_not_configured'; end if;
  select decimals into dec from chain_asset where chain = 'tron-nile' and token = 'native';
  owner := public.treasury_address('tron-nile');
  amount_sun := trunc(wr.amount * power(10, dec));

  -- TronGrid builds the unsigned tx (returns txID = sha256(raw_data)); we just sign it.
  created := (extensions.http_post(cfg.rpc_url || '/wallet/createtransaction',
    jsonb_build_object('owner_address', owner, 'to_address', wr.to_address,
      'amount', amount_sun, 'visible', true)::text, 'application/json')).content::jsonb;
  txid := created->>'txID';
  if txid is null then raise exception 'tron_create_failed: %', created; end if;

  signed := created || jsonb_build_object('signature',
    jsonb_build_array(public.tron_sign(public._derive_secp_priv(0, 'tron-nile'), decode(txid, 'hex'))));
  bresp := (extensions.http_post(cfg.rpc_url || '/wallet/broadcasttransaction',
    signed::text, 'application/json')).content::jsonb;
  if (bresp->>'result')::boolean is not true then
    raise exception 'tron_broadcast_failed: %', bresp;
  end if;
  perform mark_withdrawal_broadcast(request_pub, txid);
  return txid;
end $$;

-- ═══════════════════════ queue drivers (route by destination address) ══════════
create or replace function process_solana_withdrawals() returns int
  language plpgsql security definer set search_path = public, pg_temp as $$
declare wr record; n int := 0;
begin
  for wr in select pub_id from wallet_request
    where direction='WITHDRAWAL' and status='APPROVED' and broadcast_txid is null
      and to_address not like '0x%' and to_address not like 'T%'
    for update skip locked loop
    begin perform sign_and_broadcast_solana_withdrawal(wr.pub_id); n := n + 1;
    exception when others then raise warning 'sol withdrawal % failed: %', wr.pub_id, sqlerrm; end;
  end loop;
  return n;
end $$;

create or replace function process_tron_withdrawals() returns int
  language plpgsql security definer set search_path = public, pg_temp as $$
declare wr record; n int := 0;
begin
  for wr in select pub_id from wallet_request
    where direction='WITHDRAWAL' and status='APPROVED' and broadcast_txid is null
      and to_address like 'T%'
    for update skip locked loop
    begin perform sign_and_broadcast_tron_withdrawal(wr.pub_id); n := n + 1;
    exception when others then raise warning 'tron withdrawal % failed: %', wr.pub_id, sqlerrm; end;
  end loop;
  return n;
end $$;

do $$ begin
  perform cron.schedule('process-solana-withdrawals', '30 seconds', 'select process_solana_withdrawals()');
  perform cron.schedule('process-tron-withdrawals',   '30 seconds', 'select process_tron_withdrawals()');
exception when others then null; end $$;

revoke execute on function
  base58_decode(text), sol_shortvec(integer), sol_u64le(numeric),
  sol_build_signed_tx(bytea,bytea,numeric,bytea), tron_sign(bytea,bytea),
  sign_and_broadcast_solana_withdrawal(text), sign_and_broadcast_tron_withdrawal(text),
  process_solana_withdrawals(), process_tron_withdrawals()
  from public, anon, authenticated;
grant execute on function
  sign_and_broadcast_solana_withdrawal(text), sign_and_broadcast_tron_withdrawal(text),
  process_solana_withdrawals(), process_tron_withdrawals()
  to service_role;


-- ══ 00850_token_assets_tron_trc20.sql ══════════════════════════════════════════

-- Stablecoin support, part 1: token currencies + verified testnet token contracts +
-- generalized Tron withdrawal that routes native TRX vs TRC-20 by the withdrawal's
-- currency. The TRC-20 transfer path (triggersmartcontract → sign txID → broadcast) is
-- LIVE-PROVEN on Nile: 0.5 USDT delivered, receipt SUCCESS, signed entirely in Postgres.
-- (ERC-20 + SPL withdrawal + token DEPOSIT detection are the next parts.)

-- token currencies (6dp like the contracts)
insert into currency(name, precision) values ('USDT', 6), ('USDC', 6)
on conflict (name) do nothing;

-- verified testnet token contracts (on-chain symbol/decimals checked):
--   Sepolia USDC 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238 (decimals 6)
--   Nile USDT    TXYZopYRdj2D9XRtbG411XZZ3kM5VkAeBf          (decimals 6)
--   devnet USDC  4zMMC9srt5Ri5X14GAgXhaHii3GnPAEERYPJgZJDncDU (decimals 6)
-- chain_asset key is (chain, token); a row with currency<>EUR + a contract token marks
-- a token asset. EVM tokens stored lowercased; Tron/Solana are base58 (case-sensitive).
insert into chain_asset(chain, token, currency, decimals) values
  ('ethereum-sepolia', lower('0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238'), 'USDC', 6),
  ('tron-nile',        'TXYZopYRdj2D9XRtbG411XZZ3kM5VkAeBf',                'USDT', 6),
  ('solana-testnet',   '4zMMC9srt5Ri5X14GAgXhaHii3GnPAEERYPJgZJDncDU',      'USDC', 6)
on conflict (chain, token) do nothing;

-- Generalized Tron withdrawal: native TRX (createtransaction) when the currency maps to
-- the 'native' asset, else a TRC-20 transfer(address,uint256) via triggersmartcontract.
-- Both produce a txID we sign in-DB with tron_sign (secp256k1) and broadcast over http.
create or replace function sign_and_broadcast_tron_withdrawal(request_pub text) returns text
  language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare
  wr record; cfg chain%rowtype; owner text; token text; dec int; amount_raw numeric;
  param text; trig jsonb; txn jsonb; created jsonb; txid text; signed jsonb; bresp jsonb;
begin
  select pub_id, amount, to_address, status, direction, broadcast_txid, currency into wr
    from wallet_request where pub_id = request_pub for update;
  if not found then raise exception 'no_such_request'; end if;
  if wr.direction <> 'WITHDRAWAL' or wr.status <> 'APPROVED' then raise exception 'not_approved_withdrawal'; end if;
  if wr.broadcast_txid is not null then return wr.broadcast_txid; end if;

  select * into cfg from chain where name = 'tron-nile';
  if cfg.rpc_url is null then raise exception 'chain_not_configured'; end if;
  -- resolve the asset for this currency on Tron (native or a TRC-20 contract)
  select ca.token, ca.decimals into token, dec from chain_asset ca
    where ca.chain = 'tron-nile' and ca.currency = wr.currency limit 1;
  if token is null then raise exception 'currency_not_supported_on_tron: %', wr.currency; end if;
  owner := public.treasury_address('tron-nile');
  amount_raw := trunc(wr.amount * power(10, dec));

  if token = 'native' then
    created := (extensions.http_post(cfg.rpc_url || '/wallet/createtransaction',
      jsonb_build_object('owner_address', owner, 'to_address', wr.to_address,
        'amount', amount_raw, 'visible', true)::text, 'application/json')).content::jsonb;
    txn := created; txid := created->>'txID';
  else
    -- transfer(address,uint256): 20-byte dest (strip 0x41) padded 32B || amount padded 32B
    param := lpad(encode(substr(public.base58_decode(wr.to_address), 2, 20), 'hex'), 64, '0')
          || lpad(to_hex(amount_raw::bigint), 64, '0');
    trig := (extensions.http_post(cfg.rpc_url || '/wallet/triggersmartcontract',
      jsonb_build_object('owner_address', owner, 'contract_address', token,
        'function_selector', 'transfer(address,uint256)', 'parameter', param,
        'fee_limit', 100000000, 'call_value', 0, 'visible', true)::text, 'application/json')).content::jsonb;
    txn := trig->'transaction'; txid := txn->>'txID';
  end if;

  if txid is null then raise exception 'tron_build_failed: %', coalesce(trig, created); end if;
  signed := txn || jsonb_build_object('signature',
    jsonb_build_array(public.tron_sign(public._derive_secp_priv(0, 'tron-nile'), decode(txid, 'hex'))));
  bresp := (extensions.http_post(cfg.rpc_url || '/wallet/broadcasttransaction',
    signed::text, 'application/json')).content::jsonb;
  if (bresp->>'result')::boolean is not true then raise exception 'tron_broadcast_failed: %', bresp; end if;
  perform mark_withdrawal_broadcast(request_pub, txid);
  return txid;
end $$;

-- process_tron_withdrawals (9996) already routes T-addresses here; it now handles both
-- native TRX and TRC-20 withdrawals based on the request currency.
revoke execute on function sign_and_broadcast_tron_withdrawal(text) from public, anon, authenticated;
grant execute on function sign_and_broadcast_tron_withdrawal(text) to service_role;


-- ══ 00860_hybrid_memo_deposits.sql ══════════════════════════════════════════

-- Hybrid deposit addressing: per-chain choice between a unique derived address
-- (EVM — no easy incoming-tx+memo API on public RPC) and ONE shared address + a
-- per-user memo/tag (Tron, Solana — their APIs surface incoming transfers + the memo
-- cheaply, and our deposit UI auto-attaches it so there's no forgotten-memo risk).
--
-- Memo = 'oc'||entity_id (deterministic, unique, no extra table). Shared address = the
-- house treasury (HD index 0). credit_memo_deposit attributes by memo instead of by
-- destination address; idempotent via chain_deposit (chain,txid,log_index), same as
-- credit_chain_deposit. Native coins map to EUR via chain_asset(token='native').

alter table chain add column if not exists addressing text not null default 'derived';
update chain set addressing = 'shared_memo' where name in ('tron-nile', 'solana-testnet');

-- caller's deposit memo tag
create or replace function my_deposit_memo() returns text
  language sql security definer set search_path = public, pg_temp stable as $$
  select 'oc' || current_app_entity_id();
$$;

-- credit a memo-attributed deposit to the user whose tag matches `memo`.
create or replace function credit_memo_deposit(
    chain_param text, txid_param text, log_index_param int,
    memo text, currency_param text, amount_param numeric, confirmations_param int)
  returns text language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare eid bigint; owner_pub text; need int; dep chain_deposit%rowtype;
begin
  if memo !~ '^oc[0-9]+$' then return 'no_memo'; end if;
  eid := substring(memo from 3)::bigint;
  if not exists (select 1 from app_entity where id = eid) then return 'unknown_user'; end if;
  select confirmations into need from chain where name = chain_param;

  insert into chain_deposit(chain, txid, log_index, address, currency, amount, confirmations)
    values (chain_param, txid_param, log_index_param, memo, currency_param, amount_param, confirmations_param)
    on conflict (chain, txid, log_index) do update set confirmations = excluded.confirmations
    returning * into dep;
  if dep.credited_at is not null then return 'duplicate'; end if;
  if confirmations_param < coalesce(need, 1) then return 'pending'; end if;

  select pub_id into owner_pub from app_entity where id = eid;
  begin perform create_currency_account(owner_pub, currency_param); exception when others then null; end;
  perform process_transfer('DEPOSIT', 'MASTER', amount_param, currency_param, owner_pub,
            chain_param || ':' || txid_param, 'chain deposit (memo)', null);
  update chain_deposit set credited_at = now() where id = dep.id;
  return 'credited';
end $$;

-- my_deposit_address now branches on the chain's addressing mode.
create or replace function my_deposit_address(chain_param text) returns jsonb
  language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare eid bigint := current_app_entity_id(); k text; mode text; addr text; priv bytea;
begin
  if eid is null then raise exception 'not_authenticated'; end if;
  select kind, addressing into k, mode from chain where name = chain_param;
  if k is null then raise exception 'unknown_chain: %', chain_param; end if;

  if mode = 'shared_memo' then
    -- one shared house address; the per-user memo disambiguates deposits
    return jsonb_build_object('chain', chain_param, 'kind', k, 'mode', 'memo',
                             'address', public.treasury_address(chain_param), 'memo', 'oc' || eid);
  end if;

  -- derived (unique per-user address)
  select address into addr from user_chain_wallet where app_entity_id = eid and chain = chain_param;
  if addr is null then
    if k = 'evm' then priv := public._derive_secp_priv(eid, chain_param); addr := public.evm_address(priv);
    elsif k = 'tron' then priv := public._derive_secp_priv(eid, chain_param); addr := public.tron_address_from_priv(priv);
    elsif k = 'solana' then addr := public.sol_address_from_eid(eid);
    else raise exception 'unsupported_chain_kind: %', k; end if;
    insert into user_chain_wallet(app_entity_id, chain, address) values (eid, chain_param, addr)
      on conflict (app_entity_id, chain) do update set address = excluded.address returning address into addr;
    insert into watched_address(app_entity_id, chain, address) values (eid, chain_param, addr)
      on conflict (chain, address) do nothing;
  end if;
  return jsonb_build_object('chain', chain_param, 'kind', k, 'mode', 'derived', 'address', addr);
end $$;

-- Tron memo deposit poller: scan incoming native TRX to the shared house address,
-- read the note (raw_data.data → UTF-8) and credit the matching user.
create or replace function poll_tron_memo(chain_param text) returns int
  language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare cfg chain%rowtype; shared text; cur text; dec int; resp jsonb; t jsonb; c jsonb;
        memo text; amt numeric; n int := 0;
begin
  select * into cfg from chain where name = chain_param and enabled and kind = 'tron' and rpc_url is not null;
  if not found then return 0; end if;
  shared := public.treasury_address(chain_param);
  select currency, decimals into cur, dec from chain_asset where chain = chain_param and token = 'native';
  resp := (extensions.http_get(cfg.rpc_url || '/v1/accounts/' || shared || '/transactions?limit=50&only_confirmed=true')).content::jsonb;
  for t in select * from jsonb_array_elements(coalesce(resp->'data', '[]'::jsonb)) loop
    c := t->'raw_data'->'contract'->0;
    if c->>'type' <> 'TransferContract' then continue; end if;                 -- native TRX only
    if (c->'parameter'->'value'->>'to_address') is distinct from shared then continue; end if;
    if (t->'raw_data'->>'data') is null then continue; end if;                  -- no memo → skip
    memo := convert_from(decode(t->'raw_data'->>'data', 'hex'), 'UTF8');
    amt := (c->'parameter'->'value'->>'amount')::numeric / power(10, dec);
    if credit_memo_deposit(chain_param, t->>'txID', 0, memo, cur, amt, 1) = 'credited' then n := n + 1; end if;
  end loop;
  return n;
end $$;

do $$ begin
  perform cron.schedule('poll-tron-memo', '30 seconds', 'select poll_tron_memo(''tron-nile'')');
exception when others then null; end $$;

revoke execute on function
  credit_memo_deposit(text,text,int,text,text,numeric,int), poll_tron_memo(text)
  from public, anon, authenticated;
grant execute on function credit_memo_deposit(text,text,int,text,text,numeric,int), poll_tron_memo(text) to service_role;
grant execute on function my_deposit_memo() to authenticated;
revoke execute on function my_deposit_memo() from public, anon;
