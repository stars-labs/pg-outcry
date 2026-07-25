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
