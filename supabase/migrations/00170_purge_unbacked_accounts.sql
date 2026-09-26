-- Clean up accounts that were funded only with unbacked money.
--
-- admin_reverse_unbacked_cash can only claw back what is still sitting in the
-- currency that was minted. On the demo most of it had already been traded away
-- (the counterparties were the house demo makers, whose float 00140 returned to
-- MASTER), so the funding report kept 19 rows "outstanding" forever and
-- custody_reconcile stayed FAIL with nothing left to reverse.
--
-- admin_purge_unbacked_account(entity) handles an account whose every deposit is
-- unbacked: cancel its orders, reverse every remaining balance to MASTER (tagged
-- funding_reconcile:unbacked, like the existing reversal), and record what had
-- already left as a write-off, which the report now counts. It refuses any
-- account with a backed or internal-protocol deposit — those need a person.

create table if not exists funding_writeoff (
  id            bigint generated always as identity primary key,
  app_entity_id bigint  not null references app_entity(id),
  currency      text    not null references currency(name),
  amount        numeric not null check (amount > 0),
  note          text    not null,
  created_at    timestamptz not null default now()
);
alter table funding_writeoff enable row level security;
revoke all on funding_writeoff from public, anon, authenticated;

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
      union all
      -- unbacked money that already left the account (traded away) and was
      -- written off by admin_purge_unbacked_account
      select w.app_entity_id, w.currency, w.amount from funding_writeoff w
    ),
    exposure as (
      select
        f.*,
        coalesce(r.reversed_amount, 0) as reversed_amount,
        greatest(f.unbacked_amount - coalesce(r.reversed_amount, 0), 0) as outstanding_amount
      from funding f
      left join (select rv.app_entity_id, rv.currency, sum(rv.reversed_amount) as reversed_amount
                   from reversals rv group by rv.app_entity_id, rv.currency) r
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

create or replace function admin_purge_unbacked_account(entity_pub_param text, note_param text)
  returns jsonb
  language plpgsql security definer set search_path = public, pg_temp as $$
declare
  ent app_entity%rowtype; r record;
  reversed jsonb := '{}'; written jsonb := '{}';
begin
  perform require_admin_permission('wallet.approve');
  if coalesce(trim(note_param), '') = '' then raise exception 'note_required'; end if;
  select * into ent from app_entity where pub_id = entity_pub_param;
  if not found then raise exception 'entity_not_found: %', entity_pub_param; end if;
  if ent.type = 'MASTER' then raise exception 'master_entity_not_purgeable'; end if;

  if not exists (select 1 from funding_reconciliation_report() where entity_pub_id = ent.pub_id) then
    raise exception 'no_outstanding_unbacked_funding: %', ent.pub_id;
  end if;
  -- only accounts with no real money in them: any credited chain deposit (address or
  -- memo), balance-delta credit or internal payout means a person has to look at it
  if exists (select 1 from chain_deposit d
              where d.credited_at is not null
                and (d.address = 'oc' || ent.id::text
                     or exists (select 1 from watched_address wa
                                 where wa.app_entity_id = ent.id and wa.chain = d.chain and wa.address = d.address)))
     or exists (select 1 from chain_balance_cursor c join watched_address wa
                  on wa.chain = c.chain and wa.address = c.address
               where wa.app_entity_id = ent.id and c.credited_raw > 0)
     or exists (select 1 from transfer t
                  join transfer_ledger_entry le on le.transfer_id = t.id and le.entry_type = 'CREDIT'
                  join currency_account ca on ca.id = le.currency_account_id
                 where ca.app_entity_id = ent.id and t.type = 'DEPOSIT'
                   and t.external_reference_number in ('referral','staking','margin','perp')) then
    raise exception 'entity_has_backed_funding: review manually';
  end if;
  if exists (select 1 from wallet_request where app_entity_id = ent.id and status = 'PENDING') then
    raise exception 'pending_wallet_requests: resolve them first';
  end if;

  -- release reservations held by resting orders (also on delisted pairs)
  for r in
    select o.pub_id from trade_order o join instrument_account ia on ia.id = o.instrument_account_id
     where ia.app_entity_id = ent.id and o.status in ('OPEN','PARTIALLY_FILLED')
  loop
    perform submit_cancel(r.pub_id);
  end loop;
  if exists (select 1 from currency_account where app_entity_id = ent.id and amount_reserved > 0) then
    raise exception 'reservations_remain_after_cancel: review manually';
  end if;

  -- claw back everything the account still holds
  for r in select currency_name, amount from currency_account where app_entity_id = ent.id and amount > 0 loop
    perform process_transfer('WITHDRAWAL', ent.pub_id, r.amount, r.currency_name, 'MASTER',
                             'funding_reconcile:unbacked', 'remove unbacked funding', null);
    reversed := reversed || jsonb_build_object(r.currency_name, r.amount);
  end loop;

  -- whatever is still outstanding already left through trades: write it off
  for r in select currency, outstanding_amount from funding_reconciliation_report()
            where entity_pub_id = ent.pub_id loop
    insert into funding_writeoff(app_entity_id, currency, amount, note)
      values (ent.id, r.currency, r.outstanding_amount, note_param);
    written := written || jsonb_build_object(r.currency, r.outstanding_amount);
  end loop;

  insert into admin_audit_log(action, target, detail)
    values ('PURGE_UNBACKED_ACCOUNT', ent.pub_id,
            jsonb_build_object('note', note_param, 'reversed', reversed, 'written_off', written));
  return jsonb_build_object('entity', ent.pub_id, 'reversed', reversed, 'written_off', written);
end $$;

revoke execute on function admin_purge_unbacked_account(text,text) from public, anon;
grant execute on function admin_purge_unbacked_account(text,text) to authenticated, service_role;

-- The retired demo makers (house, type MASTER) were left holding reservations with
-- no order behind them. Release them and return the rest of the float.
do $$
declare r record;
begin
  if exists (select 1 from trade_order o join instrument_account ia on ia.id = o.instrument_account_id
             join app_entity e on e.id = ia.app_entity_id
             where e.pub_id in ('DEMO_MM_A','DEMO_MM_B') and o.status in ('OPEN','PARTIALLY_FILLED')) then
    raise exception 'demo makers still have open orders';
  end if;
  update currency_account ca set amount_reserved = 0
    from app_entity e where e.id = ca.app_entity_id and e.pub_id in ('DEMO_MM_A','DEMO_MM_B')
     and ca.amount_reserved > 0;
  for r in
    select e.pub_id, ca.currency_name, ca.amount from currency_account ca
    join app_entity e on e.id = ca.app_entity_id
    where e.pub_id in ('DEMO_MM_A','DEMO_MM_B') and ca.amount > 0
  loop
    perform process_transfer('WITHDRAWAL', r.pub_id, r.amount, r.currency_name, 'MASTER',
                             'demo maker retired', 'return house float', null);
  end loop;
end $$;
