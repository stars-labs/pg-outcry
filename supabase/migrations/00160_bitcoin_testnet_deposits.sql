-- Bitcoin testnet4 deposits, fully in Postgres.
--
-- Addresses: native segwit P2WPKH (tb1q...), derived from the same HD master seed
-- as the other chains: priv = _derive_secp_priv(entity, 'bitcoin-testnet4'),
-- address = bech32('tb', 0, hash160(compressed pubkey)).
--
-- Detection: an Esplora API (mempool.space/testnet4 by default; any Esplora works,
-- set via admin_set_chain_config). Each output paying a watched address is credited
-- through credit_chain_deposit as (txid, vout), so confirmation gating, idempotency
-- and the chain-backed funding check are the same as for every other chain. Esplora
-- returns an address's newest transactions (up to 50 mempool + 25 confirmed); with a
-- 30 s poll a deposit address would need more than that between two polls to miss one.
--
-- Deposits only: there is no BTC withdrawal signer.

-- ── bech32 (BIP-173) ────────────────────────────────────────────────────────
create or replace function bech32_polymod(vals int[]) returns int
  language plpgsql immutable as $$
declare
  gen constant int[] := array[996825010, 642813549, 513874426, 1027748829, 705979059];
  chk int := 1; top int; v int; i int;
begin
  foreach v in array vals loop
    top := chk >> 25;
    chk := ((chk & 33554431) << 5) # v;          -- 33554431 = 0x1ffffff
    for i in 0..4 loop
      if (top >> i) & 1 = 1 then chk := chk # gen[i + 1]; end if;
    end loop;
  end loop;
  return chk;
end $$;

-- segwit v0 address for a 20- or 32-byte witness program
create or replace function segwit_v0_address(hrp text, program bytea) returns text
  language plpgsql immutable as $$
declare
  charset constant text := 'qpzry9x8gf2tvdw0s3jn54khce6mua7l';
  data int[] := array[0];                          -- witness version 0
  acc int := 0; bits int := 0; i int; pm int; expanded int[] := '{}'; out text := hrp || '1';
begin
  -- regroup 8-bit bytes into 5-bit words
  for i in 0 .. length(program) - 1 loop
    acc := (acc << 8) | get_byte(program, i);
    bits := bits + 8;
    while bits >= 5 loop
      bits := bits - 5;
      data := data || ((acc >> bits) & 31);
    end loop;
  end loop;
  if bits > 0 then data := data || ((acc << (5 - bits)) & 31); end if;

  for i in 1 .. length(hrp) loop expanded := expanded || (ascii(substr(hrp, i, 1)) >> 5); end loop;
  expanded := expanded || 0;
  for i in 1 .. length(hrp) loop expanded := expanded || (ascii(substr(hrp, i, 1)) & 31); end loop;

  pm := bech32_polymod(expanded || data || array[0,0,0,0,0,0]) # 1;
  for i in 0..5 loop data := data || ((pm >> (5 * (5 - i))) & 31); end loop;
  foreach i in array data loop out := out || substr(charset, i + 1, 1); end loop;
  return out;
end $$;

-- P2WPKH address of a secp256k1 private key
create or replace function btc_p2wpkh_address(priv bytea, hrp text) returns text
  language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare pub bytea := public.secp_pubkey(priv); compressed bytea;
begin
  -- secp_pubkey returns x ‖ y; the compressed form is (02 | 03 by y parity) ‖ x
  compressed := case when get_byte(pub, 63) % 2 = 0 then '\x02'::bytea else '\x03'::bytea end
                || substr(pub, 1, 32);
  return public.segwit_v0_address(hrp,
           extensions.digest(extensions.digest(compressed, 'sha256'), 'ripemd160'));
end $$;

-- ── chain + asset ───────────────────────────────────────────────────────────
insert into chain(name, kind, rpc_url, confirmations)
values ('bitcoin-testnet4', 'bitcoin', 'https://mempool.space/testnet4/api', 2)
on conflict (name) do nothing;
insert into chain_asset(chain, token, currency, decimals)
values ('bitcoin-testnet4', 'native', 'BTC', 8)
on conflict (chain, token) do nothing;

-- ── Esplora decoder (pure, fixture-tested) ──────────────────────────────────
-- /address/:a/txs -> one row per output paying `address_param`.
create or replace function decode_esplora_deposits(txs jsonb, address_param text, tip_height bigint)
  returns table(txid text, vout int, sats numeric, confirmations int)
  language sql immutable as $$
  select t.value->>'txid',
         (o.ordinality - 1)::int,
         (o.value->>'value')::numeric,
         case when (t.value->'status'->>'confirmed')::boolean
              then (tip_height - (t.value->'status'->>'block_height')::bigint + 1)::int
              else 0 end
  from jsonb_array_elements(txs) t,
       jsonb_array_elements(t.value->'vout') with ordinality o
  where o.value->>'scriptpubkey_address' = address_param;
$$;

-- ── poller ──────────────────────────────────────────────────────────────────
create or replace function poll_bitcoin(chain_param text) returns int
  language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare
  cfg chain%rowtype; cur text; dec int; tip bigint; w record; d record; resp extensions.http_response;
  nb int := 0;
begin
  select * into cfg from chain where name = chain_param and enabled and kind = 'bitcoin' and rpc_url is not null;
  if not found then return 0; end if;
  select currency, decimals into cur, dec from chain_asset where chain = chain_param and token = 'native';
  if cur is null then raise exception 'unmapped_native_asset: %', chain_param; end if;

  resp := extensions.http_get(cfg.rpc_url || '/blocks/tip/height');
  if resp.status <> 200 then raise exception 'tip height: http %', resp.status; end if;
  tip := trim(resp.content)::bigint;

  for w in select address from watched_address where chain = chain_param loop
    resp := extensions.http_get(cfg.rpc_url || '/address/' || w.address || '/txs');
    if resp.status <> 200 then raise exception 'address txs: http %', resp.status; end if;
    for d in select * from decode_esplora_deposits(resp.content::jsonb, w.address, tip) loop
      if credit_chain_deposit(chain_param, d.txid, d.vout, w.address, cur,
                              d.sats / power(10::numeric, dec), d.confirmations) = 'credited' then
        nb := nb + 1;
      end if;
    end loop;
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
                          when 'tron' then poll_native_tron(c.name)
                          when 'bitcoin' then poll_bitcoin(c.name) end;
    exception when others then
      raise warning 'poll_native % failed: %', c.name, sqlerrm;   -- one bad chain never blocks others
    end;
  end loop;
end $$;

-- ── deposit address ─────────────────────────────────────────────────────────
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
    elsif k = 'bitcoin' then
      addr := public.btc_p2wpkh_address(public._derive_secp_priv(eid, chain_param), 'tb');
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

revoke execute on function btc_p2wpkh_address(bytea,text), poll_bitcoin(text), poll_native_balances()
  from public, anon, authenticated;
grant execute on function btc_p2wpkh_address(bytea,text), poll_bitcoin(text), poll_native_balances()
  to service_role;
grant execute on function bech32_polymod(int[]), segwit_v0_address(text,bytea),
  decode_esplora_deposits(jsonb,text,bigint) to service_role;
revoke execute on function my_deposit_address(text) from public, anon;
grant execute on function my_deposit_address(text) to authenticated;
