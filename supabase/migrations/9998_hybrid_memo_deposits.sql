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
