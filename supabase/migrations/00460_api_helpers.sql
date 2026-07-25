-- Stage 1: read access + small convenience RPCs so the whole flow is
-- drivable through PostgREST. RLS / per-user scoping is Stage 3.

grant usage on schema public to anon, authenticated;
grant select on all tables in schema public to anon, authenticated;
alter default privileges in schema public
  grant select on tables to anon, authenticated;

-- Resolve an external client id to its instrument-account pub_id (the handle
-- process_trade_order expects). SECURITY DEFINER so it can read the tables.
create or replace function find_instrument_account(external_id_param text)
  returns text
  language sql
  security definer
  set search_path = public, pg_temp
as $$
  select ia.pub_id
  from instrument_account ia
  join app_entity ae on ae.id = ia.app_entity_id
  where ae.external_id = external_id_param
  limit 1;
$$;

grant execute on function find_instrument_account(text) to anon, authenticated;
