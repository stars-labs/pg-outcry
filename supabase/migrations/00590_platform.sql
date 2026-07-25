-- Stage 2 (platform): give the API roles headroom for the matching loop.
-- process_trade_order can sweep many resting orders in one call; the default
-- per-statement timeout can be too tight under depth. Concurrency correctness is
-- handled by per-instrument advisory locks (not SERIALIZABLE), so there is no
-- serialization_failure to retry — same-instrument calls simply queue on the lock.

-- Best-effort: on hosted Supabase the migration role may not own these roles.
-- (On hosted you can also set these per-role in the dashboard.)
do $$
begin
  alter role authenticated set statement_timeout = '15s';
  alter role anon          set statement_timeout = '10s';
  alter role service_role  set statement_timeout = '30s';   -- back-office / batch
exception when insufficient_privilege then
  raise notice 'statement_timeout per-role skipped (no privilege on hosted) — set in dashboard';
end $$;
