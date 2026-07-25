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
