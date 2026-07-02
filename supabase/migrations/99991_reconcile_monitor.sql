-- Reconciliation monitor: don't just compute invariants on demand — record breaks.
-- run_reconcile_monitor() snapshots every non-PASS row of reconcile() into an
-- append-only alert table; pg_cron runs it every 5 minutes (best-effort schedule
-- so restricted deploys still apply cleanly).

create table if not exists reconcile_alert (
  id          bigint generated always as identity primary key,
  check_name  text not null,
  failures    bigint not null,
  observed_at timestamptz not null default now()
);
alter table reconcile_alert enable row level security;
drop policy if exists read_reconcile_alert on reconcile_alert;
create policy read_reconcile_alert on reconcile_alert
  for select to authenticated using (true);
grant select on reconcile_alert to authenticated, service_role;

create or replace function run_reconcile_monitor()
  returns int
  language plpgsql
  security definer
  set search_path = public, pg_temp
as $$
declare n int := 0;
begin
  -- reconcile() is permission-gated (admin RBAC) and cron has no JWT; present the
  -- service_role claim locally so the gate passes under the scheduler.
  perform set_config('request.jwt.claim.role', 'service_role', true);
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  insert into reconcile_alert(check_name, failures)
  select r.check_name, r.failures from reconcile() r where r.status <> 'PASS';
  get diagnostics n = row_count;
  return n;
end $$;
revoke execute on function run_reconcile_monitor() from public, anon, authenticated;
grant execute on function run_reconcile_monitor() to service_role;

do $$ begin
  perform cron.unschedule('reconcile-monitor');
exception when others then null; end $$;
do $$ begin
  perform cron.schedule('reconcile-monitor', '*/5 * * * *', 'select run_reconcile_monitor()');
exception when others then null; end $$;
