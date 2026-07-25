-- Stage 1: expose the matching engine through PostgREST.
--
-- The engine functions are SECURITY INVOKER by default, so a PostgREST call as
-- the `anon` role would hit the tables with no privileges. For local
-- verification we run every engine function as SECURITY DEFINER (owner = the
-- migration role, which owns the tables) with a pinned search_path, and grant
-- EXECUTE to the API roles. RLS + per-user ownership is Stage 3, not this stage.

do $$
declare
  fn record;
begin
  for fn in
    select n.nspname, p.proname,
           pg_get_function_identity_arguments(p.oid) as args
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.prokind = 'f'
  loop
    execute format(
      'alter function %I.%I(%s) security definer set search_path = public, pg_temp',
      fn.nspname, fn.proname, fn.args);
    execute format(
      'grant execute on function %I.%I(%s) to anon, authenticated',
      fn.nspname, fn.proname, fn.args);
  end loop;
end $$;
