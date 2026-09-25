-- A confirmed chain deposit opens the currency account it credits.
--
-- New entities only get EUR (engine) and USDT (00130) accounts, so the first
-- deposit of any other mapped asset (BTC, USDC, ...) failed inside
-- process_transfer and was never credited. The balance-delta path
-- (credit_balance_delta) already opened the account; the log/token path did not.

create or replace function credit_chain_deposit(
    chain_param text, txid_param text, log_index_param int,
    address_param text, currency_param text, amount_param numeric, confirmations_param int)
  returns text language plpgsql security definer set search_path = public, pg_temp
as $$
declare owner_eid bigint; owner_pub text; need int; dep chain_deposit%rowtype; result text;
begin
  if coalesce(auth.role(), '') <> 'service_role' and auth.role() is not null then
    perform require_admin_permission('chain.write');
  end if;
  select app_entity_id into owner_eid from watched_address
    where chain = chain_param and address = address_param;
  if owner_eid is null then return 'unwatched'; end if;
  select confirmations into need from chain where name = chain_param;

  insert into chain_deposit(chain, txid, log_index, address, currency, amount, confirmations)
    values (chain_param, txid_param, log_index_param, address_param, currency_param, amount_param, confirmations_param)
    on conflict (chain, txid, log_index)
      do update set confirmations = excluded.confirmations
    returning * into dep;

  if dep.credited_at is not null then return 'duplicate'; end if;
  if confirmations_param < coalesce(need, 12) then return 'pending'; end if;

  select pub_id into owner_pub from app_entity where id = owner_eid;
  if not exists (select 1 from currency_account
                 where app_entity_id = owner_eid and currency_name = currency_param) then
    perform create_currency_account(owner_pub, currency_param);
  end if;
  perform process_transfer('DEPOSIT', 'MASTER', amount_param, currency_param, owner_pub,
                           chain_param || ':' || txid_param, 'chain deposit', null);
  update chain_deposit set credited_at = now() where id = dep.id;
  result := 'credited';
  insert into admin_audit_log(action, target, detail)
    values ('CREDIT_CHAIN_DEPOSIT', chain_param || ':' || txid_param,
            jsonb_build_object('currency', currency_param, 'amount', amount_param, 'result', result));
  return result;
end $$;
