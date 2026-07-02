-- Admin RBAC for the back-office.
--
-- Browser admins now authenticate as normal Supabase Auth users (authenticated).
-- This hosted test build is intentionally open: every signed-in user receives
-- full back-office permissions by default. The role tables stay in place so the
-- deployment can be tightened later without changing the admin console shape.
-- service_role remains a backend/root role for scripts, CI, cron, and bootstrap
-- only; the web console no longer needs or accepts it.

create table if not exists admin_role (
  name        text primary key,
  description text not null
);

create table if not exists admin_permission (
  name        text primary key,
  description text not null
);

create table if not exists admin_role_permission (
  role       text not null references admin_role(name) on delete cascade,
  permission text not null references admin_permission(name) on delete cascade,
  primary key (role, permission)
);

create table if not exists admin_operator_role (
  user_id    uuid not null references auth.users(id) on delete cascade,
  role       text not null references admin_role(name) on delete cascade,
  granted_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  primary key (user_id, role)
);

insert into admin_permission(name, description) values
  ('rbac.read', 'Read operator roles and permissions'),
  ('rbac.write', 'Grant and revoke operator roles'),
  ('recon.read', 'Read reconciliation health'),
  ('wallet.read', 'Read wallet approval queues'),
  ('wallet.approve', 'Approve or reject wallet requests'),
  ('withdrawal.sign', 'Claim and update withdrawal signer queue items'),
  ('chain.read', 'Read chain deposit configuration and deposits'),
  ('chain.write', 'Update chain config, asset mappings, and manual credits'),
  ('account.read', 'Read account status'),
  ('account.suspend', 'Suspend and unsuspend accounts'),
  ('referral.read', 'Read referral liabilities'),
  ('referral.pay', 'Pay referral earnings'),
  ('market.read', 'Read fee schedules and instrument risk'),
  ('market.write', 'Update fee schedules and instrument risk'),
  ('derivatives.read', 'Read derivatives, margin, and staking control data'),
  ('derivatives.write', 'Update derivatives, margin, and staking controls'),
  ('security.read', 'Read API key oversight data'),
  ('security.revoke_api_key', 'Revoke customer API keys'),
  ('audit.read', 'Read admin audit logs')
on conflict (name) do update set description = excluded.description;

insert into admin_role(name, description) values
  ('super_admin', 'Full back-office access'),
  ('treasury', 'Cash, wallet approval, withdrawal signing, and chain operations'),
  ('risk', 'Market risk, derivatives, margin, and staking operations'),
  ('support', 'Client account operations'),
  ('finance', 'Wallet and referral payout operations'),
  ('security', 'API access and security operations'),
  ('auditor', 'Read-only compliance and audit review')
on conflict (name) do update set description = excluded.description;

insert into admin_role_permission(role, permission)
select 'super_admin', name from admin_permission
on conflict do nothing;

insert into admin_role_permission(role, permission) values
  ('treasury', 'recon.read'),
  ('treasury', 'wallet.read'),
  ('treasury', 'wallet.approve'),
  ('treasury', 'withdrawal.sign'),
  ('treasury', 'chain.read'),
  ('treasury', 'chain.write'),
  ('treasury', 'audit.read'),
  ('risk', 'recon.read'),
  ('risk', 'market.read'),
  ('risk', 'market.write'),
  ('risk', 'derivatives.read'),
  ('risk', 'derivatives.write'),
  ('risk', 'audit.read'),
  ('support', 'account.read'),
  ('support', 'account.suspend'),
  ('support', 'wallet.read'),
  ('support', 'audit.read'),
  ('finance', 'recon.read'),
  ('finance', 'wallet.read'),
  ('finance', 'wallet.approve'),
  ('finance', 'chain.read'),
  ('finance', 'referral.read'),
  ('finance', 'referral.pay'),
  ('finance', 'audit.read'),
  ('security', 'security.read'),
  ('security', 'security.revoke_api_key'),
  ('security', 'account.read'),
  ('security', 'audit.read'),
  ('auditor', 'recon.read'),
  ('auditor', 'wallet.read'),
  ('auditor', 'chain.read'),
  ('auditor', 'account.read'),
  ('auditor', 'referral.read'),
  ('auditor', 'market.read'),
  ('auditor', 'derivatives.read'),
  ('auditor', 'security.read'),
  ('auditor', 'audit.read')
on conflict do nothing;

create or replace function admin_has_permission(permission_param text)
  returns boolean
  language plpgsql
  stable
  security definer
  set search_path = public, auth, pg_temp
as $$
begin
  if auth.role() = 'service_role' then
    return true;
  end if;
  if auth.uid() is null then
    return false;
  end if;
  return exists (select 1 from admin_permission where name = permission_param);
end $$;

create or replace function admin_has_any_permission(permissions text[])
  returns boolean
  language sql
  stable
  security definer
  set search_path = public, auth, pg_temp
as $$
  select (auth.role() = 'service_role' or auth.uid() is not null)
      and exists (select 1 from admin_permission where name = any(permissions))
$$;

create or replace function current_admin_permissions()
  returns text[]
  language sql
  stable
  security definer
  set search_path = public, auth, pg_temp
as $$
  select coalesce(array_agg(name order by name), '{}'::text[])
  from admin_permission
  where auth.role() = 'service_role' or auth.uid() is not null
$$;

create or replace function require_admin_permission(permission_param text)
  returns void
  language plpgsql
  stable
  security definer
  set search_path = public, auth, pg_temp
as $$
begin
  if admin_has_permission(permission_param) then
    return;
  end if;
  if auth.uid() is null then
    raise exception 'not_authenticated';
  end if;
  raise exception 'insufficient_admin_permission: %', permission_param;
end $$;

create or replace function admin_actor_roles()
  returns text[]
  language sql
  stable
  security definer
  set search_path = public, auth, pg_temp
as $$
  with explicit as (
    select array_agg(role order by role) as roles
    from admin_operator_role
    where user_id = auth.uid()
  )
  select case
    when auth.role() = 'service_role' then array['service_role']::text[]
    when auth.uid() is null then '{}'::text[]
    else coalesce((select roles from explicit), array['super_admin']::text[])
  end
$$;

create or replace function fill_admin_audit_actor()
  returns trigger
  language plpgsql
  security definer
  set search_path = public, auth, pg_temp
as $$
declare roles text[];
begin
  roles := admin_actor_roles();
  new.actor_user_id := coalesce(new.actor_user_id, auth.uid());
  new.actor_roles := coalesce(new.actor_roles, roles);
  new.detail := coalesce(new.detail, '{}'::jsonb) ||
    jsonb_build_object('actor_user_id', auth.uid(), 'actor_roles', roles);
  return new;
end $$;

alter table admin_audit_log add column if not exists actor_user_id uuid;
alter table admin_audit_log add column if not exists actor_roles text[];
drop trigger if exists trg_admin_audit_actor on admin_audit_log;
create trigger trg_admin_audit_actor
  before insert on admin_audit_log
  for each row execute function fill_admin_audit_actor();

create or replace function admin_grant_operator_role(user_id_param uuid, role_param text)
  returns void
  language plpgsql
  security definer
  set search_path = public, auth, pg_temp
as $$
begin
  perform require_admin_permission('rbac.write');
  if not exists (select 1 from auth.users where id = user_id_param) then
    raise exception 'auth_user_not_found';
  end if;
  if not exists (select 1 from admin_role where name = role_param) then
    raise exception 'admin_role_not_found: %', role_param;
  end if;
  insert into admin_operator_role(user_id, role, granted_by)
    values (user_id_param, role_param, auth.uid())
  on conflict do nothing;
  insert into admin_audit_log(action, target, detail)
    values ('GRANT_OPERATOR_ROLE', user_id_param::text, jsonb_build_object('role', role_param));
end $$;

create or replace function admin_grant_operator_role_by_email(email_param text, role_param text)
  returns void
  language plpgsql
  security definer
  set search_path = public, auth, pg_temp
as $$
declare uid uuid;
begin
  perform require_admin_permission('rbac.write');
  select id into uid from auth.users where lower(email) = lower(email_param);
  if uid is null then raise exception 'auth_user_not_found: %', email_param; end if;
  perform admin_grant_operator_role(uid, role_param);
end $$;

create or replace function admin_revoke_operator_role(user_id_param uuid, role_param text)
  returns void
  language plpgsql
  security definer
  set search_path = public, auth, pg_temp
as $$
begin
  perform require_admin_permission('rbac.write');
  delete from admin_operator_role where user_id = user_id_param and role = role_param;
  insert into admin_audit_log(action, target, detail)
    values ('REVOKE_OPERATOR_ROLE', user_id_param::text, jsonb_build_object('role', role_param));
end $$;

-- Reconciliation is now an operator-readable health check, not a public/auth user
-- endpoint. service_role still passes require_admin_permission for automation.
create or replace function reconcile()
  returns table(check_name text, failures bigint, status text)
  language plpgsql
  security definer
  set search_path = public, pg_temp
as $$
begin
  perform require_admin_permission('recon.read');
  return query
    select 'cash_balance_matches_ledger'::text, count(*)::bigint,
           case when count(*) = 0 then 'PASS' else 'FAIL' end::text
    from (
      select ca.id
      from currency_account ca
      join app_entity ae on ae.id = ca.app_entity_id and ae.type <> 'MASTER'
      left join transfer_ledger_entry le on le.currency_account_id = ca.id
      group by ca.id, ca.amount
      having ca.amount <> coalesce(sum(case when le.entry_type = 'CREDIT' then le.amount else -le.amount end), 0)
    ) bad

    union all
    select 'transfer_double_entry_balanced'::text, count(*)::bigint,
           case when count(*) = 0 then 'PASS' else 'FAIL' end::text
    from (
      select transfer_id
      from transfer_ledger_entry
      group by transfer_id
      having sum(case when entry_type = 'DEBIT' then amount else 0 end)
           <> sum(case when entry_type = 'CREDIT' then amount else 0 end)
    ) bad

    union all
    select 'reservations_consistent'::text, count(*)::bigint,
           case when count(*) = 0 then 'PASS' else 'FAIL' end::text
    from currency_account ca
    left join (
      select app_entity_id, currency, sum(amount) amt
      from wallet_request wr where wr.status = 'PENDING' and wr.direction = 'WITHDRAWAL'
      group by app_entity_id, currency
    ) p on p.app_entity_id = ca.app_entity_id and p.currency = ca.currency_name
    join app_entity ae on ae.id = ca.app_entity_id and ae.type <> 'MASTER'
    where ca.amount_reserved < coalesce(p.amt, 0)
       or ca.amount_reserved > ca.amount
       or ca.amount < 0

    union all
    select 'approved_wallet_has_transfer'::text, count(*)::bigint,
           case when count(*) = 0 then 'PASS' else 'FAIL' end::text
    from wallet_request w
    where w.status = 'APPROVED'
      and (w.transfer_pub_id is null or not exists (select 1 from transfer t where t.pub_id = w.transfer_pub_id))

    union all
    select 'issuance_conserved'::text, count(*)::bigint,
           case when count(*) = 0 then 'PASS' else 'FAIL' end::text
    from (
      select cust.currency_name
      from (
        select currency_name, coalesce(sum(amount),0) bal
        from currency_account ca join app_entity ae on ae.id = ca.app_entity_id and ae.type <> 'MASTER'
        group by currency_name
      ) cust
      join (
        select ca.currency_name,
               coalesce(sum(case when le.entry_type = 'DEBIT' then le.amount else -le.amount end),0) net_out
        from currency_account ca
        join app_entity ae on ae.id = ca.app_entity_id and ae.type = 'MASTER'
        left join transfer_ledger_entry le on le.currency_account_id = ca.id
        group by ca.currency_name
      ) m on m.currency_name = cust.currency_name
      where cust.bal <> m.net_out
    ) bad;
end $$;

create or replace view reconciliation_report as select * from reconcile();

-- Admin RPCs guarded by permission checks.
create or replace function admin_suspend_entity(entity_pub text, reason text default null)
  returns void language plpgsql security definer set search_path = public, pg_temp
as $$
begin
  perform require_admin_permission('account.suspend');
  update app_entity set status = 'SUSPENDED', updated_at = current_timestamp where pub_id = entity_pub;
  if not found then raise exception 'entity_not_found'; end if;
  insert into admin_audit_log(action, target, detail)
    values ('SUSPEND_ENTITY', entity_pub, jsonb_build_object('reason', reason));
end $$;

create or replace function admin_unsuspend_entity(entity_pub text)
  returns void language plpgsql security definer set search_path = public, pg_temp
as $$
begin
  perform require_admin_permission('account.suspend');
  update app_entity set status = 'ACTIVE', updated_at = current_timestamp where pub_id = entity_pub;
  if not found then raise exception 'entity_not_found'; end if;
  insert into admin_audit_log(action, target, detail) values ('UNSUSPEND_ENTITY', entity_pub, '{}'::jsonb);
end $$;

create or replace function admin_set_fee(
    fee_type text, currency_param text, percentage_param numeric,
    min_param numeric default null, max_param numeric default null)
  returns void language plpgsql security definer set search_path = public, pg_temp
as $$
begin
  perform require_admin_permission('market.write');
  perform 1 from currency where name = currency_param;
  if not found then raise exception 'unknown_currency: %', currency_param; end if;
  delete from fee where type = fee_type and currency_name = currency_param;
  insert into fee(type, currency_name, percentage, min, max)
    values (fee_type, currency_param, percentage_param, min_param, max_param);
  insert into admin_audit_log(action, target, detail)
    values ('SET_FEE', fee_type, jsonb_build_object(
      'currency', currency_param, 'percentage', percentage_param, 'min', min_param, 'max', max_param));
end $$;

create or replace function admin_set_instrument_risk(
    instrument_name_param text, max_amount numeric, max_notional numeric, band_pct numeric)
  returns void language plpgsql security definer set search_path = public, pg_temp
as $$
declare iid bigint;
begin
  perform require_admin_permission('market.write');
  select id into iid from instrument where name = instrument_name_param;
  if iid is null then raise exception 'instrument_not_found'; end if;
  insert into instrument_risk(instrument_id, max_order_amount, max_order_notional, price_band_pct)
    values (iid, max_amount, max_notional, band_pct)
  on conflict (instrument_id) do update
    set max_order_amount = excluded.max_order_amount,
        max_order_notional = excluded.max_order_notional,
        price_band_pct = excluded.price_band_pct,
        updated_at = current_timestamp;
  insert into admin_audit_log(action, target, detail)
    values ('SET_RISK', instrument_name_param, jsonb_build_object(
      'max_order_amount', max_amount, 'max_order_notional', max_notional, 'price_band_pct', band_pct));
end $$;

create or replace function approve_wallet_request(request_pub_param text, note_param text default null)
  returns text
  language plpgsql security definer set search_path = public, pg_temp
as $$
declare
  r   wallet_request%rowtype;
  pub text;
  tr  text;
begin
  perform require_admin_permission('wallet.approve');
  select * into r from wallet_request where pub_id = request_pub_param for update;
  if not found then raise exception 'request_not_found'; end if;
  if r.status <> 'PENDING' then raise exception 'request_not_pending: %', r.status; end if;
  select pub_id into pub from app_entity where id = r.app_entity_id;

  if r.direction = 'DEPOSIT' then
    tr := process_transfer('DEPOSIT', 'MASTER', r.amount, r.currency, pub,
                           'wallet:' || r.pub_id, 'wallet deposit', null);
  else
    update currency_account
      set amount_reserved = greatest(amount_reserved - r.amount, 0), updated_at = current_timestamp
      where app_entity_id = r.app_entity_id and currency_name = r.currency;
    tr := create_transfer('WITHDRAWAL', pub, r.amount, r.currency, 'MASTER',
                          'wallet:' || r.pub_id, 'wallet withdrawal');
  end if;

  update wallet_request
    set status = 'APPROVED', transfer_pub_id = tr, note = note_param, resolved_at = current_timestamp
    where id = r.id;
  insert into admin_audit_log(action, target, detail)
    values ('APPROVE_WALLET_REQUEST', request_pub_param, jsonb_build_object('direction', r.direction, 'currency', r.currency, 'amount', r.amount));
  return tr;
end $$;

create or replace function reject_wallet_request(request_pub_param text, note_param text default null)
  returns void
  language plpgsql security definer set search_path = public, pg_temp
as $$
declare r wallet_request%rowtype;
begin
  perform require_admin_permission('wallet.approve');
  select * into r from wallet_request where pub_id = request_pub_param for update;
  if not found then raise exception 'request_not_found'; end if;
  if r.status <> 'PENDING' then raise exception 'request_not_pending: %', r.status; end if;

  if r.direction = 'WITHDRAWAL' then
    update currency_account
      set amount_reserved = greatest(amount_reserved - r.amount, 0), updated_at = current_timestamp
      where app_entity_id = r.app_entity_id and currency_name = r.currency;
  end if;

  update wallet_request
    set status = 'REJECTED', note = note_param, resolved_at = current_timestamp
    where id = r.id;
  insert into admin_audit_log(action, target, detail)
    values ('REJECT_WALLET_REQUEST', request_pub_param, jsonb_build_object('direction', r.direction, 'currency', r.currency, 'amount', r.amount));
end $$;

create or replace function next_withdrawal_to_sign()
  returns json
  language plpgsql security definer set search_path = public, pg_temp
as $$
declare r wallet_request%rowtype;
begin
  perform require_admin_permission('withdrawal.sign');
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
  insert into admin_audit_log(action, target, detail)
    values ('CLAIM_WITHDRAWAL_TO_SIGN', r.pub_id, jsonb_build_object('currency', r.currency, 'amount', r.amount));

  return json_build_object(
    'pub_id',     r.pub_id,
    'currency',   r.currency,
    'amount',     r.amount,
    'to_address', r.to_address);
end $$;

create or replace function mark_withdrawal_broadcast(request_pub text, txid text)
  returns boolean
  language plpgsql security definer set search_path = public, pg_temp
as $$
declare n int;
begin
  perform require_admin_permission('withdrawal.sign');
  if coalesce(trim(txid), '') = '' then raise exception 'txid_required'; end if;
  update wallet_request
     set broadcast_txid = txid, broadcast_at = current_timestamp
   where pub_id = request_pub
     and direction = 'WITHDRAWAL'
     and broadcast_txid is null;
  get diagnostics n = row_count;
  if n > 0 then
    insert into admin_audit_log(action, target, detail)
      values ('MARK_WITHDRAWAL_BROADCAST', request_pub, jsonb_build_object('txid', txid));
    return true;
  end if;
  if exists (select 1 from wallet_request where pub_id = request_pub) then return false; end if;
  raise exception 'request_not_found: %', request_pub;
end $$;

create or replace function mark_withdrawal_confirmed(request_pub text)
  returns boolean
  language plpgsql security definer set search_path = public, pg_temp
as $$
declare n int;
begin
  perform require_admin_permission('withdrawal.sign');
  update wallet_request
     set confirmed_at = current_timestamp
   where pub_id = request_pub
     and direction = 'WITHDRAWAL'
     and broadcast_txid is not null
     and confirmed_at is null;
  get diagnostics n = row_count;
  if n > 0 then
    insert into admin_audit_log(action, target, detail)
      values ('MARK_WITHDRAWAL_CONFIRMED', request_pub, '{}'::jsonb);
    return true;
  end if;
  if exists (select 1 from wallet_request where pub_id = request_pub and confirmed_at is not null)
    then return false; end if;
  raise exception 'not_broadcast_or_not_found: %', request_pub;
end $$;

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
  perform process_transfer('DEPOSIT', 'MASTER', amount_param, currency_param, owner_pub,
                           chain_param || ':' || txid_param, 'chain deposit', null);
  update chain_deposit set credited_at = now() where id = dep.id;
  result := 'credited';
  insert into admin_audit_log(action, target, detail)
    values ('CREDIT_CHAIN_DEPOSIT', chain_param || ':' || txid_param,
            jsonb_build_object('currency', currency_param, 'amount', amount_param, 'result', result));
  return result;
end $$;

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
  perform require_admin_permission('chain.write');
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
  perform require_admin_permission('chain.write');
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
  perform require_admin_permission('security.revoke_api_key');
  if coalesce(trim(key_id_param), '') = '' then raise exception 'key_id_required'; end if;
  update api_key set revoked_at = now()
   where key_id = key_id_param and revoked_at is null;
  get diagnostics n = row_count;

  insert into admin_audit_log(action, target, detail)
    values ('REVOKE_API_KEY', key_id_param, jsonb_build_object('changed', n > 0));
  return n > 0;
end $$;

create or replace function pay_referral_earnings(entity_pub text, currency_param text)
  returns numeric language plpgsql security definer set search_path = public, pg_temp
as $$
declare eid bigint; total numeric;
begin
  perform require_admin_permission('referral.pay');
  select id into eid from app_entity where pub_id = entity_pub;
  if eid is null then raise exception 'entity_not_found'; end if;
  select coalesce(sum(amount), 0) into total from referral_earning
    where referrer_entity = eid and currency = currency_param and paid_at is null;
  if total <= 0 then return 0; end if;
  perform process_transfer('DEPOSIT', 'MASTER', total, currency_param, entity_pub,
                           'referral', 'referral payout', null);
  update referral_earning set paid_at = now()
    where referrer_entity = eid and currency = currency_param and paid_at is null;
  insert into admin_audit_log(action, target, detail)
    values ('PAY_REFERRAL_EARNINGS', entity_pub, jsonb_build_object('currency', currency_param, 'amount', total));
  return total;
end $$;

create or replace function admin_set_stake_pool(
    currency_param text,
    apr_param numeric,
    unbond_seconds_param int default null)
  returns void
  language plpgsql
  security definer
  set search_path = public, pg_temp
as $$
begin
  perform require_admin_permission('derivatives.write');
  if coalesce(trim(currency_param), '') = '' then raise exception 'currency_required'; end if;
  if apr_param is null or apr_param < 0 then raise exception 'invalid_apr'; end if;
  perform 1 from currency where name = currency_param;
  if not found then raise exception 'unknown_currency: %', currency_param; end if;

  if exists (select 1 from stake_pool where currency = currency_param) then
    perform _stake_update_pool(currency_param);
    update stake_pool set apr = apr_param, updated_at = now() where currency = currency_param;
  else
    insert into stake_pool(currency, apr) values (currency_param, apr_param);
  end if;

  if unbond_seconds_param is not null then
    if unbond_seconds_param < 0 then raise exception 'invalid_unbond_seconds'; end if;
    insert into stake_config(id, unbond_seconds) values (1, unbond_seconds_param)
      on conflict (id) do update set unbond_seconds = excluded.unbond_seconds;
  end if;

  insert into admin_audit_log(action, target, detail)
    values ('SET_STAKE_POOL', currency_param,
            jsonb_build_object('apr', apr_param, 'unbond_seconds', unbond_seconds_param));
end $$;

create or replace function admin_set_margin_terms(
    max_leverage_param numeric,
    maintenance_ratio_param numeric,
    borrow_apr_param numeric)
  returns void
  language plpgsql
  security definer
  set search_path = public, pg_temp
as $$
declare e bigint;
begin
  perform require_admin_permission('derivatives.write');
  if max_leverage_param is null or max_leverage_param <= 1 then raise exception 'invalid_max_leverage'; end if;
  if maintenance_ratio_param is null or maintenance_ratio_param <= 0 or maintenance_ratio_param >= 1 then
    raise exception 'invalid_maintenance_ratio';
  end if;
  if borrow_apr_param is null or borrow_apr_param < 0 then raise exception 'invalid_borrow_apr'; end if;

  for e in select distinct app_entity_id from margin_loan where principal + accrued > 0 loop
    perform _margin_accrue(e);
  end loop;

  insert into margin_config(id, max_leverage, maintenance_ratio, borrow_apr)
    values (1, max_leverage_param, maintenance_ratio_param, borrow_apr_param)
  on conflict (id) do update
    set max_leverage = excluded.max_leverage,
        maintenance_ratio = excluded.maintenance_ratio,
        borrow_apr = excluded.borrow_apr;

  insert into admin_audit_log(action, target, detail)
    values ('SET_MARGIN_TERMS', 'margin_config',
            jsonb_build_object('max_leverage', max_leverage_param,
                               'maintenance_ratio', maintenance_ratio_param,
                               'borrow_apr', borrow_apr_param));
end $$;

create or replace function admin_set_perp_market(
    symbol_param text,
    index_symbol_param text default null,
    margin_currency_param text default null,
    mark_price_param numeric default null,
    funding_rate_param numeric default null,
    max_leverage_param numeric default null,
    maintenance_ratio_param numeric default null)
  returns void
  language plpgsql
  security definer
  set search_path = public, pg_temp
as $$
declare existing perp_market%rowtype;
begin
  perform require_admin_permission('derivatives.write');
  if coalesce(trim(symbol_param), '') = '' then raise exception 'symbol_required'; end if;
  if mark_price_param is not null and mark_price_param <= 0 then raise exception 'invalid_mark_price'; end if;
  if max_leverage_param is not null and max_leverage_param <= 1 then raise exception 'invalid_max_leverage'; end if;
  if maintenance_ratio_param is not null and (maintenance_ratio_param <= 0 or maintenance_ratio_param >= 1) then
    raise exception 'invalid_maintenance_ratio';
  end if;

  select * into existing from perp_market where symbol = symbol_param;
  if not found and coalesce(trim(index_symbol_param), '') = '' then
    raise exception 'index_symbol_required_for_new_market';
  end if;

  if index_symbol_param is not null then
    perform 1 from instrument where name = index_symbol_param;
    if not found then raise exception 'unknown_index_symbol: %', index_symbol_param; end if;
  end if;
  if margin_currency_param is not null then
    perform 1 from currency where name = margin_currency_param;
    if not found then raise exception 'unknown_margin_currency: %', margin_currency_param; end if;
  end if;

  insert into perp_market(symbol, index_symbol, margin_currency, mark_price, funding_rate, max_leverage, maintenance_ratio, updated_at)
    values (symbol_param,
            coalesce(index_symbol_param, existing.index_symbol),
            coalesce(margin_currency_param, existing.margin_currency, 'EUR'),
            mark_price_param,
            coalesce(funding_rate_param, existing.funding_rate, 0),
            coalesce(max_leverage_param, existing.max_leverage, 10),
            coalesce(maintenance_ratio_param, existing.maintenance_ratio, 0.05),
            now())
  on conflict (symbol) do update
    set index_symbol = coalesce(excluded.index_symbol, perp_market.index_symbol),
        margin_currency = coalesce(excluded.margin_currency, perp_market.margin_currency),
        mark_price = coalesce(excluded.mark_price, perp_market.mark_price),
        funding_rate = excluded.funding_rate,
        max_leverage = excluded.max_leverage,
        maintenance_ratio = excluded.maintenance_ratio,
        updated_at = now();

  insert into admin_audit_log(action, target, detail)
    values ('SET_PERP_MARKET', symbol_param,
            jsonb_build_object('index_symbol', index_symbol_param,
                               'margin_currency', margin_currency_param,
                               'mark_price', mark_price_param,
                               'funding_rate', funding_rate_param,
                               'max_leverage', max_leverage_param,
                               'maintenance_ratio', maintenance_ratio_param));
end $$;

create or replace function admin_run_derivative_jobs(
    update_marks boolean default true,
    apply_funding boolean default false,
    check_perps boolean default true,
    check_margin boolean default true,
    process_unbonds boolean default true)
  returns jsonb
  language plpgsql
  security definer
  set search_path = public, pg_temp
as $$
declare
  mark_count int := null;
  funding_count int := null;
  perp_liq_count int := null;
  margin_liq_count int := null;
  unbond_count int := null;
begin
  perform require_admin_permission('derivatives.write');
  if update_marks then mark_count := update_perp_mark(); end if;
  if apply_funding then funding_count := apply_perp_funding(); end if;
  if check_perps then perp_liq_count := check_perp_liquidations(); end if;
  if check_margin then margin_liq_count := check_margin_liquidations(); end if;
  if process_unbonds then unbond_count := process_unbonding(); end if;

  insert into admin_audit_log(action, target, detail)
    values ('RUN_DERIVATIVE_JOBS', 'derivatives',
            jsonb_build_object('update_marks', mark_count,
                               'apply_funding', funding_count,
                               'check_perps', perp_liq_count,
                               'check_margin', margin_liq_count,
                               'process_unbonds', unbond_count));

  return jsonb_build_object('update_marks', mark_count,
                            'apply_funding', funding_count,
                            'check_perps', perp_liq_count,
                            'check_margin', margin_liq_count,
                            'process_unbonds', unbond_count);
end $$;

-- Read-side RLS for operator tables and sensitive admin data.
alter table admin_role enable row level security;
alter table admin_permission enable row level security;
alter table admin_role_permission enable row level security;
alter table admin_operator_role enable row level security;
alter table admin_audit_log enable row level security;
alter table chain enable row level security;
alter table chain_asset enable row level security;

drop policy if exists admin_role_read on admin_role;
create policy admin_role_read on admin_role for select to authenticated
  using (admin_has_any_permission(array['rbac.read', 'rbac.write']));
drop policy if exists admin_permission_read on admin_permission;
create policy admin_permission_read on admin_permission for select to authenticated
  using (admin_has_any_permission(array['rbac.read', 'rbac.write']));
drop policy if exists admin_role_permission_read on admin_role_permission;
create policy admin_role_permission_read on admin_role_permission for select to authenticated
  using (admin_has_any_permission(array['rbac.read', 'rbac.write']));
drop policy if exists admin_operator_role_read on admin_operator_role;
create policy admin_operator_role_read on admin_operator_role for select to authenticated
  using (user_id = auth.uid() or admin_has_any_permission(array['rbac.read', 'rbac.write']));

drop policy if exists admin_audit_read on admin_audit_log;
create policy admin_audit_read on admin_audit_log for select to authenticated
  using (admin_has_permission('audit.read'));
drop policy if exists admin_wallet_read on wallet_request;
create policy admin_wallet_read on wallet_request for select to authenticated
  using (admin_has_any_permission(array['wallet.read', 'withdrawal.sign']));
drop policy if exists admin_app_entity_read on app_entity;
create policy admin_app_entity_read on app_entity for select to authenticated
  using (admin_has_any_permission(array['account.read', 'wallet.read', 'referral.read', 'security.read']));
drop policy if exists admin_referral_earning_read on referral_earning;
create policy admin_referral_earning_read on referral_earning for select to authenticated
  using (admin_has_permission('referral.read'));
drop policy if exists admin_chain_read on chain;
create policy admin_chain_read on chain for select to authenticated
  using (admin_has_permission('chain.read'));
drop policy if exists admin_chain_asset_read on chain_asset;
create policy admin_chain_asset_read on chain_asset for select to authenticated
  using (admin_has_permission('chain.read'));
drop policy if exists admin_chain_deposit_read on chain_deposit;
create policy admin_chain_deposit_read on chain_deposit for select to authenticated
  using (admin_has_permission('chain.read'));
drop policy if exists admin_perp_position_read on perp_position;
create policy admin_perp_position_read on perp_position for select to authenticated
  using (admin_has_permission('derivatives.read'));
drop policy if exists admin_margin_loan_read on margin_loan;
create policy admin_margin_loan_read on margin_loan for select to authenticated
  using (admin_has_permission('derivatives.read'));
drop policy if exists admin_api_key_read on api_key;
create policy admin_api_key_read on api_key for select to authenticated
  using (admin_has_permission('security.read'));

grant select on admin_role, admin_permission, admin_role_permission, admin_operator_role to authenticated;
grant select on reconciliation_report to authenticated, service_role;
grant select on admin_audit_log to authenticated;
grant select on wallet_request to authenticated;
grant select (id, pub_id, external_id, type, status, created_at) on app_entity to authenticated;
grant select on referral_earning to authenticated;
grant select on chain, chain_asset, chain_deposit to authenticated;
grant select on perp_position, margin_loan to authenticated;
revoke select on api_key from anon, authenticated;
grant select (app_entity_id, key_id, label, scopes, last_used_at, revoked_at, created_at) on api_key to authenticated;

revoke execute on function
  admin_has_permission(text),
  admin_has_any_permission(text[]),
  current_admin_permissions(),
  require_admin_permission(text),
  admin_actor_roles(),
  admin_grant_operator_role(uuid,text),
  admin_grant_operator_role_by_email(text,text),
  admin_revoke_operator_role(uuid,text),
  reconcile(),
  admin_suspend_entity(text,text),
  admin_unsuspend_entity(text),
  admin_set_fee(text,text,numeric,numeric,numeric),
  admin_set_instrument_risk(text,numeric,numeric,numeric),
  approve_wallet_request(text,text),
  reject_wallet_request(text,text),
  next_withdrawal_to_sign(),
  mark_withdrawal_broadcast(text,text),
  mark_withdrawal_confirmed(text),
  credit_chain_deposit(text,text,int,text,text,numeric,int),
  admin_set_chain_config(text,text,int,boolean),
  admin_set_chain_asset(text,text,text,int),
  admin_revoke_api_key(text),
  pay_referral_earnings(text,text),
  admin_set_stake_pool(text,numeric,int),
  admin_set_margin_terms(numeric,numeric,numeric),
  admin_set_perp_market(text,text,text,numeric,numeric,numeric,numeric),
  admin_run_derivative_jobs(boolean,boolean,boolean,boolean,boolean)
  from public, anon;

grant execute on function
  admin_has_permission(text),
  admin_has_any_permission(text[]),
  current_admin_permissions(),
  require_admin_permission(text),
  admin_actor_roles(),
  admin_grant_operator_role(uuid,text),
  admin_grant_operator_role_by_email(text,text),
  admin_revoke_operator_role(uuid,text),
  reconcile(),
  admin_suspend_entity(text,text),
  admin_unsuspend_entity(text),
  admin_set_fee(text,text,numeric,numeric,numeric),
  admin_set_instrument_risk(text,numeric,numeric,numeric),
  approve_wallet_request(text,text),
  reject_wallet_request(text,text),
  next_withdrawal_to_sign(),
  mark_withdrawal_broadcast(text,text),
  mark_withdrawal_confirmed(text),
  credit_chain_deposit(text,text,int,text,text,numeric,int),
  admin_set_chain_config(text,text,int,boolean),
  admin_set_chain_asset(text,text,text,int),
  admin_revoke_api_key(text),
  pay_referral_earnings(text,text),
  admin_set_stake_pool(text,numeric,int),
  admin_set_margin_terms(numeric,numeric,numeric),
  admin_set_perp_market(text,text,text,numeric,numeric,numeric,numeric),
  admin_run_derivative_jobs(boolean,boolean,boolean,boolean,boolean)
  to authenticated, service_role;

-- Chain-backed funding enforcement and custody reconciliation.
create or replace function request_deposit(
    currency_param text, amount_param numeric, idempotency_key_param text default null)
  returns text
  language plpgsql
  security definer
  set search_path = public, pg_temp
as $$
begin
  raise exception 'wallet_deposit_requests_disabled_use_wallet_chain_deposit';
end $$;

create or replace function approve_wallet_request(request_pub_param text, note_param text default null)
  returns text
  language plpgsql
  security definer
  set search_path = public, pg_temp
as $$
declare
  r   wallet_request%rowtype;
  pub text;
  tr  text;
begin
  perform require_admin_permission('wallet.approve');
  select * into r from wallet_request where pub_id = request_pub_param for update;
  if not found then raise exception 'request_not_found'; end if;
  if r.status <> 'PENDING' then raise exception 'request_not_pending: %', r.status; end if;
  select pub_id into pub from app_entity where id = r.app_entity_id;

  if r.direction = 'DEPOSIT' then
    update wallet_request
       set status = 'REJECTED',
           note = coalesce(note_param, 'Deposit requests are disabled; use chain_deposit crediting.'),
           resolved_at = current_timestamp
     where id = r.id;
    insert into admin_audit_log(action, target, detail)
      values ('REJECT_WALLET_DEPOSIT_REQUEST', request_pub_param,
              jsonb_build_object('reason', 'chain_deposit_required',
                                 'currency', r.currency,
                                 'amount', r.amount));
    return null;
  end if;

  update currency_account
    set amount_reserved = greatest(amount_reserved - r.amount, 0), updated_at = current_timestamp
    where app_entity_id = r.app_entity_id and currency_name = r.currency;
  tr := create_transfer('WITHDRAWAL', pub, r.amount, r.currency, 'MASTER',
                        'wallet:' || r.pub_id, 'wallet withdrawal');

  update wallet_request
    set status = 'APPROVED', transfer_pub_id = tr, note = note_param, resolved_at = current_timestamp
    where id = r.id;
  insert into admin_audit_log(action, target, detail)
    values ('APPROVE_WALLET_REQUEST', request_pub_param,
            jsonb_build_object('direction', r.direction,
                               'currency', r.currency,
                               'amount', r.amount));
  return tr;
end $$;

update wallet_request
   set status = 'REJECTED',
       note = coalesce(note, 'Deposit requests are disabled; use chain_deposit crediting.'),
       resolved_at = coalesce(resolved_at, current_timestamp)
 where direction = 'DEPOSIT'
   and status = 'PENDING';

create or replace function funding_reconciliation_report()
  returns table(
    entity_pub_id text,
    external_id text,
    currency text,
    source_kinds text,
    first_seen timestamptz,
    last_seen timestamptz,
    transfer_count bigint,
    unbacked_amount numeric,
    reversed_amount numeric,
    outstanding_amount numeric,
    available_cash numeric,
    blocked_amount numeric
  )
  language plpgsql
  security definer
  set search_path = public, pg_temp
as $$
begin
  perform require_admin_permission('recon.read');

  return query
    with customer_deposits as (
      select
        t.id as transfer_id,
        t.pub_id as transfer_pub_id,
        t.created_at,
        ca_to.app_entity_id as app_entity_id,
        to_ae.pub_id as entity_pub_id,
        to_ae.external_id,
        t.currency_name as currency,
        t.amount,
        coalesce(t.external_reference_number, '') as ref,
        coalesce(t.details, '') as details
      from transfer t
      join transfer_ledger_entry le_to
        on le_to.transfer_id = t.id and le_to.entry_type = 'CREDIT'
      join currency_account ca_to on ca_to.id = le_to.currency_account_id
      join app_entity to_ae on to_ae.id = ca_to.app_entity_id
      join transfer_ledger_entry le_from
        on le_from.transfer_id = t.id and le_from.entry_type = 'DEBIT'
      join currency_account ca_from on ca_from.id = le_from.currency_account_id
      join app_entity from_ae on from_ae.id = ca_from.app_entity_id
      where t.type = 'DEPOSIT'
        and from_ae.type = 'MASTER'
        and to_ae.type <> 'MASTER'
    ),
    classified as (
      select
        cd.*,
        case
          when chain_match.chain_deposit_id is not null then 'chain_deposit'
          when balance_match.ok is not null then 'chain_balance_delta'
          when cd.ref = 'referral' and cd.details = 'referral payout' then 'internal_referral'
          when cd.ref = 'staking' and cd.details in ('stake reward', 'unbond release') then 'internal_staking'
          when cd.ref = 'margin' and cd.details = 'borrow' then 'internal_margin'
          when cd.ref = 'perp' and cd.details = 'close payout' then 'internal_perp'
          when lower(cd.ref || ' ' || cd.details) ~ '(demo|faucet)' then 'legacy_demo_funds'
          when cd.ref like 'wallet:%' or cd.details = 'wallet deposit' then 'legacy_wallet_deposit'
          when cd.details like 'chain deposit%' then 'missing_chain_evidence'
          else 'manual_master_deposit'
        end as source_kind,
        case
          when chain_match.chain_deposit_id is not null or balance_match.ok is not null then 'CHAIN_BACKED'
          when (cd.ref = 'referral' and cd.details = 'referral payout')
            or (cd.ref = 'staking' and cd.details in ('stake reward', 'unbond release'))
            or (cd.ref = 'margin' and cd.details = 'borrow')
            or (cd.ref = 'perp' and cd.details = 'close payout')
          then 'INTERNAL_PROTOCOL'
          else 'UNBACKED'
        end as backing_status
      from customer_deposits cd
      left join lateral (
        select d.id as chain_deposit_id
        from chain_deposit d
        where d.credited_at is not null
          and d.currency = cd.currency
          and d.amount = cd.amount
          and cd.ref = d.chain || ':' || d.txid
          and (
            d.address = 'oc' || cd.app_entity_id::text
            or exists (
              select 1 from watched_address wa
              where wa.app_entity_id = cd.app_entity_id
                and wa.chain = d.chain
                and wa.address = d.address
            )
          )
        limit 1
      ) chain_match on true
      left join lateral (
        select 1 as ok
        from chain_balance_cursor cbc
        join watched_address wa
          on wa.chain = cbc.chain
         and wa.address = cbc.address
         and wa.app_entity_id = cd.app_entity_id
        where cd.details = 'chain deposit (balance delta)'
          and cd.ref = cbc.chain || ':' || cbc.address || ':' || split_part(cd.ref, ':', 3)
          and split_part(cd.ref, ':', 3) ~ '^[0-9]+(\.[0-9]+)?$'
          and cbc.credited_raw >= case
                when split_part(cd.ref, ':', 3) ~ '^[0-9]+(\.[0-9]+)?$'
                then split_part(cd.ref, ':', 3)::numeric
                else null
              end
        limit 1
      ) balance_match on true
    ),
    unbacked as (
      select *
      from classified
      where backing_status = 'UNBACKED'
    ),
    funding as (
      select
        u.app_entity_id,
        u.entity_pub_id,
        u.external_id,
        u.currency,
        string_agg(distinct u.source_kind, ', ' order by u.source_kind) as source_kinds,
        min(u.created_at) as first_seen,
        max(u.created_at) as last_seen,
        count(*)::bigint as transfer_count,
        sum(u.amount) as unbacked_amount
      from unbacked u
      group by u.app_entity_id, u.entity_pub_id, u.external_id, u.currency
    ),
    reversals as (
      select
        ca_from.app_entity_id,
        t.currency_name as currency,
        sum(t.amount) as reversed_amount
      from transfer t
      join transfer_ledger_entry le_from
        on le_from.transfer_id = t.id and le_from.entry_type = 'DEBIT'
      join currency_account ca_from on ca_from.id = le_from.currency_account_id
      join app_entity from_ae on from_ae.id = ca_from.app_entity_id
      join transfer_ledger_entry le_to
        on le_to.transfer_id = t.id and le_to.entry_type = 'CREDIT'
      join currency_account ca_to on ca_to.id = le_to.currency_account_id
      join app_entity to_ae on to_ae.id = ca_to.app_entity_id
      where t.type = 'WITHDRAWAL'
        and t.external_reference_number = 'funding_reconcile:unbacked'
        and from_ae.type <> 'MASTER'
        and to_ae.type = 'MASTER'
      group by ca_from.app_entity_id, t.currency_name
    ),
    exposure as (
      select
        f.*,
        coalesce(r.reversed_amount, 0) as reversed_amount,
        greatest(f.unbacked_amount - coalesce(r.reversed_amount, 0), 0) as outstanding_amount
      from funding f
      left join reversals r
        on r.app_entity_id = f.app_entity_id
       and r.currency = f.currency
    )
    select
      e.entity_pub_id,
      e.external_id,
      e.currency,
      e.source_kinds,
      e.first_seen,
      e.last_seen,
      e.transfer_count,
      e.unbacked_amount,
      e.reversed_amount,
      e.outstanding_amount,
      greatest(coalesce(ca.amount - ca.amount_reserved, 0), 0) as available_cash,
      greatest(e.outstanding_amount - greatest(coalesce(ca.amount - ca.amount_reserved, 0), 0), 0) as blocked_amount
    from exposure e
    left join currency_account ca
      on ca.app_entity_id = e.app_entity_id
     and ca.currency_name = e.currency
    where e.outstanding_amount > 0
    order by e.outstanding_amount desc, e.last_seen desc;
end $$;

create or replace function custody_reconcile()
  returns table(check_name text, failures bigint, status text)
  language plpgsql
  security definer
  set search_path = public, pg_temp
as $$
begin
  perform require_admin_permission('recon.read');

  return query
    select 'unbacked_customer_funding'::text,
           count(*)::bigint,
           case when count(*) = 0 then 'PASS' else 'FAIL' end::text
    from funding_reconciliation_report()

    union all
    select 'wallet_deposit_requests_disabled'::text,
           count(*)::bigint,
           case when count(*) = 0 then 'PASS' else 'FAIL' end::text
    from wallet_request wr
    where wr.direction = 'DEPOSIT'
      and wr.status in ('PENDING', 'APPROVED');
end $$;

create or replace view custody_reconciliation_report as select * from custody_reconcile();
create or replace view custody_funding_exposure as select * from funding_reconciliation_report();

create or replace function admin_reverse_unbacked_cash(
    dry_run_param boolean default true,
    entity_pub_param text default null)
  returns table(
    entity_pub_id text,
    external_id text,
    currency text,
    outstanding_amount numeric,
    available_cash numeric,
    reversed_amount numeric,
    reversal_transfer_pub_id text,
    dry_run boolean
  )
  language plpgsql
  security definer
  set search_path = public, pg_temp
as $$
declare
  r record;
  tr text;
begin
  perform require_admin_permission('recon.read');
  if not coalesce(dry_run_param, true) then
    perform require_admin_permission('wallet.approve');
  end if;

  for r in
    select
      fre.entity_pub_id,
      fre.external_id,
      fre.currency,
      fre.outstanding_amount,
      fre.available_cash,
      least(fre.outstanding_amount, fre.available_cash) as amount_to_reverse
    from funding_reconciliation_report() fre
    where (entity_pub_param is null or fre.entity_pub_id = entity_pub_param)
      and least(fre.outstanding_amount, fre.available_cash) > 0
    order by fre.outstanding_amount desc
  loop
    tr := null;
    if not coalesce(dry_run_param, true) then
      tr := process_transfer('WITHDRAWAL', r.entity_pub_id, r.amount_to_reverse, r.currency, 'MASTER',
                             'funding_reconcile:unbacked', 'remove unbacked funding', null);
      insert into admin_audit_log(action, target, detail)
        values ('REVERSE_UNBACKED_FUNDING', r.entity_pub_id,
                jsonb_build_object('currency', r.currency,
                                   'amount', r.amount_to_reverse,
                                   'transfer_pub_id', tr));
    end if;

    entity_pub_id := r.entity_pub_id;
    external_id := r.external_id;
    currency := r.currency;
    outstanding_amount := r.outstanding_amount;
    available_cash := r.available_cash;
    reversed_amount := r.amount_to_reverse;
    reversal_transfer_pub_id := tr;
    dry_run := coalesce(dry_run_param, true);
    return next;
  end loop;
end $$;

revoke execute on function
  request_deposit(text,numeric,text),
  approve_wallet_request(text,text),
  funding_reconciliation_report(),
  custody_reconcile(),
  admin_reverse_unbacked_cash(boolean,text)
  from public, anon;

grant execute on function
  request_deposit(text,numeric,text),
  approve_wallet_request(text,text),
  funding_reconciliation_report(),
  custody_reconcile(),
  admin_reverse_unbacked_cash(boolean,text)
  to authenticated, service_role;

grant select on custody_reconciliation_report, custody_funding_exposure
  to authenticated, service_role;
