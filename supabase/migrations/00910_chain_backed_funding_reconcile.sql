-- Remote backfill for chain-backed funding enforcement.
-- In a clean local reset this file sorts before the 9xxx migrations, so it skips.
do $remote_migration$
begin
  if to_regclass('public.wallet_request') is null
     or to_regprocedure('public.require_admin_permission(text)') is null then
    raise notice 'chain-backed funding backfill skipped until base migrations exist';
    return;
  end if;
  execute $chain_backed_sql$
-- Chain-backed funding enforcement and custody reconciliation.
--
-- Customer funding must come from a chain watcher / credited chain_deposit row.
-- Legacy wallet-deposit approvals and demo/manual MASTER -> customer credits are
-- reported as unbacked funding exposure and can be reversed with an append-only
-- withdrawal back to MASTER.

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

insert into admin_audit_log(action, target, detail)
select 'REJECT_LEGACY_PENDING_DEPOSIT_REQUESTS',
       'wallet_request',
       jsonb_build_object('count', count(*))
from wallet_request
where direction = 'DEPOSIT'
  and status = 'REJECTED'
  and resolved_at >= current_timestamp - interval '5 minutes'
having count(*) > 0;

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

do $$
begin
  perform set_config('request.jwt.claim.role', 'service_role', true);
  perform admin_reverse_unbacked_cash(false, null);
exception when others then
  raise warning 'auto_reverse_unbacked_cash skipped: %', sqlerrm;
end $$;
$chain_backed_sql$;
end
$remote_migration$;
