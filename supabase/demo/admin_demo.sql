-- DEMO ONLY — not part of the product migrations. Exposes a READ-ONLY snapshot
-- of the back-office (reconciliation, pending approvals, accounts, fees, risk,
-- audit) so the admin console can run as a public live demo with just the anon
-- key — without ever shipping the service_role key to a browser.
--
-- This deliberately surfaces aggregate operator data to anon. That is acceptable
-- ONLY for a throwaway demo with disposable accounts. Do NOT apply to a real
-- deployment. Apply manually: psql "$DB_URL" -f supabase/demo/admin_demo.sql

create or replace function demo_admin_overview()
  returns jsonb
  language sql
  security definer
  set search_path = public, pg_temp
as $$
  select jsonb_build_object(
    'recon', coalesce((
      select jsonb_agg(jsonb_build_object(
        'check_name', check_name, 'failures', failures, 'status', status))
      from reconciliation_report), '[]'::jsonb),
    'approvals', coalesce((
      select jsonb_agg(jsonb_build_object(
        'direction', w.direction, 'currency', w.currency, 'amount', w.amount,
        'created_at', w.created_at, 'external_id', ae.external_id) order by w.created_at)
      from wallet_request w
      left join app_entity ae on ae.id = w.app_entity_id
      where w.status = 'PENDING'), '[]'::jsonb),
    'accounts', coalesce((
      select jsonb_agg(jsonb_build_object(
        'external_id', external_id, 'type', type, 'status', status) order by created_at desc)
      from app_entity), '[]'::jsonb),
    'fees', coalesce((
      select jsonb_agg(jsonb_build_object(
        'type', type, 'currency_name', currency_name, 'percentage', percentage,
        'min', min, 'max', max))
      from fee), '[]'::jsonb),
    'risk', coalesce((
      select jsonb_agg(jsonb_build_object(
        'instrument', i.name, 'max_order_amount', r.max_order_amount,
        'max_order_notional', r.max_order_notional, 'price_band_pct', r.price_band_pct))
      from instrument_risk r left join instrument i on i.id = r.instrument_id), '[]'::jsonb),
    'audit', coalesce((
      select jsonb_agg(t order by t.created_at desc) from (
        select action, target, detail, created_at
        from admin_audit_log order by created_at desc limit 40) t), '[]'::jsonb)
  );
$$;

revoke execute on function demo_admin_overview() from public;
grant execute on function demo_admin_overview() to anon, authenticated;
