-- Stablecoin/token completion: in-DB ERC-20 + SPL withdrawal signing, native-vs-token
-- withdrawal routing for EVM/Solana (Tron already routed in 9997), a Solana memo deposit
-- poller, and USDC/USDT trading pairs. The two token signers were built by agents and
-- validated byte-identical to their canonical JS libs: ERC-20 vs ethers (120/120), SPL +
-- ATA derivation (incl. a pure-plpgsql ed25519 on-curve check) vs @solana/web3.js +
-- spl-token (100/100). Token DEPOSIT detection for TRC-20/SPL (memo) is the remaining item.

-- ════════════════════════ ERC-20 transfer signing (vs ethers 120/120) ═══════════
create or replace function public.evm_erc20_transfer_data(to_addr text, amount numeric)
returns bytea language plpgsql immutable as $function$
declare to_bytes bytea; amt_bytes bytea; selector constant bytea := '\xa9059cbb'::bytea;
begin
  to_bytes := decode(regexp_replace(lower(to_addr), '^0x', ''), 'hex');
  if length(to_bytes) <> 20 then raise exception 'to_addr must be 20 bytes, got %', length(to_bytes); end if;
  if amount < 0 then raise exception 'amount must be non-negative'; end if;
  amt_bytes := public.uint_to_minimal_bytes(amount);
  if length(amt_bytes) > 32 then raise exception 'amount exceeds uint256'; end if;
  return selector || decode(lpad(encode(to_bytes, 'hex'), 64, '0'), 'hex')
                  || decode(lpad(encode(amt_bytes, 'hex'), 64, '0'), 'hex');
end; $function$;

create or replace function public.evm_build_signed_token_tx(
  priv bytea, nonce numeric, gas_price numeric, gas_limit numeric,
  token_contract text, to_addr text, amount numeric, chain_id int)
returns text language plpgsql as $function$
declare token_bytes bytea; data_enc bytea; sighash bytea; sig jsonb; v01 int; v_final numeric;
        r_bytes bytea; s_bytes bytea; signing bytea; final_tx bytea;
begin
  token_bytes := decode(regexp_replace(lower(token_contract), '^0x', ''), 'hex');
  if length(token_bytes) <> 20 then raise exception 'token_contract must be 20 bytes'; end if;
  data_enc := public.rlp_encode_bytes(public.evm_erc20_transfer_data(to_addr, amount));
  signing := public.rlp_encode_list(array[
    public.rlp_encode_uint(nonce), public.rlp_encode_uint(gas_price),
    public.rlp_encode_uint(gas_limit), public.rlp_encode_bytes(token_bytes),
    public.rlp_encode_uint(0), data_enc,
    public.rlp_encode_uint(chain_id), public.rlp_encode_uint(0), public.rlp_encode_uint(0)]);
  sighash := public.keccak256(signing);
  sig := public.secp_sign(priv, sighash);
  v01 := (sig->>'v')::int; v_final := chain_id::numeric * 2 + 35 + v01;
  r_bytes := public.strip_leading_zeros(decode(lpad(sig->>'r', 64, '0'), 'hex'));
  s_bytes := public.strip_leading_zeros(decode(lpad(sig->>'s', 64, '0'), 'hex'));
  final_tx := public.rlp_encode_list(array[
    public.rlp_encode_uint(nonce), public.rlp_encode_uint(gas_price),
    public.rlp_encode_uint(gas_limit), public.rlp_encode_bytes(token_bytes),
    public.rlp_encode_uint(0), data_enc,
    public.rlp_encode_uint(v_final), public.rlp_encode_bytes(r_bytes), public.rlp_encode_bytes(s_bytes)]);
  return '0x' || encode(final_tx, 'hex');
end; $function$;

-- ════════════════════════ SPL transfer signing (vs web3.js 100/100) ═════════════
create or replace function public.sol_ed25519_on_curve(point bytea) returns boolean
  language plpgsql immutable set search_path to 'public', 'pg_temp' as $function$
declare
  p numeric := 57896044618658097711785492504343953926634992332820282019728792003956564819949;
  d numeric := 37095705934669439343138083508754565189542113879843219016388785533085940283555;
  y numeric := 0; y2 numeric; u numeric; v numeric; w numeric; vinv numeric;
  base numeric; expo numeric; res numeric; i int;
begin
  if octet_length(point) <> 32 then raise exception 'point must be 32 bytes'; end if;
  for i in reverse 31..0 loop y := y * 256 + get_byte(point, i); end loop;
  if y >= 57896044618658097711785492504343953926634992332820282019728792003956564819968 then
    y := y - 57896044618658097711785492504343953926634992332820282019728792003956564819968;
  end if;
  y := y % p; y2 := (y * y) % p; u := ((y2 - 1) % p + p) % p; v := ((d * y2 + 1) % p) % p;
  base := v % p; expo := p - 2; res := 1;
  while expo > 0 loop
    if (expo % 2) = 1 then res := (res * base) % p; end if;
    base := (base * base) % p; expo := div(expo, 2);
  end loop;
  vinv := res; w := (u * vinv) % p;
  if w = 0 then return true; end if;
  base := w % p; expo := (p - 1) / 2; res := 1;
  while expo > 0 loop
    if (expo % 2) = 1 then res := (res * base) % p; end if;
    base := (base * base) % p; expo := div(expo, 2);
  end loop;
  return res = 1;
end $function$;

create or replace function public.sol_ata(owner_pubkey bytea, mint bytea) returns bytea
  language plpgsql immutable set search_path to 'public', 'pg_temp' as $function$
declare
  token_program bytea := decode('06ddf6e1d765a193d9cbe146ceeb79ac1cb485ed5f5b37913a8cf5857eff00a9','hex');
  ata_program   bytea := decode('8c97258f4e2489f1bb3d1029148e0d830b5a1399daff1084048e7bd8dbe9f859','hex');
  pda_marker bytea := convert_to('ProgramDerivedAddress', 'UTF8'); bump int; cand bytea;
begin
  if octet_length(owner_pubkey) <> 32 then raise exception 'owner_pubkey must be 32 bytes'; end if;
  if octet_length(mint) <> 32 then raise exception 'mint must be 32 bytes'; end if;
  for bump in reverse 255..0 loop
    cand := extensions.digest(owner_pubkey || token_program || mint
      || set_byte('\x00'::bytea, 0, bump) || ata_program || pda_marker, 'sha256');
    if not public.sol_ed25519_on_curve(cand) then return cand; end if;
  end loop;
  raise exception 'unable to find off-curve PDA bump for ATA';
end $function$;

create or replace function public.sol_build_signed_token_tx(
    seed bytea, mint bytea, dest_owner bytea, amount numeric, decimals int, recent_blockhash bytea)
  returns text language plpgsql set search_path to 'public', 'pg_temp' as $function$
declare
  kp record; owner bytea; secret bytea;
  token_program bytea := decode('06ddf6e1d765a193d9cbe146ceeb79ac1cb485ed5f5b37913a8cf5857eff00a9','hex');
  src_ata bytea; dst_ata bytea; ordered bytea[]; header bytea; account_keys bytea;
  instr_data bytea; instruction bytea; i_src int; i_mint int; i_dst int; i_owner int; i_token int;
  message bytea; signature bytea; tx bytea;
begin
  if octet_length(seed) <> 32 then raise exception 'seed must be 32 bytes'; end if;
  if octet_length(mint) <> 32 then raise exception 'mint must be 32 bytes'; end if;
  if octet_length(dest_owner) <> 32 then raise exception 'dest_owner must be 32 bytes'; end if;
  if octet_length(recent_blockhash) <> 32 then raise exception 'blockhash must be 32 bytes'; end if;
  if decimals < 0 or decimals > 255 then raise exception 'decimals out of range'; end if;
  kp := pgsodium.crypto_sign_seed_new_keypair(seed); owner := kp.public; secret := kp.secret;
  src_ata := public.sol_ata(owner, mint); dst_ata := public.sol_ata(dest_owner, mint);
  header := set_byte(set_byte(set_byte('\x000000'::bytea, 0, 1), 1, 0), 2, 2);
  SELECT array_agg(pk ORDER BY (pk = owner) DESC, is_signer DESC, is_writable DESC,
                   public.base58_encode(pk) COLLATE "en-x-icu") INTO ordered
  FROM (VALUES (owner,true,true),(src_ata,false,true),(dst_ata,false,true),
               (mint,false,false),(token_program,false,false)) AS a(pk, is_signer, is_writable);
  account_keys := public.sol_shortvec(array_length(ordered, 1));
  FOR i_src IN 1 .. array_length(ordered, 1) LOOP account_keys := account_keys || ordered[i_src]; END LOOP;
  i_src := array_position(ordered, src_ata) - 1; i_mint := array_position(ordered, mint) - 1;
  i_dst := array_position(ordered, dst_ata) - 1; i_owner := array_position(ordered, owner) - 1;
  i_token := array_position(ordered, token_program) - 1;
  instr_data := set_byte('\x00'::bytea, 0, 12) || public.sol_u64le(amount) || set_byte('\x00'::bytea, 0, decimals);
  instruction := set_byte('\x00'::bytea, 0, i_token) || public.sol_shortvec(4)
    || set_byte('\x00'::bytea, 0, i_src) || set_byte('\x00'::bytea, 0, i_mint)
    || set_byte('\x00'::bytea, 0, i_dst) || set_byte('\x00'::bytea, 0, i_owner)
    || public.sol_shortvec(octet_length(instr_data)) || instr_data;
  message := header || account_keys || recent_blockhash || public.sol_shortvec(1) || instruction;
  signature := pgsodium.crypto_sign_detached(message, secret);
  tx := public.sol_shortvec(1) || signature || message;
  return translate(encode(tx, 'base64'), E'\n', '');
end $function$;

-- ════════════════════════ EVM withdrawal: route native ETH vs ERC-20 ════════════
create or replace function sign_and_broadcast_evm_withdrawal(request_pub text) returns text
  language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare wr record; cfg chain%rowtype; token text; dec int; priv bytea; from_addr text;
        nonce numeric; gas_price numeric; raw text; txhash text;
begin
  select pub_id, currency, amount, to_address, status, direction, broadcast_txid into wr
    from wallet_request where pub_id = request_pub for update;
  if not found then raise exception 'no_such_request'; end if;
  if wr.direction <> 'WITHDRAWAL' or wr.status <> 'APPROVED' then raise exception 'not_approved_withdrawal'; end if;
  if wr.broadcast_txid is not null then return wr.broadcast_txid; end if;
  if wr.to_address is null or left(wr.to_address, 2) <> '0x' then raise exception 'not_evm_address'; end if;
  select * into cfg from chain where name = 'ethereum-sepolia';
  if cfg.rpc_url is null then raise exception 'chain_not_configured'; end if;
  select ca.token, ca.decimals into token, dec from chain_asset ca
    where ca.chain = 'ethereum-sepolia' and ca.currency = wr.currency limit 1;
  if token is null then raise exception 'currency_not_supported_on_evm: %', wr.currency; end if;
  priv := public._derive_secp_priv(0, 'ethereum-sepolia'); from_addr := public.evm_address(priv);
  nonce := hex_to_numeric(substr(_evm_rpc(cfg.rpc_url, 'eth_getTransactionCount', jsonb_build_array(from_addr, 'pending')) #>> '{}', 3));
  gas_price := hex_to_numeric(substr(_evm_rpc(cfg.rpc_url, 'eth_gasPrice', '[]'::jsonb) #>> '{}', 3));
  if token = 'native' then
    raw := public.evm_build_signed_tx(priv, nonce, gas_price, 21000, wr.to_address, trunc(wr.amount * power(10::numeric, dec)), 11155111);
  else
    raw := public.evm_build_signed_token_tx(priv, nonce, gas_price, 100000, token, wr.to_address, trunc(wr.amount * power(10::numeric, dec)), 11155111);
  end if;
  txhash := '0x' || encode(public.keccak256(decode(substr(raw, 3), 'hex')), 'hex');
  perform _evm_rpc(cfg.rpc_url, 'eth_sendRawTransaction', jsonb_build_array(raw));
  perform mark_withdrawal_broadcast(request_pub, txhash);
  return txhash;
end $$;

-- ════════════════════════ Solana withdrawal: route native SOL vs SPL ════════════
create or replace function sign_and_broadcast_solana_withdrawal(request_pub text) returns text
  language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare wr record; cfg chain%rowtype; token text; dec int; seed bytea; bh text; resp jsonb;
        tx_b64 text; sig text;
begin
  select pub_id, amount, to_address, status, direction, broadcast_txid, currency into wr
    from wallet_request where pub_id = request_pub for update;
  if not found then raise exception 'no_such_request'; end if;
  if wr.direction <> 'WITHDRAWAL' or wr.status <> 'APPROVED' then raise exception 'not_approved_withdrawal'; end if;
  if wr.broadcast_txid is not null then return wr.broadcast_txid; end if;
  select * into cfg from chain where name = 'solana-testnet';
  if cfg.rpc_url is null then raise exception 'chain_not_configured'; end if;
  select ca.token, ca.decimals into token, dec from chain_asset ca
    where ca.chain = 'solana-testnet' and ca.currency = wr.currency limit 1;
  if token is null then raise exception 'currency_not_supported_on_solana: %', wr.currency; end if;
  seed := public._derive_ed25519_seed(0);
  resp := (extensions.http_post(cfg.rpc_url, jsonb_build_object('jsonrpc','2.0','id',1,'method','getLatestBlockhash',
    'params', jsonb_build_array(jsonb_build_object('commitment','finalized')))::text, 'application/json')).content::jsonb;
  bh := resp->'result'->'value'->>'blockhash';
  if bh is null then raise exception 'no_blockhash: %', resp; end if;
  if token = 'native' then
    tx_b64 := public.sol_build_signed_tx(seed, public.base58_decode(wr.to_address), trunc(wr.amount * power(10::numeric, dec)), public.base58_decode(bh));
  else
    tx_b64 := public.sol_build_signed_token_tx(seed, public.base58_decode(token), public.base58_decode(wr.to_address),
                trunc(wr.amount * power(10::numeric, dec)), dec, public.base58_decode(bh));
  end if;
  resp := (extensions.http_post(cfg.rpc_url, jsonb_build_object('jsonrpc','2.0','id',1,'method','sendTransaction',
    'params', jsonb_build_array(tx_b64, jsonb_build_object('encoding','base64')))::text, 'application/json')).content::jsonb;
  if resp ? 'error' then raise exception 'sol_send_error: %', resp->'error'; end if;
  sig := resp->>'result';
  perform mark_withdrawal_broadcast(request_pub, sig);
  return sig;
end $$;

-- ════════════════════════ Solana native-SOL memo deposit poller ═════════════════
create or replace function poll_solana_memo(chain_param text) returns int
  language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare cfg chain%rowtype; shared text; shared_pk bytea; cur text; dec int; sigs jsonb; s jsonb;
        tx jsonb; ix jsonb; memo text; amt numeric; idx int; n int := 0;
begin
  select * into cfg from chain where name = chain_param and enabled and kind = 'solana' and rpc_url is not null;
  if not found then return 0; end if;
  shared := public.treasury_address(chain_param); shared_pk := public.base58_decode(shared);
  select currency, decimals into cur, dec from chain_asset where chain = chain_param and token = 'native';
  sigs := (extensions.http_post(cfg.rpc_url, jsonb_build_object('jsonrpc','2.0','id',1,'method','getSignaturesForAddress',
    'params', jsonb_build_array(shared, jsonb_build_object('limit', 25)))::text, 'application/json')).content::jsonb -> 'result';
  for s in select * from jsonb_array_elements(coalesce(sigs, '[]'::jsonb)) loop
    if (s->>'confirmationStatus') <> 'finalized' or s->'err' is not null then continue; end if;
    tx := (extensions.http_post(cfg.rpc_url, jsonb_build_object('jsonrpc','2.0','id',1,'method','getTransaction',
      'params', jsonb_build_array(s->>'signature', jsonb_build_object('encoding','jsonParsed','maxSupportedTransactionVersion',0)))::text,
      'application/json')).content::jsonb -> 'result';
    -- lamports credited to the shared address (post-pre)
    amt := decode_solana_credit(tx, shared); if amt is null or amt <= 0 then continue; end if;
    -- memo = the spl-memo instruction's parsed string, if present
    memo := null;
    for ix in select * from jsonb_array_elements(coalesce(tx->'transaction'->'message'->'instructions','[]'::jsonb)) loop
      if ix->>'program' = 'spl-memo' then memo := ix->>'parsed'; exit; end if;
    end loop;
    if memo is null then continue; end if;
    if credit_memo_deposit(chain_param, s->>'signature', 0, memo, cur, amt / power(10::numeric, dec), 1) = 'credited' then n := n + 1; end if;
  end loop;
  return n;
end $$;
do $$ begin perform cron.schedule('poll-solana-memo', '30 seconds', 'select poll_solana_memo(''solana-testnet'')');
exception when others then null; end $$;

-- ════════════════════════ stablecoin trading pairs ══════════════════════════════
insert into instrument(pub_id, name, quote_currency, fx_instrument, base_currency, enabled) values
  (gen_random_uuid()::text, 'USDC_EUR', 'EUR', true, 'USDC', true),
  (gen_random_uuid()::text, 'USDT_EUR', 'EUR', true, 'USDT', true)
on conflict (name) do nothing;

-- MASTER needs USDT/USDC accounts to issue token deposits from (DEPOSIT MASTER→user).
do $$ begin perform create_currency_account('MASTER', 'USDT'); exception when others then null; end $$;
do $$ begin perform create_currency_account('MASTER', 'USDC'); exception when others then null; end $$;

-- my_chain_deposits must also surface MEMO deposits (chain_deposit.address = the memo
-- 'oc'||entity_id), not only deposits to watched (per-user derived) addresses.
create or replace view my_chain_deposits as
  select d.chain, d.txid, d.currency, d.amount, d.confirmations, d.credited_at, d.created_at
  from chain_deposit d
  where d.address in (select address from watched_address where app_entity_id = current_app_entity_id())
     or d.address = 'oc' || current_app_entity_id();
alter view my_chain_deposits set (security_invoker = on);
grant select on my_chain_deposits to authenticated;

-- chain_deposit had RLS enabled out-of-band (Supabase advisor) with NO policy, so the
-- security_invoker view returned nothing to anyone. Make it declarative: enable RLS +
-- a per-user SELECT policy (own watched-address deposits OR own memo deposits).
alter table chain_deposit enable row level security;
drop policy if exists own_chain_deposit on chain_deposit;
create policy own_chain_deposit on chain_deposit for select to authenticated
  using (address in (select address from watched_address where app_entity_id = current_app_entity_id())
         or address = 'oc' || current_app_entity_id());
grant select on chain_deposit to authenticated;

revoke execute on function
  public.evm_erc20_transfer_data(text,numeric), public.evm_build_signed_token_tx(bytea,numeric,numeric,numeric,text,text,numeric,int),
  public.sol_ed25519_on_curve(bytea), public.sol_ata(bytea,bytea),
  public.sol_build_signed_token_tx(bytea,bytea,bytea,numeric,int,bytea), poll_solana_memo(text)
  from public, anon, authenticated;
grant execute on function poll_solana_memo(text) to service_role;

-- ════════════════════════ token (TRC-20 / SPL) memo deposit detection ═══════════
-- Native TRX/SOL memo deposits credit via 9998/poll_solana_memo; these add USDT
-- (TRC-20) + USDC (SPL) deposits to the shared treasury address, attributed by memo.

-- Tron TRC-20: decode transfer(address,uint256) calldata (a9059cbb ++ to ++ amount).
create or replace function decode_tron_trigger_transfer(data text)
  returns table(to_hex text, amount_raw numeric) language sql immutable as $$
  select substr(data, 33, 40), hex_to_numeric(substr(data, 73, 64))
  where data ~* '^a9059cbb' and length(data) >= 136;
$$;

-- TRC-20 recipients appear in /transactions/trc20 (NOT /transactions, which is owner-
-- indexed and returns hex addresses). That endpoint has no memo, so fetch each tx's
-- raw_data.data (the memo) via /wallet/gettransactionbyid and attribute by it.
create or replace function poll_tron_token_memo(chain_param text) returns int
  language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare cfg chain%rowtype; shared text; resp jsonb; d jsonb; cur text; dec int; tx jsonb; memo text; n int := 0;
begin
  select * into cfg from chain where name = chain_param and enabled and kind = 'tron' and rpc_url is not null;
  if not found then return 0; end if;
  shared := public.treasury_address(chain_param);
  resp := (extensions.http_get(cfg.rpc_url || '/v1/accounts/' || shared
            || '/transactions/trc20?only_to=true&only_confirmed=true&limit=50')).content::jsonb;
  for d in select * from jsonb_array_elements(coalesce(resp->'data', '[]'::jsonb)) loop
    if d->>'type' <> 'Transfer' or d->>'to' <> shared then continue; end if;
    select currency, decimals into cur, dec from chain_asset
      where chain = chain_param and token = (d->'token_info'->>'address');
    if cur is null then continue; end if;
    tx := (extensions.http_post(cfg.rpc_url || '/wallet/gettransactionbyid',
            jsonb_build_object('value', d->>'transaction_id')::text, 'application/json')).content::jsonb;
    if (tx->'raw_data'->>'data') is null then continue; end if;        -- no memo → can't attribute
    memo := convert_from(decode(tx->'raw_data'->>'data', 'hex'), 'UTF8');
    if credit_memo_deposit(chain_param, d->>'transaction_id', 0, memo, cur, (d->>'value')::numeric / power(10::numeric, dec), 1) = 'credited'
      then n := n + 1; end if;
  end loop;
  return n;
end $$;

create or replace function poll_solana_token_memo(chain_param text) returns int
  language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare cfg chain%rowtype; shared text; shared_pk bytea; a record; mint bytea; ata text; sigs jsonb; s jsonb;
        tx jsonb; pre numeric; post numeric; bal jsonb; memo text; ix jsonb; amt numeric; n int := 0;
begin
  select * into cfg from chain where name = chain_param and enabled and kind = 'solana' and rpc_url is not null;
  if not found then return 0; end if;
  shared := public.treasury_address(chain_param); shared_pk := public.base58_decode(shared);
  for a in select token, currency, decimals from chain_asset where chain = chain_param and token <> 'native' loop
    mint := public.base58_decode(a.token);
    ata := public.base58_encode(public.sol_ata(shared_pk, mint));
    sigs := (extensions.http_post(cfg.rpc_url, jsonb_build_object('jsonrpc','2.0','id',1,'method','getSignaturesForAddress',
      'params', jsonb_build_array(ata, jsonb_build_object('limit', 25)))::text, 'application/json')).content::jsonb -> 'result';
    for s in select * from jsonb_array_elements(coalesce(sigs, '[]'::jsonb)) loop
      if (s->>'confirmationStatus') <> 'finalized' or s->'err' is not null then continue; end if;
      tx := (extensions.http_post(cfg.rpc_url, jsonb_build_object('jsonrpc','2.0','id',1,'method','getTransaction',
        'params', jsonb_build_array(s->>'signature', jsonb_build_object('encoding','jsonParsed','maxSupportedTransactionVersion',0)))::text,
        'application/json')).content::jsonb -> 'result';
      pre := 0; post := 0;
      for bal in select * from jsonb_array_elements(coalesce(tx->'meta'->'preTokenBalances','[]'::jsonb)) loop
        if bal->>'mint' = a.token and bal->>'owner' = shared then pre := (bal->'uiTokenAmount'->>'amount')::numeric; end if;
      end loop;
      for bal in select * from jsonb_array_elements(coalesce(tx->'meta'->'postTokenBalances','[]'::jsonb)) loop
        if bal->>'mint' = a.token and bal->>'owner' = shared then post := (bal->'uiTokenAmount'->>'amount')::numeric; end if;
      end loop;
      amt := post - pre;
      if amt <= 0 then continue; end if;
      memo := null;
      for ix in select * from jsonb_array_elements(coalesce(tx->'transaction'->'message'->'instructions','[]'::jsonb)) loop
        if ix->>'program' = 'spl-memo' then memo := ix->>'parsed'; exit; end if;
      end loop;
      if memo is null then continue; end if;
      if credit_memo_deposit(chain_param, s->>'signature', 0, memo, a.currency, amt / power(10::numeric, a.decimals), 1) = 'credited'
        then n := n + 1; end if;
    end loop;
  end loop;
  return n;
end $$;

do $$ begin
  perform cron.schedule('poll-tron-token-memo',   '30 seconds', 'select poll_tron_token_memo(''tron-nile'')');
  perform cron.schedule('poll-solana-token-memo', '30 seconds', 'select poll_solana_token_memo(''solana-testnet'')');
exception when others then null; end $$;

revoke execute on function
  decode_tron_trigger_transfer(text), poll_tron_token_memo(text), poll_solana_token_memo(text)
  from public, anon, authenticated;
grant execute on function poll_tron_token_memo(text), poll_solana_token_memo(text) to service_role;

-- ════════════════════════ withdrawal cooling = chain irreversibility time ═══════
-- Replace the fixed 24h address-cooling with each chain's on-chain finality (the time
-- after which a tx can't be rolled back), inferred from the destination address.
alter table chain add column if not exists finality_seconds int not null default 180;
update chain set finality_seconds = case name
  when 'ethereum-sepolia' then 180   -- ~practical Sepolia finality
  when 'tron-nile'        then 60    -- ~19 SR confirmations
  when 'solana-testnet'   then 15    -- ~finalized commitment
  else 180 end;

-- chain inferred from address form: 0x→evm, T→tron, else→solana
create or replace function _addr_finality_seconds(addr text) returns int
  language sql stable set search_path = public, pg_temp as $$
  select coalesce((select finality_seconds from chain where name =
    case when left(addr,2)='0x' then 'ethereum-sepolia'
         when left(addr,1)='T'  then 'tron-nile'
         else 'solana-testnet' end), 180);
$$;

create or replace function add_withdrawal_address(currency_param text, address_param text,
                                                  label_param text default null)
  returns json language plpgsql security definer set search_path = public, pg_temp
as $$
declare eid bigint := current_app_entity_id(); r withdrawal_address%rowtype; fin int;
begin
  if eid is null then raise exception 'not_authenticated'; end if;
  if coalesce(trim(address_param), '') = '' then raise exception 'address_required'; end if;
  fin := public._addr_finality_seconds(address_param);
  insert into withdrawal_address(app_entity_id, currency, address, label, active_at)
    values (eid, currency_param, address_param, label_param, now() + make_interval(secs => fin))
    on conflict (app_entity_id, currency, address) do update
      set removed_at = null, label = excluded.label
    returning * into r;
  return json_build_object('id', r.id, 'currency', r.currency, 'address', r.address,
    'active_at', r.active_at, 'note', 'usable once on-chain-irreversible (active_at)');
end $$;

-- recompute cooling for existing still-cooling addresses to the new finality basis
update withdrawal_address w set active_at = w.created_at + make_interval(secs => public._addr_finality_seconds(w.address))
  where w.active_at > now();

grant execute on function add_withdrawal_address(text, text, text) to authenticated;
revoke execute on function _addr_finality_seconds(text) from public, anon, authenticated;
