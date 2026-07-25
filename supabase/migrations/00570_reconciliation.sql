-- Stage 4 (hardening): append-only ledger + reconciliation report.
--
-- The double-entry ledger entry tables are immutable: the engine only INSERTs
-- DEBIT/CREDIT rows, never updates/deletes them. Enforce that so balances can
-- always be re-derived and audited.

create or replace function forbid_ledger_mutation()
  returns trigger language plpgsql as $$
begin
  raise exception 'append_only_ledger: % on % is not allowed', tg_op, tg_table_name;
end $$;

create trigger transfer_ledger_append_only
  before update or delete on transfer_ledger_entry
  for each row execute function forbid_ledger_mutation();
create trigger iae_ledger_append_only
  before update or delete on instrument_account_ledger_entry
  for each row execute function forbid_ledger_mutation();

-- ── reconciliation report ────────────────────────────────────────────────────
-- Each row is one invariant; failures = 0 means healthy. Admin-only (service_role).

create or replace function reconcile()
  returns table(check_name text, failures bigint, status text)
  language sql security definer set search_path = public, pg_temp
as $$
  -- 1) per-customer cash balance == sum(CREDIT) - sum(DEBIT) of its ledger
  select 'cash_balance_matches_ledger', count(*),
         case when count(*) = 0 then 'PASS' else 'FAIL' end
  from (
    select ca.id
    from currency_account ca
    join app_entity ae on ae.id = ca.app_entity_id and ae.type <> 'MASTER'
    left join transfer_ledger_entry le on le.currency_account_id = ca.id
    group by ca.id, ca.amount
    having ca.amount <> coalesce(sum(case when le.entry_type = 'CREDIT' then le.amount else -le.amount end), 0)
  ) bad

  union all
  -- 2) every transfer is balanced: total debits == total credits
  select 'transfer_double_entry_balanced', count(*),
         case when count(*) = 0 then 'PASS' else 'FAIL' end
  from (
    select transfer_id
    from transfer_ledger_entry
    group by transfer_id
    having sum(case when entry_type = 'DEBIT' then amount else 0 end)
         <> sum(case when entry_type = 'CREDIT' then amount else 0 end)
  ) bad

  union all
  -- 3) reservations sane: covers pending withdrawals, never exceeds balance, available >= 0
  select 'reservations_consistent', count(*),
         case when count(*) = 0 then 'PASS' else 'FAIL' end
  from currency_account ca
  left join (
    select app_entity_id, currency, sum(amount) amt
    from wallet_request where status = 'PENDING' and direction = 'WITHDRAWAL'
    group by app_entity_id, currency
  ) p on p.app_entity_id = ca.app_entity_id and p.currency = ca.currency_name
  join app_entity ae on ae.id = ca.app_entity_id and ae.type <> 'MASTER'
  where ca.amount_reserved < coalesce(p.amt, 0)
     or ca.amount_reserved > ca.amount
     or ca.amount < 0

  union all
  -- 4) every APPROVED wallet request points at a real settlement transfer
  select 'approved_wallet_has_transfer', count(*),
         case when count(*) = 0 then 'PASS' else 'FAIL' end
  from wallet_request w
  where w.status = 'APPROVED'
    and (w.transfer_pub_id is null or not exists (select 1 from transfer t where t.pub_id = w.transfer_pub_id))

  union all
  -- 5) issuance: per currency, total customer balances == MASTER net outflow
  select 'issuance_conserved', count(*),
         case when count(*) = 0 then 'PASS' else 'FAIL' end
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
$$;

create or replace view reconciliation_report as select * from reconcile();

grant execute on function reconcile() to service_role;
grant select on reconciliation_report to service_role;
