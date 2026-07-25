-- Stage 3/4 hardening: deny-by-default on the function surface.
--
-- 9000 made every engine function SECURITY DEFINER and granted EXECUTE to
-- anon/authenticated — including internal helpers (create_trade,
-- update_price_level, create_book_order, ...) that, if called directly, would
-- let a client forge trades or balances. Revoke EXECUTE on ALL public functions
-- from anon+authenticated, then re-grant ONLY the intended public API.
-- service_role retains its grants (admin/back-office plane).

-- Function creation also grants EXECUTE to PUBLIC, so revoke from PUBLIC (not just
-- the named roles). service_role is the trusted admin/back-office plane and keeps
-- EXECUTE on everything.
do $$
declare fn record;
begin
  for fn in
    select p.proname, pg_get_function_identity_arguments(p.oid) as args
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.prokind = 'f'
  loop
    execute format('revoke execute on function public.%I(%s) from public, anon, authenticated',
                   fn.proname, fn.args);
    execute format('grant execute on function public.%I(%s) to service_role',
                   fn.proname, fn.args);
  end loop;
end $$;

-- Authenticated end-user API (self-scoped). current_app_entity_id is also invoked
-- inside RLS policies as the caller, so it MUST stay executable by authenticated.
grant execute on function
  place_order(text,order_side,text,numeric,numeric,text),
  cancel_order(text),
  current_app_entity_id(),
  current_app_entity_pub(),
  request_withdrawal(text,numeric,text),
  request_deposit(text,numeric,text)
  to authenticated;

-- anon (unauthenticated) gets no RPCs; it can still read public market data
-- (price_level / trade / instrument / currency) via table SELECT grants.
