-- API keys, referral, withdrawal security, derivatives, OHLCV, in-DB crypto primitives
--
-- Squashed from the pre-launch incremental migrations, concatenated in their
-- original apply order (so the resulting schema is identical). Section headers
-- below name the migration each block came from.


-- ══ 00680_api_keys.sql ══════════════════════════════════════════

-- Per-user API keys (pure-SQL, for bots / market-makers).
--
-- A client creates a key while logged in (gets the plaintext secret ONCE), then
-- exchanges (key_id, secret) for a short-lived Supabase JWT minted in-DB with
-- pgcrypto HMAC. The bot uses that JWT as a normal bearer token, so every
-- existing RLS policy and RPC works unchanged — no separate auth plane.
--
-- Numbered >9900 so 9900_lockdown (which revokes+regrants all functions) does
-- not strip these grants.

create table if not exists api_key (
  id            bigint generated always as identity primary key,
  app_entity_id bigint not null references app_entity(id) on delete cascade,
  key_id        text unique not null default ('ock_' || encode(extensions.gen_random_bytes(9), 'hex')),
  secret_hash   text not null,                      -- sha256(hex) of the plaintext secret
  label         text,
  scopes        text[] not null default '{trade}',  -- informational (read/trade/withdraw)
  created_at    timestamptz not null default now(),
  last_used_at  timestamptz,
  revoked_at    timestamptz
);
create index if not exists api_key_entity_idx on api_key(app_entity_id);

alter table api_key enable row level security;
drop policy if exists own_api_key on api_key;
create policy own_api_key on api_key for select to authenticated
  using (app_entity_id = current_app_entity_id());

-- own keys without the secret hash
create or replace view api_keys as
  select key_id, label, scopes, created_at, last_used_at, revoked_at
  from api_key;
alter view api_keys set (security_invoker = on);

-- base64url(bytea): + -> -, / -> _, strip '=' and any newline encode() inserts
create or replace function _b64url(data bytea) returns text
  language sql immutable as $$ select translate(encode(data, 'base64'), E'+/=\n', '-_'); $$;

-- create a key; returns the plaintext secret ONCE (never retrievable again)
create or replace function create_api_key(label_param text default null,
                                          scopes_param text[] default '{trade}')
  returns json language plpgsql security definer set search_path = public, pg_temp
as $$
declare eid bigint := current_app_entity_id(); secret text; r api_key%rowtype;
begin
  if eid is null then raise exception 'not_authenticated'; end if;
  secret := 'ocs_' || encode(extensions.gen_random_bytes(24), 'hex');
  insert into api_key(app_entity_id, secret_hash, label, scopes)
    values (eid, encode(extensions.digest(secret, 'sha256'), 'hex'), label_param, scopes_param)
    returning * into r;
  return json_build_object('key_id', r.key_id, 'secret', secret, 'scopes', r.scopes,
    'note', 'store the secret now — it is not retrievable later');
end $$;

create or replace function revoke_api_key(key_id_param text)
  returns boolean language plpgsql security definer set search_path = public, pg_temp
as $$
declare eid bigint := current_app_entity_id(); n int;
begin
  if eid is null then raise exception 'not_authenticated'; end if;
  update api_key set revoked_at = now()
    where key_id = key_id_param and app_entity_id = eid and revoked_at is null;
  get diagnostics n = row_count;
  return n > 0;
end $$;

-- exchange (key_id, secret) for a short-lived JWT (HS256, signed with the
-- project jwt secret). Callable by anon: the bot starts from the anon key.
create or replace function api_key_login(key_id_param text, secret_param text,
                                         ttl_seconds int default 900)
  returns json language plpgsql security definer set search_path = public, pg_temp
as $$
declare
  k api_key%rowtype; uid uuid; jwt_secret text;
  header text; payload text; body text; sig text; jwt text; iat bigint; exp bigint;
begin
  select * into k from api_key where key_id = key_id_param and revoked_at is null;
  if not found or k.secret_hash <> encode(extensions.digest(secret_param, 'sha256'), 'hex') then
    raise exception 'invalid_api_key';
  end if;
  select user_id into uid from app_user where app_entity_id = k.app_entity_id limit 1;
  if uid is null then raise exception 'no_user_for_key'; end if;

  jwt_secret := current_setting('app.settings.jwt_secret', true);
  if jwt_secret is null or jwt_secret = '' then raise exception 'jwt_secret_unavailable'; end if;
  ttl_seconds := least(greatest(ttl_seconds, 60), 86400);   -- clamp 1min..1day
  iat := extract(epoch from now())::bigint;
  exp := iat + ttl_seconds;

  header  := _b64url(convert_to('{"alg":"HS256","typ":"JWT"}', 'utf8'));
  payload := _b64url(convert_to(json_build_object(
               'role', 'authenticated', 'aud', 'authenticated',
               'sub', uid::text, 'iat', iat, 'exp', exp)::text, 'utf8'));
  body := header || '.' || payload;
  sig  := _b64url(extensions.hmac(body, jwt_secret, 'sha256'));
  jwt  := body || '.' || sig;

  update api_key set last_used_at = now() where id = k.id;
  return json_build_object('access_token', jwt, 'token_type', 'bearer', 'expires_in', ttl_seconds);
end $$;

grant select on api_keys to authenticated;
grant execute on function create_api_key(text, text[]), revoke_api_key(text) to authenticated;
grant execute on function api_key_login(text, text, int) to anon, authenticated;
-- Supabase default privileges auto-grant new public functions to anon; revoke the
-- ones that must be authenticated-only (api_key_login stays anon-callable by design).
revoke execute on function create_api_key(text, text[]), revoke_api_key(text) from public, anon;


-- ══ 00690_referral.sql ══════════════════════════════════════════

-- Referral / affiliate program (pure-SQL).
--
-- OPEX dedicates a whole microservice to this; here it's a few tables + a trigger:
--   * each entity has a referral_code
--   * a new user attributes themselves to a referrer ONCE (set_my_referrer)
--   * an AFTER-INSERT trigger on `trade` accrues commission for the taker's
--     referrer as a referral_earning row (a percentage of traded notional)
--   * an admin RPC pays accrued earnings out as a real ledger transfer from MASTER
--
-- Numbered >9900 so 9900_lockdown does not strip the grants.

create table if not exists referral_code (
  app_entity_id bigint primary key references app_entity(id) on delete cascade,
  code          text unique not null,
  created_at    timestamptz not null default now()
);

create table if not exists referral (
  referred_entity bigint primary key references app_entity(id) on delete cascade,
  referrer_entity bigint not null references app_entity(id) on delete cascade,
  created_at      timestamptz not null default now(),
  check (referred_entity <> referrer_entity)
);
create index if not exists referral_referrer_idx on referral(referrer_entity);

create table if not exists referral_earning (
  id              bigint generated always as identity primary key,
  referrer_entity bigint not null references app_entity(id) on delete cascade,
  referred_entity bigint not null references app_entity(id) on delete cascade,
  trade_id        bigint not null,
  currency        text not null,
  amount          numeric not null check (amount >= 0),
  paid_at         timestamptz,
  created_at      timestamptz not null default now()
);
create index if not exists referral_earning_referrer_idx on referral_earning(referrer_entity) where paid_at is null;

-- commission rate as a fraction of traded notional (quote). Reference default:
-- 2 bps. A production venue would base this on the taker fee instead.
create table if not exists referral_config (
  id smallint primary key default 1 check (id = 1),
  commission_rate numeric not null default 0.0002
);
insert into referral_config(id) values (1) on conflict do nothing;

-- accrue commission for the taker's referrer on every trade
create or replace function accrue_referral_commission() returns trigger
  language plpgsql security definer set search_path = public, pg_temp
as $$
declare taker_eid bigint; ref_eid bigint; quote text; prec int; rate numeric;
begin
  select ia.app_entity_id into taker_eid
    from trade_order o join instrument_account ia on ia.id = o.instrument_account_id
    where o.id = new.taker_order_id;
  if taker_eid is null then return new; end if;

  select referrer_entity into ref_eid from referral where referred_entity = taker_eid;
  if ref_eid is null then return new; end if;

  select i.quote_currency into quote from instrument i where i.id = new.instrument_id;
  select c.precision into prec from currency c where c.name = quote;
  select commission_rate into rate from referral_config where id = 1;

  insert into referral_earning(referrer_entity, referred_entity, trade_id, currency, amount)
    values (ref_eid, taker_eid, new.id, quote,
            banker_round(new.price * new.amount * rate, coalesce(prec, 2)));
  return new;
end $$;

drop trigger if exists trg_referral_commission on trade;
create trigger trg_referral_commission after insert on trade
  for each row execute function accrue_referral_commission();

-- get (creating if absent) the caller's referral code
create or replace function my_referral_code() returns text
  language plpgsql security definer set search_path = public, pg_temp
as $$
declare eid bigint := current_app_entity_id(); c text;
begin
  if eid is null then raise exception 'not_authenticated'; end if;
  select code into c from referral_code where app_entity_id = eid;
  if c is null then
    c := upper(substr(encode(extensions.gen_random_bytes(6), 'hex'), 1, 8));
    insert into referral_code(app_entity_id, code) values (eid, c)
      on conflict (app_entity_id) do update set code = referral_code.code
      returning code into c;
  end if;
  return c;
end $$;

-- one-time attribution to a referrer
create or replace function set_my_referrer(code_param text) returns boolean
  language plpgsql security definer set search_path = public, pg_temp
as $$
declare eid bigint := current_app_entity_id(); ref_eid bigint;
begin
  if eid is null then raise exception 'not_authenticated'; end if;
  if exists (select 1 from referral where referred_entity = eid) then
    raise exception 'referrer_already_set';
  end if;
  select app_entity_id into ref_eid from referral_code where code = upper(code_param);
  if ref_eid is null then raise exception 'invalid_referral_code'; end if;
  if ref_eid = eid then raise exception 'cannot_refer_self'; end if;
  insert into referral(referred_entity, referrer_entity) values (eid, ref_eid);
  return true;
end $$;

-- caller's own referral summary
create or replace view referral_summary as
  select
    ae.id as app_entity_id,
    (select code from referral_code rc where rc.app_entity_id = ae.id) as my_code,
    (select count(*) from referral r where r.referrer_entity = ae.id) as referred_count,
    coalesce((select sum(amount) from referral_earning e
              where e.referrer_entity = ae.id), 0) as total_earned,
    coalesce((select sum(amount) from referral_earning e
              where e.referrer_entity = ae.id and e.paid_at is null), 0) as unpaid_earned
  from app_entity ae
  where ae.id = current_app_entity_id();

-- admin: pay out a referrer's unpaid earnings as a real ledger transfer from MASTER
create or replace function pay_referral_earnings(entity_pub text, currency_param text)
  returns numeric language plpgsql security definer set search_path = public, pg_temp
as $$
declare eid bigint; total numeric;
begin
  select id into eid from app_entity where pub_id = entity_pub;
  if eid is null then raise exception 'entity_not_found'; end if;
  select coalesce(sum(amount), 0) into total from referral_earning
    where referrer_entity = eid and currency = currency_param and paid_at is null;
  if total <= 0 then return 0; end if;
  perform process_transfer('DEPOSIT', 'MASTER', total, currency_param, entity_pub,
                           'referral', 'referral payout', null);
  update referral_earning set paid_at = now()
    where referrer_entity = eid and currency = currency_param and paid_at is null;
  return total;
end $$;

-- RLS: own referral data only
alter table referral_code   enable row level security;
alter table referral        enable row level security;
alter table referral_earning enable row level security;
drop policy if exists own_referral_code on referral_code;
create policy own_referral_code on referral_code for select to authenticated
  using (app_entity_id = current_app_entity_id());
drop policy if exists own_referral on referral;
create policy own_referral on referral for select to authenticated
  using (referrer_entity = current_app_entity_id() or referred_entity = current_app_entity_id());
drop policy if exists own_referral_earning on referral_earning;
create policy own_referral_earning on referral_earning for select to authenticated
  using (referrer_entity = current_app_entity_id());

grant select on referral_summary to authenticated;
grant execute on function my_referral_code(), set_my_referrer(text) to authenticated;
grant execute on function pay_referral_earnings(text, text) to service_role;
-- authenticated-only (revoke the Supabase default anon grant); payout is admin-only
revoke execute on function my_referral_code(), set_my_referrer(text) from public, anon;
revoke execute on function pay_referral_earnings(text, text) from public, anon, authenticated;


-- ══ 00700_withdrawal_whitelist.sql ══════════════════════════════════════════

-- Withdrawal security: address whitelist (with a cooling period) + rolling-window
-- limits. A withdrawal to an address is only allowed once the address has been
-- whitelisted and its cooling period has elapsed, and only if it stays under the
-- per-currency limit over the trailing window.
--
-- Numbered >9900 so 9900_lockdown does not strip the grants.

alter table wallet_request add column if not exists to_address text;

create table if not exists withdrawal_address (
  id            bigint generated always as identity primary key,
  app_entity_id bigint not null references app_entity(id) on delete cascade,
  currency      text not null,
  address       text not null,
  label         text,
  created_at    timestamptz not null default now(),
  active_at     timestamptz not null default now() + interval '24 hours',  -- cooling period
  removed_at    timestamptz,
  unique (app_entity_id, currency, address)
);
create index if not exists withdrawal_address_entity_idx on withdrawal_address(app_entity_id);

-- per-currency rolling-window limit (global defaults; a venue can tune per row)
create table if not exists withdrawal_limit (
  currency     text primary key,
  window_hours int   not null default 24,
  max_amount   numeric not null
);
insert into withdrawal_limit(currency, max_amount) values
  ('EUR', 50000), ('BTC', 5)
on conflict do nothing;

create or replace function add_withdrawal_address(currency_param text, address_param text,
                                                  label_param text default null)
  returns json language plpgsql security definer set search_path = public, pg_temp
as $$
declare eid bigint := current_app_entity_id(); r withdrawal_address%rowtype;
begin
  if eid is null then raise exception 'not_authenticated'; end if;
  if coalesce(trim(address_param), '') = '' then raise exception 'address_required'; end if;
  insert into withdrawal_address(app_entity_id, currency, address, label)
    values (eid, currency_param, address_param, label_param)
    on conflict (app_entity_id, currency, address) do update
      set removed_at = null, label = excluded.label  -- re-add resets removal (cooling already passed)
    returning * into r;
  return json_build_object('id', r.id, 'currency', r.currency, 'address', r.address,
    'active_at', r.active_at, 'note', 'usable after the cooling period (active_at)');
end $$;

create or replace function remove_withdrawal_address(address_id_param bigint)
  returns boolean language plpgsql security definer set search_path = public, pg_temp
as $$
declare eid bigint := current_app_entity_id(); n int;
begin
  if eid is null then raise exception 'not_authenticated'; end if;
  update withdrawal_address set removed_at = now()
    where id = address_id_param and app_entity_id = eid and removed_at is null;
  get diagnostics n = row_count; return n > 0;
end $$;

-- whitelisted, cooled, rolling-limit-checked withdrawal request.
create or replace function request_withdrawal_to(
    currency_param text, amount_param numeric, to_address_param text,
    idempotency_key_param text default null)
  returns text language plpgsql security definer set search_path = public, pg_temp
as $$
declare
  eid bigint := current_app_entity_id();
  ca currency_account%rowtype; req text;
  win int; lim numeric; used numeric;
begin
  if eid is null then raise exception 'not_authenticated'; end if;
  perform assert_entity_active(eid);
  if amount_param <= 0 then raise exception 'amount_must_be_positive'; end if;

  -- address must be whitelisted and past its cooling period
  if not exists (select 1 from withdrawal_address w
                 where w.app_entity_id = eid and w.currency = currency_param
                   and w.address = to_address_param and w.removed_at is null
                   and w.active_at <= now()) then
    raise exception 'address_not_whitelisted_or_cooling: %', to_address_param;
  end if;

  -- rolling-window limit (counts pending + completed requests in the window)
  select window_hours, max_amount into win, lim from withdrawal_limit where currency = currency_param;
  if lim is not null then
    select coalesce(sum(amount), 0) into used from wallet_request
      where app_entity_id = eid and direction = 'WITHDRAWAL' and currency = currency_param
        and status <> 'REJECTED' and created_at > now() - make_interval(hours => win);
    if used + amount_param > lim then
      raise exception 'withdrawal_limit_exceeded: % + % > % per %h',
        used, amount_param, lim, win;
    end if;
  end if;

  -- idempotency replay
  if idempotency_key_param is not null then
    select pub_id into req from wallet_request
      where app_entity_id = eid and idempotency_key = idempotency_key_param;
    if found then return req; end if;
  end if;

  select * into ca from currency_account where app_entity_id = eid and currency_name = currency_param;
  if not found then raise exception 'no_currency_account: %', currency_param; end if;
  if ca.amount - ca.amount_reserved < amount_param then
    raise exception 'insufficient_available_balance: available %, requested %',
      ca.amount - ca.amount_reserved, amount_param;
  end if;

  begin
    insert into wallet_request(app_entity_id, direction, currency, amount, idempotency_key, to_address)
      values (eid, 'WITHDRAWAL', currency_param, amount_param, idempotency_key_param, to_address_param)
      returning pub_id into req;
  exception when unique_violation then
    select pub_id into req from wallet_request
      where app_entity_id = eid and idempotency_key = idempotency_key_param;
    return req;
  end;

  update currency_account
    set amount_reserved = amount_reserved + amount_param, updated_at = current_timestamp
    where id = ca.id;
  return req;
end $$;

-- own whitelisted addresses
create or replace view withdrawal_addresses as
  select id, currency, address, label, created_at, active_at,
         (active_at <= now()) as usable
  from withdrawal_address where removed_at is null;
alter view withdrawal_addresses set (security_invoker = on);
alter table withdrawal_address enable row level security;
drop policy if exists own_withdrawal_address on withdrawal_address;
create policy own_withdrawal_address on withdrawal_address for select to authenticated
  using (app_entity_id = current_app_entity_id());

grant select on withdrawal_addresses to authenticated;
grant execute on function add_withdrawal_address(text, text, text),
                          remove_withdrawal_address(bigint),
                          request_withdrawal_to(text, numeric, text, text) to authenticated;
-- authenticated-only (revoke the Supabase default anon grant)
revoke execute on function add_withdrawal_address(text, text, text),
                           remove_withdrawal_address(bigint),
                           request_withdrawal_to(text, numeric, text, text) from public, anon;


-- ══ 00710_chain_deposits.sql ══════════════════════════════════════════

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


-- ══ 00720_withdrawal_queue.sql ══════════════════════════════════════════

-- Withdrawal send-queue: hand APPROVED on-chain withdrawals to an external signer.
--
-- Why an external signer at all? pgcrypto (schema `extensions`) has no secp256k1
-- or keccak, so Postgres cannot sign an EVM transaction. Deposits CAN be watched
-- in-DB (9920), but a WITHDRAWAL must be signed+broadcast by an outside process
-- that holds the hot key. This migration is ONLY the on-chain send bookkeeping;
-- it never moves ledger funds.
--
-- LEDGER NOTE — do NOT double-spend: approve_wallet_request (9300) already did
-- the money side for a WITHDRAWAL: it create_transfer'd user -> MASTER AND
-- released the reservation (amount_reserved -= amount). By the time a row is
-- APPROVED with a to_address, the user has already been debited. So the signer
-- queue here strictly tracks "did we put it on the chain yet", with NO currency_
-- account / transfer writes whatsoever.
--
-- Numbered >9900 so 9900_lockdown's deny-by-default sweep does not strip these
-- grants (it runs once, earlier; new funcs created here keep their grants).

-- ── lifecycle columns on wallet_request ──────────────────────────────────────
-- A withdrawal's on-chain send moves through:
--   APPROVED (status) + to_address set      -> eligible to claim
--   signing_claimed_at set                  -> a signer owns it (won't be re-handed out)
--   broadcast_txid + broadcast_at set       -> tx is on the chain
--   confirmed_at set                        -> tx is mined/confirmed (terminal)
alter table wallet_request add column if not exists signing_claimed_at timestamptz;
alter table wallet_request add column if not exists broadcast_txid     text;
alter table wallet_request add column if not exists broadcast_at       timestamptz;
alter table wallet_request add column if not exists confirmed_at       timestamptz;

-- ── service_role: claim the next withdrawal to sign ──────────────────────────
-- Atomic claim so two concurrent signers never both send the same withdrawal.
-- The SELECT ... FOR UPDATE SKIP LOCKED row-locks one eligible row (skipping any
-- a sibling signer already holds in its open transaction); we then stamp
-- signing_claimed_at inside the SAME transaction so once committed the row no
-- longer matches the `signing_claimed_at is null` predicate. Result: each
-- withdrawal is handed out at most once. (broadcast_txid is also re-checked so a
-- crashed-before-commit claim that left no stamp still can't be re-broadcast once
-- a txid exists.)
create or replace function next_withdrawal_to_sign()
  returns json
  language plpgsql security definer set search_path = public, pg_temp
as $$
declare r wallet_request%rowtype;
begin
  select * into r from wallet_request
   where direction = 'WITHDRAWAL'
     and status = 'APPROVED'
     and to_address is not null
     and signing_claimed_at is null
     and broadcast_txid is null
   order by resolved_at nulls last, id
   for update skip locked
   limit 1;
  if not found then return null; end if;

  update wallet_request set signing_claimed_at = current_timestamp where id = r.id;

  return json_build_object(
    'pub_id',     r.pub_id,
    'currency',   r.currency,
    'amount',     r.amount,
    'to_address', r.to_address);
end $$;

-- ── service_role: record broadcast (idempotent) ──────────────────────────────
-- Stamp the on-chain tx hash. No-op if a txid is already recorded so a signer
-- retry never overwrites the first broadcast.
create or replace function mark_withdrawal_broadcast(request_pub text, txid text)
  returns boolean
  language plpgsql security definer set search_path = public, pg_temp
as $$
declare n int;
begin
  if coalesce(trim(txid), '') = '' then raise exception 'txid_required'; end if;
  update wallet_request
     set broadcast_txid = txid, broadcast_at = current_timestamp
   where pub_id = request_pub
     and direction = 'WITHDRAWAL'
     and broadcast_txid is null;        -- idempotent: don't clobber an existing txid
  get diagnostics n = row_count;
  if n > 0 then return true; end if;
  -- already broadcast (idempotent replay) is success; a missing row is an error
  if exists (select 1 from wallet_request where pub_id = request_pub) then return false; end if;
  raise exception 'request_not_found: %', request_pub;
end $$;

-- ── service_role: record confirmation (idempotent) ───────────────────────────
create or replace function mark_withdrawal_confirmed(request_pub text)
  returns boolean
  language plpgsql security definer set search_path = public, pg_temp
as $$
declare n int;
begin
  update wallet_request
     set confirmed_at = current_timestamp
   where pub_id = request_pub
     and direction = 'WITHDRAWAL'
     and broadcast_txid is not null     -- can only confirm something we broadcast
     and confirmed_at is null;          -- idempotent
  get diagnostics n = row_count;
  if n > 0 then return true; end if;
  if exists (select 1 from wallet_request where pub_id = request_pub and confirmed_at is not null)
    then return false; end if;          -- already confirmed: idempotent replay
  raise exception 'not_broadcast_or_not_found: %', request_pub;
end $$;

-- ── grants ───────────────────────────────────────────────────────────────────
-- These are the operator/signer plane only. Users see send status through the
-- existing wallet_request RLS select grant (broadcast_txid / confirmed_at are
-- now visible on their own rows) — they must NOT be able to claim or mark.
-- Supabase default privileges auto-grant EXECUTE on every new public function to
-- anon+authenticated, so revoke from those roles explicitly (not just PUBLIC).
revoke execute on function
  next_withdrawal_to_sign(),
  mark_withdrawal_broadcast(text,text),
  mark_withdrawal_confirmed(text)
  from public, anon, authenticated;
grant execute on function
  next_withdrawal_to_sign(),
  mark_withdrawal_broadcast(text,text),
  mark_withdrawal_confirmed(text)
  to service_role;


-- ══ 00730_staking.sql ══════════════════════════════════════════

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


-- ══ 00740_margin.sql ══════════════════════════════════════════

-- Spot margin (pure SQL, MVP) — borrow against collateral, with lazy interest
-- accrual and a liquidation monitor. Cross-margin, valued in the quote currency
-- (EUR) via last trade prices. All money movement reuses process_transfer so
-- reconciliation holds: borrow = DEPOSIT MASTER→user (the house lends), repay =
-- WITHDRAWAL user→MASTER, liquidation = seize collateral → MASTER. The loan is
-- tracked in margin_loan (a liability table, separate from the cash ledger).
--
-- SIMPLIFIED vs production: liquidation is a forced settlement at the mark price
-- (seize collateral, clear debt, shortfall borne by the house) rather than routing
-- a market order through the book; no partial liquidation / insurance fund / ADL.
-- See docs/DERIVATIVES.md. Numbered >9900 so 9900_lockdown keeps grants.

create table if not exists margin_config (
  id smallint primary key default 1 check (id = 1),
  max_leverage      numeric not null default 3,     -- total debt ≤ equity*(L-1)
  maintenance_ratio numeric not null default 0.1,   -- liquidate when equity ≤ debt*ratio
  borrow_apr        numeric not null default 0.10
);
insert into margin_config(id) values (1) on conflict do nothing;

create table if not exists margin_loan (
  app_entity_id bigint not null references app_entity(id) on delete cascade,
  currency      text   not null,
  principal     numeric not null default 0 check (principal >= 0),
  accrued       numeric not null default 0 check (accrued >= 0),
  updated_at    timestamptz not null default now(),
  primary key (app_entity_id, currency)
);

create table if not exists margin_liquidation (
  id bigint generated always as identity primary key,
  app_entity_id bigint not null,
  debt_value numeric, collateral_value numeric, at timestamptz not null default now()
);

-- value of 1 unit of `cur` in the EUR quote (EUR=1; else last trade of <cur>_EUR; else 0)
create or replace function _margin_price(cur text) returns numeric
  language sql stable security definer set search_path = public, pg_temp as $$
  select case when cur = 'EUR' then 1
    else coalesce((select t.price from trade t join instrument i on i.id = t.instrument_id
                   where i.name = cur || '_EUR' order by t.created_at desc limit 1), 0) end;
$$;

-- accrue interest on all of an entity's loans (lazy)
create or replace function _margin_accrue(eid bigint) returns void
  language plpgsql security definer set search_path = public, pg_temp as $$
declare apr numeric;
begin
  select borrow_apr into apr from margin_config where id = 1;
  update margin_loan set
    accrued = accrued + (principal + accrued) * (apr / 31557600.0) * extract(epoch from now() - updated_at),
    updated_at = now()
  where app_entity_id = eid and (principal + accrued) > 0;
end $$;

-- (collateral_value, debt_value, equity) in EUR
create or replace function _margin_state(eid bigint, out collateral numeric, out debt numeric, out equity numeric)
  language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  select coalesce(sum(amount * _margin_price(currency_name)), 0) into collateral
    from currency_account where app_entity_id = eid;
  select coalesce(sum((principal + accrued) * _margin_price(currency)), 0) into debt
    from margin_loan where app_entity_id = eid;
  equity := collateral - debt;
end $$;

create or replace function borrow(currency_param text, amount_param numeric) returns numeric
  language plpgsql security definer set search_path = public, pg_temp as $$
declare eid bigint := current_app_entity_id(); pub text; cfg margin_config%rowtype; st record; addv numeric;
begin
  if eid is null then raise exception 'not_authenticated'; end if;
  if amount_param <= 0 then raise exception 'amount_must_be_positive'; end if;
  select * into cfg from margin_config where id = 1;
  perform _margin_accrue(eid);
  select * into st from _margin_state(eid);
  addv := amount_param * _margin_price(currency_param);
  if addv = 0 then raise exception 'unpriced_currency: %', currency_param; end if;
  -- borrowing leaves equity unchanged (collateral and debt both += addv); cap total debt
  if st.debt + addv > st.equity * (cfg.max_leverage - 1) + 1e-9 then
    raise exception 'exceeds_max_leverage: debt % + new % > equity % * (L-1)', st.debt, addv, st.equity;
  end if;
  select pub_id into pub from app_entity where id = eid;
  begin perform create_currency_account(pub, currency_param); exception when others then null; end;
  perform process_transfer('DEPOSIT', 'MASTER', amount_param, currency_param, pub, 'margin', 'borrow', null);
  insert into margin_loan(app_entity_id, currency, principal) values (eid, currency_param, amount_param)
    on conflict (app_entity_id, currency) do update set principal = margin_loan.principal + excluded.principal;
  return amount_param;
end $$;

create or replace function repay(currency_param text, amount_param numeric) returns numeric
  language plpgsql security definer set search_path = public, pg_temp as $$
declare eid bigint := current_app_entity_id(); pub text; ln margin_loan%rowtype; pay numeric; ca numeric;
begin
  if eid is null then raise exception 'not_authenticated'; end if;
  perform _margin_accrue(eid);
  select * into ln from margin_loan where app_entity_id = eid and currency = currency_param for update;
  if not found then raise exception 'no_loan: %', currency_param; end if;
  select pub_id into pub from app_entity where id = eid;
  select amount - amount_reserved into ca from currency_account where app_entity_id = eid and currency_name = currency_param;
  pay := least(amount_param, ln.principal + ln.accrued, coalesce(ca, 0));
  if pay <= 0 then raise exception 'nothing_to_repay_or_insufficient_balance'; end if;
  perform process_transfer('WITHDRAWAL', pub, pay, currency_param, 'MASTER', 'margin', 'repay', null);
  -- pay interest first, then principal
  if pay >= ln.accrued then
    update margin_loan set principal = principal - (pay - accrued), accrued = 0, updated_at = now()
      where app_entity_id = eid and currency = currency_param;
  else
    update margin_loan set accrued = accrued - pay, updated_at = now()
      where app_entity_id = eid and currency = currency_param;
  end if;
  delete from margin_loan where app_entity_id = eid and currency = currency_param and principal <= 0 and accrued <= 0;
  return pay;
end $$;

-- liquidation monitor (pg_cron): seize collateral of under-margined accounts
create or replace function check_margin_liquidations() returns int
  language plpgsql security definer set search_path = public, pg_temp as $$
declare e bigint; cfg margin_config%rowtype; st record; pub text; c record; n int := 0;
begin
  select * into cfg from margin_config where id = 1;
  for e in select distinct app_entity_id from margin_loan where principal + accrued > 0 loop
    perform _margin_accrue(e);
    select * into st from _margin_state(e);
    if st.debt > 0 and st.equity <= st.debt * cfg.maintenance_ratio then
      select pub_id into pub from app_entity where id = e;
      -- forced settlement at mark: seize all free collateral to the house, clear debt
      for c in select currency_name, amount - amount_reserved as free from currency_account
               where app_entity_id = e and amount - amount_reserved > 0 loop
        perform process_transfer('WITHDRAWAL', pub, c.free, c.currency_name, 'MASTER', 'margin', 'liquidation', null);
      end loop;
      delete from margin_loan where app_entity_id = e;
      insert into margin_liquidation(app_entity_id, debt_value, collateral_value)
        values (e, st.debt, st.collateral);
      n := n + 1;
    end if;
  end loop;
  return n;
end $$;
do $$ begin perform cron.schedule('check-margin', '30 seconds', 'select check_margin_liquidations()');
exception when others then null; end $$;

create or replace view my_margin as
  select l.currency, l.principal, l.accrued, (l.principal + l.accrued) as debt
  from margin_loan l where l.app_entity_id = current_app_entity_id();
alter view my_margin set (security_invoker = on);
create or replace view margin_terms as select max_leverage, maintenance_ratio, borrow_apr from margin_config;

-- caller's account health (collateral / debt / equity in EUR) — auth-callable wrapper
-- around the internal _margin_state (which stays operator-only)
create or replace function my_margin_health(out collateral numeric, out debt numeric, out equity numeric)
  language plpgsql security definer set search_path = public, pg_temp as $$
declare eid bigint := current_app_entity_id();
begin
  if eid is null then raise exception 'not_authenticated'; end if;
  perform _margin_accrue(eid);
  select * into collateral, debt, equity from _margin_state(eid);
end $$;

alter table margin_loan enable row level security;
drop policy if exists own_margin_loan on margin_loan;
create policy own_margin_loan on margin_loan for select to authenticated
  using (app_entity_id = current_app_entity_id());

grant select on my_margin, margin_terms to authenticated;
grant execute on function borrow(text,numeric), repay(text,numeric), my_margin_health() to authenticated;
revoke execute on function my_margin_health() from public, anon;
grant execute on function check_margin_liquidations() to service_role;
revoke execute on function borrow(text,numeric), repay(text,numeric) from public, anon;
revoke execute on function check_margin_liquidations(), _margin_accrue(bigint), _margin_state(bigint), _margin_price(text)
  from public, anon, authenticated;


-- ══ 00750_perp.sql ══════════════════════════════════════════

-- Perpetual futures (pure SQL, MVP) — position-based linear perp, EUR-margined.
-- Open/close a signed position with posted margin, mark-to-market uPnL, periodic
-- funding (pg_cron), and a liquidation monitor (pg_cron). The house (MASTER) is
-- the counterparty/insurance for this MVP. All cash moves via process_transfer so
-- reconciliation holds; perp_position holds the off-ledger position state.
--
-- Mark price: set by an oracle (update_perp_mark, pg_cron) from the spot last
-- trade of the index symbol — or override perp_market.mark_price directly (and via
-- pg_net for a real external index). Numbered >9900 so 9900_lockdown keeps grants.
--
-- SIMPLIFIED vs production: one (netted) position per market, open-from-flat only;
-- liquidation seizes remaining margin at the mark (no partial close / book routing
-- / ADL); funding/PnL settle against the house, not netted long-vs-short.
-- See docs/DERIVATIVES.md.

create table if not exists perp_market (
  symbol            text primary key,        -- e.g. 'BTC-PERP'
  index_symbol      text not null,           -- spot to read for the index, e.g. 'BTC_EUR'
  margin_currency   text not null default 'EUR',
  mark_price        numeric,                 -- set by the oracle / update_perp_mark
  funding_rate      numeric not null default 0,   -- per funding interval (long pays short if >0)
  max_leverage      numeric not null default 10,
  maintenance_ratio numeric not null default 0.05,
  updated_at        timestamptz not null default now()
);
insert into perp_market(symbol, index_symbol) values ('BTC-PERP', 'BTC_EUR') on conflict do nothing;

create table if not exists perp_position (
  app_entity_id bigint not null references app_entity(id) on delete cascade,
  symbol        text   not null references perp_market(symbol),
  size          numeric not null,            -- signed: + long, - short (base units)
  entry_price   numeric not null,
  margin        numeric not null,            -- trader's claim on the margin pool (margin_currency)
  updated_at    timestamptz not null default now(),
  primary key (app_entity_id, symbol),
  check (size <> 0 and margin >= 0)
);

create table if not exists perp_event (
  id bigint generated always as identity primary key,
  app_entity_id bigint, symbol text, kind text,      -- 'liquidation' | 'funding'
  detail jsonb, at timestamptz not null default now()
);

-- oracle: refresh marks from the spot last trade (or set externally / via pg_net)
create or replace function update_perp_mark() returns int
  language plpgsql security definer set search_path = public, pg_temp as $$
declare m perp_market%rowtype; px numeric; n int := 0;
begin
  for m in select * from perp_market loop
    select t.price into px from trade t join instrument i on i.id = t.instrument_id
      where i.name = m.index_symbol order by t.created_at desc limit 1;
    if px is not null then
      update perp_market set mark_price = px, updated_at = now() where symbol = m.symbol; n := n + 1;
    end if;
  end loop;
  return n;
end $$;
do $$ begin perform cron.schedule('update-perp-mark', '10 seconds', 'select update_perp_mark()');
exception when others then null; end $$;

-- open a position from flat: post `margin`, take a signed `size` at the current mark
create or replace function open_perp(symbol_param text, size_param numeric, margin_param numeric) returns json
  language plpgsql security definer set search_path = public, pg_temp as $$
declare eid bigint := current_app_entity_id(); pub text; mk perp_market%rowtype; notional numeric; required numeric;
begin
  if eid is null then raise exception 'not_authenticated'; end if;
  if size_param = 0 or margin_param <= 0 then raise exception 'invalid_size_or_margin'; end if;
  select * into mk from perp_market where symbol = symbol_param;
  if not found then raise exception 'unknown_market: %', symbol_param; end if;
  if mk.mark_price is null then raise exception 'no_mark_price'; end if;
  if exists (select 1 from perp_position where app_entity_id = eid and symbol = symbol_param) then
    raise exception 'position_exists_close_first';
  end if;
  notional := abs(size_param) * mk.mark_price;
  required := notional / mk.max_leverage;
  if margin_param < required - 1e-9 then
    raise exception 'insufficient_margin: need % got %', required, margin_param;
  end if;
  select pub_id into pub from app_entity where id = eid;
  perform process_transfer('WITHDRAWAL', pub, margin_param, mk.margin_currency, 'MASTER', 'perp', 'open margin', null);
  insert into perp_position(app_entity_id, symbol, size, entry_price, margin)
    values (eid, symbol_param, size_param, mk.mark_price, margin_param);
  return json_build_object('symbol', symbol_param, 'size', size_param, 'entry', mk.mark_price,
    'margin', margin_param, 'leverage', round(notional / margin_param, 2));
end $$;

-- close the whole position at the mark, realize PnL, return margin+pnl (clamped ≥0)
create or replace function close_perp(symbol_param text) returns json
  language plpgsql security definer set search_path = public, pg_temp as $$
declare eid bigint := current_app_entity_id(); pub text; mk perp_market%rowtype; pos perp_position%rowtype;
        pnl numeric; payout numeric;
begin
  if eid is null then raise exception 'not_authenticated'; end if;
  select * into mk from perp_market where symbol = symbol_param;
  select * into pos from perp_position where app_entity_id = eid and symbol = symbol_param for update;
  if not found then raise exception 'no_position'; end if;
  pnl := pos.size * (mk.mark_price - pos.entry_price);
  payout := round(greatest(pos.margin + pnl, 0), 2);
  if payout > 0 then
    select pub_id into pub from app_entity where id = eid;
    perform process_transfer('DEPOSIT', 'MASTER', payout, mk.margin_currency, pub, 'perp', 'close payout', null);
  end if;
  delete from perp_position where app_entity_id = eid and symbol = symbol_param;
  return json_build_object('pnl', round(pnl, 2), 'payout', payout);
end $$;

-- funding (pg_cron): long pays short when funding_rate>0; adjusts the margin claim
create or replace function apply_perp_funding() returns int
  language plpgsql security definer set search_path = public, pg_temp as $$
declare p record; mk perp_market%rowtype; pay numeric; n int := 0;
begin
  for p in select * from perp_position loop
    select * into mk from perp_market where symbol = p.symbol;
    if mk.funding_rate = 0 or mk.mark_price is null then continue; end if;
    pay := mk.funding_rate * p.size * mk.mark_price;   -- long (size>0) pays when rate>0
    update perp_position set margin = greatest(margin - pay, 0), updated_at = now()
      where app_entity_id = p.app_entity_id and symbol = p.symbol;
    insert into perp_event(app_entity_id, symbol, kind, detail)
      values (p.app_entity_id, p.symbol, 'funding', jsonb_build_object('rate', mk.funding_rate, 'paid', round(pay,2)));
    n := n + 1;
  end loop;
  return n;
end $$;
do $$ begin perform cron.schedule('apply-perp-funding', '1 hour', 'select apply_perp_funding()');
exception when others then null; end $$;

-- liquidation monitor (pg_cron): seize margin when equity ≤ maintenance
create or replace function check_perp_liquidations() returns int
  language plpgsql security definer set search_path = public, pg_temp as $$
declare p record; mk perp_market%rowtype; equity numeric; maint numeric; n int := 0;
begin
  for p in select * from perp_position loop
    select * into mk from perp_market where symbol = p.symbol;
    if mk.mark_price is null then continue; end if;
    equity := p.margin + p.size * (mk.mark_price - p.entry_price);
    maint  := abs(p.size) * mk.mark_price * mk.maintenance_ratio;
    if equity <= maint then
      delete from perp_position where app_entity_id = p.app_entity_id and symbol = p.symbol;
      insert into perp_event(app_entity_id, symbol, kind, detail)
        values (p.app_entity_id, p.symbol, 'liquidation',
                jsonb_build_object('mark', mk.mark_price, 'equity', round(equity,2)));
      n := n + 1;
    end if;
  end loop;
  return n;
end $$;
do $$ begin perform cron.schedule('check-perp', '15 seconds', 'select check_perp_liquidations()');
exception when others then null; end $$;

-- caller's positions with live uPnL/equity
create or replace view my_perp as
  select p.symbol, p.size, p.entry_price, m.mark_price,
         round(p.size * (m.mark_price - p.entry_price), 2) as upnl,
         p.margin,
         round(p.margin + p.size * (m.mark_price - p.entry_price), 2) as equity
  from perp_position p join perp_market m on m.symbol = p.symbol
  where p.app_entity_id = current_app_entity_id();
alter view my_perp set (security_invoker = on);
create or replace view perp_markets as
  select symbol, index_symbol, margin_currency, mark_price, funding_rate, max_leverage, maintenance_ratio from perp_market;

alter table perp_position enable row level security;
drop policy if exists own_perp on perp_position;
create policy own_perp on perp_position for select to authenticated
  using (app_entity_id = current_app_entity_id());

grant select on my_perp, perp_markets to anon, authenticated;
grant execute on function open_perp(text,numeric,numeric), close_perp(text) to authenticated;
grant execute on function update_perp_mark(), apply_perp_funding(), check_perp_liquidations() to service_role;
revoke execute on function open_perp(text,numeric,numeric), close_perp(text) from public, anon;
revoke execute on function update_perp_mark(), apply_perp_funding(), check_perp_liquidations() from public, anon, authenticated;


-- ══ 00760_grant_banker_round.sql ══════════════════════════════════════════

-- Fixes found driving the live demo: a logged-in user could stake / open a perp
-- (the writes succeeded — balances moved) but their position views came back empty
-- or errored. Two distinct causes, both in the derivative migrations:
--
-- 1) banker_round() EXECUTE. 9900_lockdown revokes EXECUTE on every public function
--    from anon/authenticated and re-grants only a whitelist; banker_round() was left
--    off it. my_stakes is security_invoker and calls banker_round() to show the live
--    pending reward, so reading it raised "permission denied for function
--    banker_round". It is an IMMUTABLE pure rounding helper that reads nothing, so
--    granting EXECUTE is safe.
--
-- 2) Public market tables had RLS enabled with NO policy on hosted (switched on
--    out-of-band by the Supabase security advisor — the migrations themselves only
--    enabled RLS on the *position* tables, so CI never reproduced this). stake_pool
--    and perp_market hold public market data (APR / total staked / mark price /
--    funding) and are joined by the security_invoker views my_stakes and my_perp.
--    With RLS on and no SELECT policy, those joins returned zero rows for
--    authenticated, so positions never showed even though stake_position /
--    perp_position had the row. (The stake_pools / perp_markets *views* worked
--    because they're security-definer and bypass RLS.) Make this declarative: enable
--    RLS here too (so CI == hosted == the migration) and add public read policies.
--    margin_config is read only via security-definer views (margin_terms /
--    my_margin_health), so it needs no policy.
--
-- Numbered >9900 so the lockdown's revoke loop has already run.

grant execute on function banker_round(numeric, integer) to anon, authenticated;

alter table stake_pool enable row level security;
drop policy if exists read_stake_pool on stake_pool;
create policy read_stake_pool on stake_pool for select to anon, authenticated using (true);

alter table perp_market enable row level security;
drop policy if exists read_perp_market on perp_market;
create policy read_perp_market on perp_market for select to anon, authenticated using (true);


-- ══ 00770_ohlcv.sql ══════════════════════════════════════════

-- Server-side OHLCV (candlestick) datafeed — pure SQL.
--
-- Buckets public trades into open/high/low/close/volume candles for any resolution,
-- so non-WASM clients (TradingView Lightweight Charts, mobile, TradingView UDF later)
-- get real server-computed candles instead of aggregating raw trades client-side.
--
-- Reads the security_invoker `trade_history` view (already anon-readable), so this
-- function runs with the caller's privileges and exposes nothing the caller can't
-- already select. `date_bin` (PG14+) aligns buckets to the epoch so a 60s candle
-- always starts on a whole minute, matching the chart library's timeframe grid.

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
  bucketed as (
    select date_bin(make_interval(secs => win.res),
                    th.created_at, timestamptz 'epoch') as bucket,
           th.price, th.amount, th.created_at
    from win, trade_history th
    where th.instrument = p_instrument
      and th.created_at >= win.t_from
      and th.created_at <= win.t_to
  )
  select (extract(epoch from bucket))::bigint                      as t,
         (array_agg(price order by created_at,      price))[1]     as o,
         max(price)                                                as h,
         min(price)                                                as l,
         (array_agg(price order by created_at desc, price desc))[1] as c,
         sum(amount)                                               as v
  from bucketed
  group by bucket
  order by bucket
$$;

revoke execute on function ohlcv(text, int, timestamptz, timestamptz) from public;
grant  execute on function ohlcv(text, int, timestamptz, timestamptz)
  to anon, authenticated, service_role;

comment on function ohlcv(text, int, timestamptz, timestamptz) is
  'Server-side OHLCV candles from trade_history; resolution allow-listed, window capped at 5000 buckets.';


-- ══ 00780_crypto_secp256k1_keccak.sql ══════════════════════════════════════════

-- Pure-PL/pgSQL cryptographic primitives for IN-DATABASE wallet custody & signing.
--
-- WHY: hosted Supabase ships no secp256k1/keccak extension and forbids installing
-- custom C extensions, so EVM/Tron key derivation + transaction signing must be done
-- in pure SQL to keep the "the database IS the exchange" model on the hosted demo.
-- These use only pgcrypto (HMAC/SHA-256, in schema `extensions`) + numeric/bit math.
--
-- VALIDATED against ethers/js-sha3 as oracle: keccak256 matches for all input lengths
-- 0..300 (incl. rate-boundary 135/136/137/271/272/273); secp256k1 pubkeys + RFC6979
-- (r,s,v) match ethers exactly across 30 random (priv,z) pairs; anchor addresses
-- 0x7e5f4552…395bdf (priv=1) and 0x2b5ad5c4…ccd6cf (priv=2) confirmed.
--
-- PERF: a sign / scalar-mult is tens–hundreds of ms in plpgsql — fine for low-rate
-- withdrawals. TESTNET ONLY: a master seed lives in the DB (vault), so DB access ==
-- fund control. Never custody real funds with this.
--
-- These are INTERNAL primitives: only SECURITY DEFINER wrappers (HD derivation,
-- withdrawal signer) and service_role should call them — revoked from anon/authenticated
-- at the end. Numbered >9900 so 9900_lockdown's revoke loop has already run.

-- ============================================================ keccak256 (Ethereum)
CREATE OR REPLACE FUNCTION public.keccak256(input bytea)
RETURNS bytea
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  st     bit(64)[];
  bb     bit(64)[];
  cc     bit(64)[];
  dd     bit(64)[];
  rho    int[] := ARRAY[
            0, 1,62,28,27,
           36,44, 6,55,20,
            3,10,43,25,39,
           41,45,15,21, 8,
           18, 2,61,56,14];
  rc     bit(64)[] := ARRAY[
           x'0000000000000001'::bit(64), x'0000000000008082'::bit(64),
           x'800000000000808A'::bit(64), x'8000000080008000'::bit(64),
           x'000000000000808B'::bit(64), x'0000000080000001'::bit(64),
           x'8000000080008081'::bit(64), x'8000000000008009'::bit(64),
           x'000000000000008A'::bit(64), x'0000000000000088'::bit(64),
           x'0000000080008009'::bit(64), x'000000008000000A'::bit(64),
           x'000000008000808B'::bit(64), x'800000000000008B'::bit(64),
           x'8000000000008089'::bit(64), x'8000000000008003'::bit(64),
           x'8000000000008002'::bit(64), x'8000000000000080'::bit(64),
           x'000000000000800A'::bit(64), x'800000008000000A'::bit(64),
           x'8000000080008081'::bit(64), x'8000000000008080'::bit(64),
           x'0000000080000001'::bit(64), x'8000000080008008'::bit(64)];
  zero64 bit(64) := x'0000000000000000'::bit(64);
  msg    bytea;
  mlen   int;
  rate   int := 136;
  nblocks int;
  padlen int;
  blk    int;
  i      int;
  x      int;
  y      int;
  idx    int;
  rnd    int;
  rot    int;
  lane   bit(64);
  bytepos int;
  out    bytea;
BEGIN
  mlen := coalesce(octet_length(input), 0);
  nblocks := (mlen / rate) + 1;
  padlen := nblocks * rate - mlen;
  msg := input || decode(repeat('00', padlen), 'hex');
  msg := set_byte(msg, mlen, get_byte(msg, mlen) | 1);
  msg := set_byte(msg, mlen + padlen - 1, get_byte(msg, mlen + padlen - 1) | 128);

  st := array_fill(zero64, ARRAY[25]);

  FOR blk IN 0 .. nblocks - 1 LOOP
    FOR i IN 0 .. 16 LOOP
      bytepos := blk * rate + i * 8;
      lane :=  (get_byte(msg, bytepos + 7)::bit(64) << 56)
             | (get_byte(msg, bytepos + 6)::bit(64) << 48)
             | (get_byte(msg, bytepos + 5)::bit(64) << 40)
             | (get_byte(msg, bytepos + 4)::bit(64) << 32)
             | (get_byte(msg, bytepos + 3)::bit(64) << 24)
             | (get_byte(msg, bytepos + 2)::bit(64) << 16)
             | (get_byte(msg, bytepos + 1)::bit(64) << 8)
             | (get_byte(msg, bytepos + 0)::bit(64));
      st[i + 1] := st[i + 1] # lane;
    END LOOP;

    FOR rnd IN 0 .. 23 LOOP
      cc := ARRAY[]::bit(64)[];
      FOR x IN 0 .. 4 LOOP
        cc[x + 1] := st[x + 1] # st[x + 6] # st[x + 11] # st[x + 16] # st[x + 21];
      END LOOP;
      dd := ARRAY[]::bit(64)[];
      FOR x IN 0 .. 4 LOOP
        lane := cc[((x + 1) % 5) + 1];
        dd[x + 1] := cc[((x + 4) % 5) + 1] # ((lane << 1) | (lane >> 63));
      END LOOP;
      FOR y IN 0 .. 4 LOOP
        FOR x IN 0 .. 4 LOOP
          st[x + 5 * y + 1] := st[x + 5 * y + 1] # dd[x + 1];
        END LOOP;
      END LOOP;

      bb := array_fill(zero64, ARRAY[25]);
      FOR y IN 0 .. 4 LOOP
        FOR x IN 0 .. 4 LOOP
          idx := x + 5 * y;
          rot := rho[idx + 1];
          lane := st[idx + 1];
          IF rot = 0 THEN
            bb[y + 5 * ((2 * x + 3 * y) % 5) + 1] := lane;
          ELSE
            bb[y + 5 * ((2 * x + 3 * y) % 5) + 1] := (lane << rot) | (lane >> (64 - rot));
          END IF;
        END LOOP;
      END LOOP;

      FOR y IN 0 .. 4 LOOP
        FOR x IN 0 .. 4 LOOP
          st[x + 5 * y + 1] :=
            bb[x + 5 * y + 1]
            # ((~ bb[((x + 1) % 5) + 5 * y + 1]) & bb[((x + 2) % 5) + 5 * y + 1]);
        END LOOP;
      END LOOP;

      st[1] := st[1] # rc[rnd + 1];
    END LOOP;
  END LOOP;

  out := '\x'::bytea;
  FOR i IN 0 .. 3 LOOP
    lane := st[i + 1];
    out := out
      || set_byte(set_byte(set_byte(set_byte(set_byte(set_byte(set_byte(set_byte(
           '\x0000000000000000'::bytea,
           0, substring(lane from 57 for 8)::int),
           1, substring(lane from 49 for 8)::int),
           2, substring(lane from 41 for 8)::int),
           3, substring(lane from 33 for 8)::int),
           4, substring(lane from 25 for 8)::int),
           5, substring(lane from 17 for 8)::int),
           6, substring(lane from  9 for 8)::int),
           7, substring(lane from  1 for 8)::int);
  END LOOP;

  RETURN out;
END;
$$;

CREATE OR REPLACE FUNCTION public.keccak256_hex(input bytea)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT encode(public.keccak256(input), 'hex');
$$;

-- ============================================================ secp256k1 + ECDSA
CREATE OR REPLACE FUNCTION public.secp_powmod(base numeric, exp numeric, m numeric)
RETURNS numeric LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  r numeric := 1;
  b numeric := mod(base, m);
  e numeric := exp;
BEGIN
  IF b < 0 THEN b := b + m; END IF;
  WHILE e > 0 LOOP
    IF mod(e, 2) = 1 THEN
      r := mod(r * b, m);
    END IF;
    e := div(e, 2);
    b := mod(b * b, m);
  END LOOP;
  RETURN r;
END;
$$;

CREATE OR REPLACE FUNCTION public.secp_b2n(b bytea)
RETURNS numeric LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  r numeric := 0;
  i int;
BEGIN
  FOR i IN 0 .. length(b) - 1 LOOP
    r := r * 256 + get_byte(b, i);
  END LOOP;
  RETURN r;
END;
$$;

CREATE OR REPLACE FUNCTION public.secp_n2hex(x numeric)
RETURNS text LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  digits constant text := '0123456789abcdef';
  s text := '';
  v numeric := x;
  d int;
BEGIN
  WHILE v > 0 LOOP
    d := mod(v, 16)::int;
    s := substr(digits, d + 1, 1) || s;
    v := div(v, 16);
  END LOOP;
  RETURN lpad(s, 64, '0');
END;
$$;

CREATE OR REPLACE FUNCTION public.secp_n2bytea(x numeric)
RETURNS bytea LANGUAGE sql IMMUTABLE AS $$
  SELECT decode(public.secp_n2hex(x), 'hex');
$$;

CREATE OR REPLACE FUNCTION public.secp_jdouble(jp numeric[])
RETURNS numeric[] LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  p constant numeric := 115792089237316195423570985008687907853269984665640564039457584007908834671663;
  X numeric := jp[1]; Y numeric := jp[2]; Z numeric := jp[3];
  XX numeric; YY numeric; YYYY numeric; ZZ numeric;
  S numeric; M numeric; T numeric; X3 numeric; Y3 numeric; Z3 numeric;
BEGIN
  IF Z = 0 OR Y = 0 THEN
    RETURN ARRAY[1::numeric, 1::numeric, 0::numeric];
  END IF;
  XX   := mod(X * X, p);
  YY   := mod(Y * Y, p);
  YYYY := mod(YY * YY, p);
  ZZ   := mod(Z * Z, p);
  S    := mod(2 * (mod((X + YY) * (X + YY), p) - XX - YYYY), p);
  M    := mod(3 * XX, p);
  T    := mod(M * M - 2 * S, p);
  X3   := T;
  Y3   := mod(M * (S - T) - 8 * YYYY, p);
  Z3   := mod(mod((Y + Z) * (Y + Z), p) - YY - ZZ, p);
  RETURN ARRAY[mod(X3 + p, p), mod(Y3 + p, p), mod(Z3 + p, p)];
END;
$$;

CREATE OR REPLACE FUNCTION public.secp_jadd(jp numeric[], jq numeric[])
RETURNS numeric[] LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  p constant numeric := 115792089237316195423570985008687907853269984665640564039457584007908834671663;
  X1 numeric := jp[1]; Y1 numeric := jp[2]; Z1 numeric := jp[3];
  X2 numeric := jq[1]; Y2 numeric := jq[2]; Z2 numeric := jq[3];
  Z1Z1 numeric; Z2Z2 numeric; U1 numeric; U2 numeric; S1 numeric; S2 numeric;
  H numeric; ii numeric; jj numeric; r numeric; V numeric;
  X3 numeric; Y3 numeric; Z3 numeric;
BEGIN
  IF Z1 = 0 THEN RETURN jq; END IF;
  IF Z2 = 0 THEN RETURN jp; END IF;
  Z1Z1 := mod(Z1 * Z1, p);
  Z2Z2 := mod(Z2 * Z2, p);
  U1 := mod(X1 * Z2Z2, p);
  U2 := mod(X2 * Z1Z1, p);
  S1 := mod(mod(Y1 * Z2, p) * Z2Z2, p);
  S2 := mod(mod(Y2 * Z1, p) * Z1Z1, p);
  H  := mod(U2 - U1 + p, p);
  r  := mod(2 * (S2 - S1) + 2 * p, p);
  IF H = 0 THEN
    IF r = 0 THEN
      RETURN public.secp_jdouble(jp);
    ELSE
      RETURN ARRAY[1::numeric, 1::numeric, 0::numeric];
    END IF;
  END IF;
  ii := mod((2 * H) * (2 * H), p);
  jj := mod(H * ii, p);
  V  := mod(U1 * ii, p);
  X3 := mod(r * r - jj - 2 * V + 2 * p, p);
  Y3 := mod(r * (V - X3) - 2 * mod(S1 * jj, p) + 2 * p, p);
  Z3 := mod(mod((mod((Z1 + Z2) * (Z1 + Z2), p) - Z1Z1 - Z2Z2 + 2 * p), p) * H, p);
  RETURN ARRAY[mod(X3 + p, p), mod(Y3 + p, p), mod(Z3 + p, p)];
END;
$$;

CREATE OR REPLACE FUNCTION public.secp_mul(scalar numeric, px numeric, py numeric)
RETURNS numeric[] LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  p constant numeric := 115792089237316195423570985008687907853269984665640564039457584007908834671663;
  acc numeric[] := ARRAY[1::numeric, 1::numeric, 0::numeric];
  base numeric[] := ARRAY[px, py, 1::numeric];
  bits int[] := ARRAY[]::int[];
  k numeric := scalar;
  i int;
  zinv numeric; zinv2 numeric;
BEGIN
  IF scalar = 0 THEN RETURN NULL; END IF;
  WHILE k > 0 LOOP
    bits := array_append(bits, mod(k, 2)::int);
    k := div(k, 2);
  END LOOP;
  FOR i IN REVERSE array_length(bits, 1) .. 1 LOOP
    acc := public.secp_jdouble(acc);
    IF bits[i] = 1 THEN
      acc := public.secp_jadd(acc, base);
    END IF;
  END LOOP;
  IF acc[3] = 0 THEN RETURN NULL; END IF;
  zinv  := public.secp_powmod(acc[3], p - 2, p);
  zinv2 := mod(zinv * zinv, p);
  RETURN ARRAY[ mod(acc[1] * zinv2, p),
                mod(mod(acc[2] * zinv2, p) * zinv, p) ];
END;
$$;

-- 64-byte uncompressed pubkey X(32)||Y(32), no 0x04 prefix
CREATE OR REPLACE FUNCTION public.secp_pubkey(priv bytea)
RETURNS bytea LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  Gx constant numeric := 55066263022277343669578718895168534326250603453777594175500187360389116729240;
  Gy constant numeric := 32670510020758816978083085130507043184471273380659243275938904335757337482424;
  d numeric := public.secp_b2n(priv);
  pt numeric[];
BEGIN
  pt := public.secp_mul(d, Gx, Gy);
  IF pt IS NULL THEN
    RAISE EXCEPTION 'invalid private key (results in point at infinity)';
  END IF;
  RETURN decode(public.secp_n2hex(pt[1]) || public.secp_n2hex(pt[2]), 'hex');
END;
$$;

-- RFC6979 deterministic ECDSA over 32-byte hash z; low-s normalized.
-- returns {"r":hex,"s":hex,"v":0|1}
CREATE OR REPLACE FUNCTION public.secp_sign(priv bytea, z bytea)
RETURNS jsonb LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  n  constant numeric := 115792089237316195423570985008687907852837564279074904382605163141518161494337;
  Gx constant numeric := 55066263022277343669578718895168534326250603453777594175500187360389116729240;
  Gy constant numeric := 32670510020758816978083085130507043184471273380659243275938904335757337482424;
  half constant numeric := 57896044618658097711785492504343953926418782139537452191302581570759080747168;
  d numeric := public.secp_b2n(priv);
  zint numeric := public.secp_b2n(z);
  priv_oct bytea := public.secp_n2bytea(d);
  z_oct bytea := public.secp_n2bytea(mod(zint, n));
  vv bytea := decode(repeat('01', 32), 'hex');
  kk bytea := decode(repeat('00', 32), 'hex');
  tt bytea;
  knonce numeric;
  pt numeric[];
  sig_r numeric;
  sig_s numeric;
  parity int;
BEGIN
  kk := extensions.hmac(vv || '\x00'::bytea || priv_oct || z_oct, kk, 'sha256');
  vv := extensions.hmac(vv, kk, 'sha256');
  kk := extensions.hmac(vv || '\x01'::bytea || priv_oct || z_oct, kk, 'sha256');
  vv := extensions.hmac(vv, kk, 'sha256');

  LOOP
    vv := extensions.hmac(vv, kk, 'sha256');
    tt := vv;
    knonce := public.secp_b2n(tt);
    IF knonce >= 1 AND knonce < n THEN
      pt := public.secp_mul(knonce, Gx, Gy);
      IF pt IS NOT NULL THEN
        sig_r := mod(pt[1], n);
        IF sig_r <> 0 THEN
          sig_s := mod( public.secp_powmod(knonce, n - 2, n)
                    * mod(zint + mod(sig_r * d, n), n), n );
          IF sig_s <> 0 THEN
            parity := mod(pt[2], 2)::int;
            IF sig_s > half THEN
              sig_s := n - sig_s;
              parity := 1 - parity;
            END IF;
            RETURN jsonb_build_object(
              'r', public.secp_n2hex(sig_r),
              's', public.secp_n2hex(sig_s),
              'v', parity);
          END IF;
        END IF;
      END IF;
    END IF;
    kk := extensions.hmac(vv || '\x00'::bytea, kk, 'sha256');
    vv := extensions.hmac(vv, kk, 'sha256');
  END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION public.secp_verify(pub bytea, z bytea, r bytea, s bytea)
RETURNS boolean LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  n  constant numeric := 115792089237316195423570985008687907852837564279074904382605163141518161494337;
  Gx constant numeric := 55066263022277343669578718895168534326250603453777594175500187360389116729240;
  Gy constant numeric := 32670510020758816978083085130507043184471273380659243275938904335757337482424;
  Qx numeric := public.secp_b2n(substr(pub, 1, 32));
  Qy numeric := public.secp_b2n(substr(pub, 33, 32));
  rn numeric := public.secp_b2n(r);
  sn numeric := public.secp_b2n(s);
  zint numeric := public.secp_b2n(z);
  w numeric; u1 numeric; u2 numeric;
  P1 numeric[]; P2 numeric[];
  J1 numeric[]; J2 numeric[]; J numeric[];
BEGIN
  IF rn < 1 OR rn >= n OR sn < 1 OR sn >= n THEN
    RETURN false;
  END IF;
  w  := public.secp_powmod(sn, n - 2, n);
  u1 := mod(zint * w, n);
  u2 := mod(rn * w, n);

  P1 := public.secp_mul(u1, Gx, Gy);
  P2 := public.secp_mul(u2, Qx, Qy);

  IF P1 IS NULL THEN J1 := ARRAY[1::numeric,1::numeric,0::numeric];
  ELSE J1 := ARRAY[P1[1], P1[2], 1::numeric]; END IF;
  IF P2 IS NULL THEN J2 := ARRAY[1::numeric,1::numeric,0::numeric];
  ELSE J2 := ARRAY[P2[1], P2[2], 1::numeric]; END IF;

  J := public.secp_jadd(J1, J2);
  IF J[3] = 0 THEN
    RETURN false;
  END IF;
  DECLARE
    p constant numeric := 115792089237316195423570985008687907853269984665640564039457584007908834671663;
    zinv numeric := public.secp_powmod(J[3], p - 2, p);
    xaff numeric;
  BEGIN
    xaff := mod(J[1] * mod(zinv * zinv, p), p);
    RETURN mod(xaff, n) = rn;
  END;
END;
$$;

-- ---------- EVM address = last 20 bytes of keccak256(uncompressed pubkey) ----------
CREATE OR REPLACE FUNCTION public.evm_address(priv bytea)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT '0x' || encode(substr(public.keccak256(public.secp_pubkey(priv)), 13, 20), 'hex');
$$;

-- internal primitives: callable only by SECURITY DEFINER wrappers + service_role
REVOKE EXECUTE ON FUNCTION
  public.keccak256(bytea), public.keccak256_hex(bytea),
  public.secp_powmod(numeric,numeric,numeric), public.secp_b2n(bytea),
  public.secp_n2hex(numeric), public.secp_n2bytea(numeric),
  public.secp_jdouble(numeric[]), public.secp_jadd(numeric[],numeric[]),
  public.secp_mul(numeric,numeric,numeric), public.secp_pubkey(bytea),
  public.secp_sign(bytea,bytea), public.secp_verify(bytea,bytea,bytea,bytea),
  public.evm_address(bytea)
FROM public, anon, authenticated;
