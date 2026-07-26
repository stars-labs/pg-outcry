-- Operational alerting: make a broken invariant reach a human.
--
-- 00070 records invariant breaks into reconcile_alert, but a row in a table
-- nobody watches is not an alert. This adds an outbound webhook (Slack, PagerDuty,
-- Discord, anything that accepts a JSON POST) fired by the same 5-minute monitor.
--
-- Configure with:
--   select ops_set_alert_webhook('https://hooks.slack.com/services/…');
-- Disable by setting it to null. With no URL configured this is inert — the
-- monitor still records alerts, it just doesn't call out.

create table if not exists ops_alert_config (
  id          boolean primary key default true check (id),
  webhook_url text,
  min_seconds int not null default 900,   -- don't re-page for the same check more often than this
  updated_at  timestamptz not null default now()
);
insert into ops_alert_config default values on conflict do nothing;

-- config may contain a secret URL: operators read it through the RPC, not the table
alter table ops_alert_config enable row level security;
revoke all on ops_alert_config from anon, authenticated;

alter table reconcile_alert add column if not exists notified_at timestamptz;

create or replace function ops_set_alert_webhook(url_param text)
  returns boolean
  language plpgsql
  security definer
  set search_path = public, pg_temp
as $$
begin
  perform require_admin_permission('rbac.write');
  update ops_alert_config set webhook_url = url_param, updated_at = now() where id;
  insert into admin_audit_log(action, target, detail)
    values ('SET_ALERT_WEBHOOK', 'ops_alert_config',
            jsonb_build_object('configured', url_param is not null));
  return url_param is not null;
end $$;

-- Post one message per un-notified alert, rate-limited per check_name.
create or replace function ops_notify_alerts()
  returns int
  language plpgsql
  security definer
  set search_path = public, extensions, pg_temp
as $$
declare
  cfg   ops_alert_config%rowtype;
  r     record;
  sent  int := 0;
begin
  select * into cfg from ops_alert_config where id;
  if cfg.webhook_url is null then
    return 0;                       -- inert until an operator configures it
  end if;

  for r in
    select a.*
    from reconcile_alert a
    where a.notified_at is null
      and not exists (              -- rate-limit: same check paged recently
        select 1 from reconcile_alert b
        where b.check_name = a.check_name
          and b.notified_at is not null
          and b.notified_at > now() - make_interval(secs => cfg.min_seconds))
    order by a.observed_at
  loop
    begin
      perform extensions.http_post(
        cfg.webhook_url,
        jsonb_build_object('text', format(
          '🚨 pg-outcry reconciliation FAILED: %s (%s failing rows) at %s',
          r.check_name, r.failures, r.observed_at))::text,
        'application/json');
      update reconcile_alert set notified_at = now() where id = r.id;
      sent := sent + 1;
    exception when others then
      raise warning 'ops_notify_alerts: webhook post failed: %', sqlerrm;
      exit;                         -- back off; the next tick retries
    end;
  end loop;
  return sent;
end $$;

-- Fold notification into the existing monitor so there is one scheduled job.
create or replace function run_reconcile_monitor()
  returns int
  language plpgsql
  security definer
  set search_path = public, pg_temp
as $$
declare n int := 0;
begin
  perform set_config('request.jwt.claim.role', 'service_role', true);
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  insert into reconcile_alert(check_name, failures)
  select r.check_name, r.failures from reconcile() r where r.status <> 'PASS';
  get diagnostics n = row_count;
  begin
    perform ops_notify_alerts();
  exception when others then
    raise warning 'reconcile monitor: notify step failed: %', sqlerrm;
  end;
  return n;
end $$;

revoke execute on function ops_set_alert_webhook(text), ops_notify_alerts() from public, anon;
grant  execute on function ops_set_alert_webhook(text) to authenticated, service_role;
grant  execute on function ops_notify_alerts() to service_role;

comment on function ops_notify_alerts() is
  'POSTs un-notified reconcile_alert rows to the configured webhook, rate-limited per check.';
