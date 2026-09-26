-- Bitcoin testnet4 withdrawals, signed and broadcast in Postgres.
--
-- The hot wallet is every HD address the venue controls on the chain: each user's
-- deposit address (user_chain_wallet) and the treasury (HD index 0), which also
-- receives change. Deposits therefore fund withdrawals directly; nothing needs to
-- be swept first. Addresses a user registered themselves (watched_address without
-- a user_chain_wallet row) are not ours to spend and are never used.
--
-- Transactions are native segwit (P2WPKH inputs, BIP-143 sighash, low-S DER
-- signatures from the existing RFC-6979 secp_sign), and are validated byte for
-- byte against bitcoinjs-lib. Outputs may be any testnet address type: P2WPKH,
-- P2WSH, P2TR, P2PKH, P2SH. Mainnet addresses are refused.
--
-- Signing and broadcasting are separate cron jobs so a payment can never be
-- signed twice: sign_bitcoin_withdrawals() only builds, signs and records the raw
-- transaction (and marks its inputs spent); broadcast_bitcoin_withdrawals() only
-- (re)sends recorded raw transactions, which is idempotent. The network fee is
-- paid by the venue, like gas on the other chains: the recipient gets the full
-- requested amount.

-- ── encoding helpers ────────────────────────────────────────────────────────
create or replace function btc_le(n numeric, width int) returns bytea
  language plpgsql immutable as $$
declare out bytea := '\x'::bytea; i int; v numeric := n;
begin
  if n < 0 then raise exception 'btc_le: negative %', n; end if;
  for i in 1 .. width loop
    out := out || set_byte('\x00'::bytea, 0, mod(v, 256)::int);
    v := floor(v / 256);
  end loop;
  if v <> 0 then raise exception 'btc_le: % does not fit % bytes', n, width; end if;
  return out;
end $$;

create or replace function btc_varint(n int) returns bytea
  language sql immutable as $$
  select case when n < 253 then btc_le(n, 1)
              when n <= 65535 then '\xfd'::bytea || btc_le(n, 2)
              else '\xfe'::bytea || btc_le(n, 4) end;
$$;

create or replace function btc_dsha256(b bytea) returns bytea
  language sql immutable set search_path = public, extensions, pg_temp as $$
  select extensions.digest(extensions.digest(b, 'sha256'), 'sha256');
$$;

create or replace function btc_reverse(b bytea) returns bytea
  language plpgsql immutable as $$
declare out bytea := '\x'::bytea; i int;
begin
  for i in reverse length(b) - 1 .. 0 loop out := out || set_byte('\x00'::bytea, 0, get_byte(b, i)); end loop;
  return out;
end $$;

-- ── address -> scriptPubKey (testnet only) ──────────────────────────────────
create or replace function btc_testnet_script(address text) returns bytea
  language plpgsql immutable set search_path = public, extensions, pg_temp as $$
declare
  charset constant text := 'qpzry9x8gf2tvdw0s3jn54khce6mua7l';
  a text := lower(address); sep int; hrp text; vals int[] := '{}'; expanded int[] := '{}';
  i int; c int; chk int; ver int; acc int := 0; bits int := 0; prog bytea := '\x'::bytea;
  raw bytea;
begin
  if address ~ '^(tb1|TB1)' then
    if address <> lower(address) and address <> upper(address) then raise exception 'btc_address_mixed_case'; end if;
    sep := length(a) - strpos(reverse(a), '1') + 1;
    hrp := substr(a, 1, sep - 1);
    for i in sep + 1 .. length(a) loop
      c := strpos(charset, substr(a, i, 1)) - 1;
      if c < 0 then raise exception 'btc_address_bad_char'; end if;
      vals := vals || c;
    end loop;
    if array_length(vals, 1) < 7 then raise exception 'btc_address_too_short'; end if;
    for i in 1 .. length(hrp) loop expanded := expanded || (ascii(substr(hrp, i, 1)) >> 5); end loop;
    expanded := expanded || 0;
    for i in 1 .. length(hrp) loop expanded := expanded || (ascii(substr(hrp, i, 1)) & 31); end loop;
    chk := bech32_polymod(expanded || vals);
    ver := vals[1];
    if (ver = 0 and chk <> 1) or (ver > 0 and chk <> 734539939) then   -- 0x2bc830a3 = bech32m
      raise exception 'btc_address_bad_checksum';
    end if;
    for i in 2 .. array_length(vals, 1) - 6 loop           -- 5-bit words -> bytes, no padding
      acc := ((acc << 5) | vals[i]) & 4095;
      bits := bits + 5;
      if bits >= 8 then bits := bits - 8; prog := prog || set_byte('\x00'::bytea, 0, (acc >> bits) & 255); end if;
    end loop;
    if bits >= 5 or (acc & ((1 << bits) - 1)) <> 0 then raise exception 'btc_address_bad_padding'; end if;
    if ver = 0 and length(prog) in (20, 32) then
      return '\x00'::bytea || btc_le(length(prog), 1) || prog;
    elsif ver = 1 and length(prog) = 32 then
      return '\x51'::bytea || '\x20'::bytea || prog;
    end if;
    raise exception 'btc_address_unsupported_witness: v% len %', ver, length(prog);
  end if;

  if address ~ '^[mn2][1-9A-HJ-NP-Za-km-z]{25,34}$' then
    raw := public.base58_decode(address);
    if length(raw) <> 25 or substr(btc_dsha256(substr(raw, 1, 21)), 1, 4) <> substr(raw, 22, 4) then
      raise exception 'btc_address_bad_checksum';
    end if;
    if get_byte(raw, 0) = 111 then        -- 0x6f P2PKH
      return '\x76a914'::bytea || substr(raw, 2, 20) || '\x88ac'::bytea;
    elsif get_byte(raw, 0) = 196 then     -- 0xc4 P2SH
      return '\xa914'::bytea || substr(raw, 2, 20) || '\x87'::bytea;
    end if;
  end if;
  raise exception 'btc_address_not_testnet: %', address;
end $$;

-- ── signed transaction builder (validated vs bitcoinjs-lib) ─────────────────
-- inputs:  [{txid, vout, value (sats), priv (hex)}]  all P2WPKH
-- outputs: [{address, value (sats)}]
-- returns {txid, hex, vsize}
create or replace function btc_build_signed_tx(inputs jsonb, outputs jsonb) returns jsonb
  language plpgsql immutable set search_path = public, extensions, pg_temp as $$
declare
  seq constant bytea := '\xffffffff'::bytea;
  prevouts bytea := '\x'::bytea; seqs bytea := '\x'::bytea; outs bytea := '\x'::bytea;
  ins bytea := '\x'::bytea; wits bytea := '\x'::bytea;
  i jsonb; o jsonb; spk bytea; outpoint bytea; priv bytea; pub bytea; cpub bytea;
  pre bytea; sig jsonb; r bytea; s bytea; der bytea; base bytea; witness_tx bytea;
  hash_prevouts bytea; hash_seqs bytea; hash_outs bytea;
begin
  if jsonb_array_length(inputs) = 0 or jsonb_array_length(outputs) = 0 then
    raise exception 'btc_tx_needs_inputs_and_outputs';
  end if;
  for i in select value from jsonb_array_elements(inputs) loop
    prevouts := prevouts || btc_reverse(decode(i->>'txid', 'hex')) || btc_le((i->>'vout')::numeric, 4);
    seqs := seqs || seq;
  end loop;
  for o in select value from jsonb_array_elements(outputs) loop
    spk := btc_testnet_script(o->>'address');
    outs := outs || btc_le((o->>'value')::numeric, 8) || btc_varint(length(spk)) || spk;
  end loop;
  hash_prevouts := btc_dsha256(prevouts);
  hash_seqs := btc_dsha256(seqs);
  hash_outs := btc_dsha256(outs);

  for i in select value from jsonb_array_elements(inputs) loop
    outpoint := btc_reverse(decode(i->>'txid', 'hex')) || btc_le((i->>'vout')::numeric, 4);
    priv := decode(i->>'priv', 'hex');
    pub := public.secp_pubkey(priv);
    cpub := case when get_byte(pub, 63) % 2 = 0 then '\x02'::bytea else '\x03'::bytea end || substr(pub, 1, 32);
    -- BIP-143 preimage, SIGHASH_ALL; scriptCode = P2PKH of the key hash
    pre := btc_le(2, 4) || hash_prevouts || hash_seqs || outpoint
        || '\x1976a914'::bytea || extensions.digest(extensions.digest(cpub, 'sha256'), 'ripemd160') || '\x88ac'::bytea
        || btc_le((i->>'value')::numeric, 8) || seq || hash_outs || btc_le(0, 4) || btc_le(1, 4);
    sig := public.secp_sign(priv, btc_dsha256(pre));                 -- RFC-6979, low-S
    r := public.strip_leading_zeros(decode(lpad(sig->>'r', 64, '0'), 'hex'));
    s := public.strip_leading_zeros(decode(lpad(sig->>'s', 64, '0'), 'hex'));
    if get_byte(r, 0) >= 128 then r := '\x00'::bytea || r; end if;
    if get_byte(s, 0) >= 128 then s := '\x00'::bytea || s; end if;
    der := '\x02'::bytea || btc_le(length(r), 1) || r || '\x02'::bytea || btc_le(length(s), 1) || s;
    der := '\x30'::bytea || btc_le(length(der), 1) || der || '\x01'::bytea;
    ins := ins || outpoint || '\x00'::bytea || seq;
    wits := wits || '\x02'::bytea || btc_varint(length(der)) || der || btc_varint(length(cpub)) || cpub;
  end loop;

  base := btc_le(2, 4) || btc_varint(jsonb_array_length(inputs)) || ins
       || btc_varint(jsonb_array_length(outputs)) || outs || btc_le(0, 4);
  witness_tx := btc_le(2, 4) || '\x0001'::bytea || btc_varint(jsonb_array_length(inputs)) || ins
       || btc_varint(jsonb_array_length(outputs)) || outs || wits || btc_le(0, 4);
  return jsonb_build_object(
    'txid', encode(btc_reverse(btc_dsha256(base)), 'hex'),
    'hex', encode(witness_tx, 'hex'),
    'vsize', ceil((length(base) * 3 + length(witness_tx)) / 4.0)::int);
end $$;

-- ── bookkeeping ─────────────────────────────────────────────────────────────
create table if not exists btc_withdrawal_tx (
  request_pub   text primary key references wallet_request(pub_id),
  txid          text not null unique,
  raw_hex       text not null,
  fee_sats      numeric not null,
  created_at    timestamptz not null default now(),
  broadcast_at  timestamptz,
  last_error    text
);
-- every outpoint a signed transaction consumes; never selected again
create table if not exists btc_spent_outpoint (
  txid        text not null,
  vout        int  not null,
  request_pub text not null references btc_withdrawal_tx(request_pub),
  primary key (txid, vout)
);
alter table btc_withdrawal_tx  enable row level security;
alter table btc_spent_outpoint enable row level security;
revoke all on btc_withdrawal_tx, btc_spent_outpoint from public, anon, authenticated;

-- the addresses whose keys we hold: users' HD deposit addresses + the treasury
create or replace function btc_hot_wallet(chain_param text)
  returns table(address text, key_index bigint)
  language sql stable security definer set search_path = public, pg_temp as $$
  select w.address, w.app_entity_id from user_chain_wallet w where w.chain = chain_param
  union all
  select btc_p2wpkh_address(_derive_secp_priv(0, chain_param), 'tb'), 0;
$$;

create or replace function treasury_address(chain_param text) returns text
  language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare k text;
begin
  select kind into k from chain where name = chain_param;
  if k = 'evm' then return public.evm_address(public._derive_secp_priv(0, chain_param));
  elsif k = 'tron' then return public.tron_address_from_priv(public._derive_secp_priv(0, chain_param));
  elsif k = 'solana' then return public.sol_address_from_eid(0);
  elsif k = 'bitcoin' then return public.btc_p2wpkh_address(public._derive_secp_priv(0, chain_param), 'tb');
  else raise exception 'unknown_or_unsupported_chain: %', chain_param; end if;
end; $$;

-- Pick confirmed UTXOs (largest first) until amount + fee is covered.
-- utxos: [{txid, vout, value, key_index}]. Returns {inputs, fee, change} or raises.
create or replace function btc_select_coins(utxos jsonb, amount_sats numeric, fee_rate numeric)
  returns jsonb
  language plpgsql immutable as $$
declare u jsonb; picked jsonb := '[]'; total numeric := 0; fee numeric; change numeric;
begin
  for u in select value from jsonb_array_elements(utxos) order by (value->>'value')::numeric desc loop
    picked := picked || u;
    total := total + (u->>'value')::numeric;
    -- P2WPKH: ~11 vB overhead + 68 vB per input + 31-43 vB per output (2 outputs)
    fee := ceil((11 + 68 * jsonb_array_length(picked) + 2 * 43) * fee_rate);
    if total >= amount_sats + fee then
      change := total - amount_sats - fee;
      if change < 546 then fee := fee + change; change := 0; end if;   -- dust goes to the fee
      return jsonb_build_object('inputs', picked, 'fee', fee, 'change', change);
    end if;
  end loop;
  raise exception 'btc_insufficient_hot_wallet: have % sats, need % + fee', total, amount_sats;
end $$;

-- ── signer (no network writes) ──────────────────────────────────────────────
create or replace function sign_bitcoin_withdrawal(request_pub text) returns text
  language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare
  chain_param constant text := 'bitcoin-testnet4';
  wr record; cfg chain%rowtype; dec int; amount_sats numeric; fee_rate numeric;
  w record; resp extensions.http_response; u jsonb; utxos jsonb := '[]'; sel jsonb;
  inputs jsonb := '[]'; outputs jsonb; tx jsonb;
begin
  select pub_id, currency, amount, to_address, status, direction, broadcast_txid
    into wr from wallet_request where pub_id = request_pub for update;
  if not found then raise exception 'no_such_request'; end if;
  if wr.direction <> 'WITHDRAWAL' or wr.status <> 'APPROVED' or wr.currency <> 'BTC' then
    raise exception 'not_approved_btc_withdrawal';
  end if;
  if wr.broadcast_txid is not null then return wr.broadcast_txid; end if;
  perform btc_testnet_script(wr.to_address);                           -- validate before any I/O

  select * into cfg from chain where name = chain_param and enabled and rpc_url is not null;
  if not found then raise exception 'chain_not_enabled: %', chain_param; end if;
  select decimals into dec from chain_asset where chain = chain_param and token = 'native';
  amount_sats := round(wr.amount * power(10::numeric, dec));

  resp := extensions.http_get(cfg.rpc_url || '/fee-estimates');
  fee_rate := greatest(ceil(coalesce(case when resp.status = 200 then (resp.content::jsonb->>'3')::numeric end, 2)), 2);

  for w in select * from btc_hot_wallet(chain_param) loop
    resp := extensions.http_get(cfg.rpc_url || '/address/' || w.address || '/utxo');
    if resp.status <> 200 then raise exception 'utxo lookup %: http %', w.address, resp.status; end if;
    for u in select value from jsonb_array_elements(resp.content::jsonb) loop
      if (u->'status'->>'confirmed')::boolean
         and not exists (select 1 from btc_spent_outpoint s where s.txid = u->>'txid' and s.vout = (u->>'vout')::int) then
        utxos := utxos || jsonb_build_object('txid', u->>'txid', 'vout', (u->>'vout')::int,
                                             'value', (u->>'value')::numeric, 'key_index', w.key_index);
      end if;
    end loop;
  end loop;

  sel := btc_select_coins(utxos, amount_sats, fee_rate);
  for u in select value from jsonb_array_elements(sel->'inputs') loop
    inputs := inputs || jsonb_build_object('txid', u->>'txid', 'vout', (u->>'vout')::int, 'value', (u->>'value')::numeric,
      'priv', encode(_derive_secp_priv((u->>'key_index')::bigint, chain_param), 'hex'));
  end loop;
  outputs := jsonb_build_array(jsonb_build_object('address', wr.to_address, 'value', amount_sats));
  if (sel->>'change')::numeric > 0 then
    outputs := outputs || jsonb_build_object('address', treasury_address(chain_param), 'value', (sel->>'change')::numeric);
  end if;
  tx := btc_build_signed_tx(inputs, outputs);

  insert into btc_withdrawal_tx(request_pub, txid, raw_hex, fee_sats)
    values (request_pub, tx->>'txid', tx->>'hex', (sel->>'fee')::numeric);
  insert into btc_spent_outpoint(txid, vout, request_pub)
    select value->>'txid', (value->>'vout')::int, request_pub from jsonb_array_elements(sel->'inputs');
  -- the job acts as the service plane (mark_* check withdrawal.sign)
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  perform mark_withdrawal_broadcast(request_pub, tx->>'txid');
  return tx->>'txid';
end $$;

-- One withdrawal per run: the next one must not see UTXOs this one just spent as free.
create or replace function sign_bitcoin_withdrawals() returns int
  language plpgsql security definer set search_path = public, pg_temp as $$
declare wr record;
begin
  for wr in select pub_id from wallet_request
    where direction = 'WITHDRAWAL' and status = 'APPROVED' and broadcast_txid is null and currency = 'BTC'
    order by created_at limit 1
    for update skip locked
  loop
    begin
      perform sign_bitcoin_withdrawal(wr.pub_id);
      return 1;
    exception when others then
      raise warning 'btc withdrawal % not signed: %', wr.pub_id, sqlerrm;
    end;
  end loop;
  return 0;
end $$;

-- ── broadcaster (idempotent) ────────────────────────────────────────────────
create or replace function broadcast_bitcoin_withdrawals() returns int
  language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare cfg chain%rowtype; t record; resp extensions.http_response; n int := 0;
begin
  select * into cfg from chain where name = 'bitcoin-testnet4' and enabled and rpc_url is not null;
  if not found then return 0; end if;
  for t in select * from btc_withdrawal_tx where broadcast_at is null order by created_at for update skip locked loop
    resp := extensions.http_post(cfg.rpc_url || '/tx', t.raw_hex, 'text/plain');
    if resp.status = 200 or resp.content ~* '(already|txn-already-known|txn-already-in-mempool)' then
      update btc_withdrawal_tx set broadcast_at = now(), last_error = null where request_pub = t.request_pub;
      n := n + 1;
    else
      update btc_withdrawal_tx set last_error = left(resp.status || ': ' || resp.content, 500)
       where request_pub = t.request_pub;
    end if;
  end loop;
  return n;
end $$;

create or replace function confirm_bitcoin_withdrawals() returns int
  language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare cfg chain%rowtype; t record; resp extensions.http_response; n int := 0;
begin
  select * into cfg from chain where name = 'bitcoin-testnet4' and enabled and rpc_url is not null;
  if not found then return 0; end if;
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  for t in select b.request_pub, b.txid from btc_withdrawal_tx b join wallet_request w on w.pub_id = b.request_pub
            where b.broadcast_at is not null and w.confirmed_at is null loop
    resp := extensions.http_get(cfg.rpc_url || '/tx/' || t.txid || '/status');
    if resp.status = 200 and (resp.content::jsonb->>'confirmed')::boolean then
      perform mark_withdrawal_confirmed(t.request_pub); n := n + 1;
    end if;
  end loop;
  return n;
end $$;

-- ── existing chain drivers: act as the service plane, keep BTC out of Solana ─
-- mark_withdrawal_broadcast / _confirmed require withdrawal.sign, which a pg_cron
-- job does not have (no JWT). The EVM/Tron/Solana signers broadcast first and then
-- mark; the mark raised, the per-request subtransaction rolled back, nothing was
-- recorded, and the next run signed and paid the same withdrawal again (fresh
-- nonce / blockhash / timestamp) every 30 s. Reproduced locally: 2 broadcasts for
-- 1 withdrawal. Each cron driver now declares itself the service plane first.
create or replace function process_evm_withdrawals() returns int
  language plpgsql security definer set search_path = public, pg_temp as $$
declare wr record; n int := 0;
begin
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
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
end $$;

create or replace function process_tron_withdrawals() returns int
  language plpgsql security definer set search_path = public, pg_temp as $$
declare wr record; n int := 0;
begin
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  for wr in select pub_id from wallet_request
    where direction='WITHDRAWAL' and status='APPROVED' and broadcast_txid is null
      and to_address like 'T%'
    for update skip locked loop
    begin perform sign_and_broadcast_tron_withdrawal(wr.pub_id); n := n + 1;
    exception when others then raise warning 'tron withdrawal % failed: %', wr.pub_id, sqlerrm; end;
  end loop;
  return n;
end $$;

create or replace function process_evm_confirmations() returns int
  language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare wr record; cfg chain%rowtype; receipt jsonb; n int := 0;
begin
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
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
end $$;

-- Solana took "anything not 0x… and not T…", which includes every BTC address.
create or replace function process_solana_withdrawals() returns int
  language plpgsql security definer set search_path = public, pg_temp as $$
declare wr record; n int := 0;
begin
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  for wr in select pub_id from wallet_request
    where direction='WITHDRAWAL' and status='APPROVED' and broadcast_txid is null
      and to_address not like '0x%' and to_address not like 'T%' and currency <> 'BTC'
    for update skip locked loop
    begin perform sign_and_broadcast_solana_withdrawal(wr.pub_id); n := n + 1;
    exception when others then raise warning 'sol withdrawal % failed: %', wr.pub_id, sqlerrm; end;
  end loop;
  return n;
end $$;

insert into withdrawal_limit (currency, window_hours, max_amount) values ('BTC', 24, 1)
on conflict (currency) do nothing;

do $$ begin
  perform cron.schedule('sign-bitcoin-withdrawals',      '30 seconds', 'select sign_bitcoin_withdrawals()');
  perform cron.schedule('broadcast-bitcoin-withdrawals', '20 seconds', 'select broadcast_bitcoin_withdrawals()');
  perform cron.schedule('confirm-bitcoin-withdrawals',   '* * * * *',  'select confirm_bitcoin_withdrawals()');
exception when others then null; end $$;

revoke execute on function btc_le(numeric,int), btc_varint(int), btc_dsha256(bytea), btc_reverse(bytea),
  btc_testnet_script(text), btc_build_signed_tx(jsonb,jsonb), btc_hot_wallet(text), btc_select_coins(jsonb,numeric,numeric),
  sign_bitcoin_withdrawal(text), sign_bitcoin_withdrawals(), broadcast_bitcoin_withdrawals(),
  confirm_bitcoin_withdrawals(), process_solana_withdrawals(), process_evm_withdrawals(),
  process_tron_withdrawals(), process_evm_confirmations(), treasury_address(text)
  from public, anon, authenticated;
grant execute on function btc_testnet_script(text), btc_build_signed_tx(jsonb,jsonb), btc_select_coins(jsonb,numeric,numeric),
  sign_bitcoin_withdrawal(text), sign_bitcoin_withdrawals(), broadcast_bitcoin_withdrawals(),
  confirm_bitcoin_withdrawals(), process_solana_withdrawals(), process_evm_withdrawals(),
  process_tron_withdrawals(), process_evm_confirmations(), treasury_address(text)
  to service_role;
