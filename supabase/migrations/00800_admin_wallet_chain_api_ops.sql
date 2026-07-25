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
