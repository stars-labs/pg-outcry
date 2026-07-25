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
