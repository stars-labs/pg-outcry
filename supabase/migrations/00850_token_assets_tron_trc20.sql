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
