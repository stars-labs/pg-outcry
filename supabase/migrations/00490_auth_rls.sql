-- Stage 3: Supabase Auth (GoTrue) identity + Row Level Security.
--
-- Model chosen: "register == open account". A GoTrue signup auto-provisions an
-- app_entity (via create_client) and links it to auth.users. Authenticated users
-- trade through place_order/cancel_order (which resolve their own account from
-- auth.uid()); they can only ever read their own accounts/orders/balances.
-- Funding + raw engine entry points become admin-only (service_role).

-- ── identity link ──────────────────────────────────────────────────────────
create table app_user (
  user_id       uuid primary key references auth.users(id) on delete cascade,
  app_entity_id bigint not null references app_entity(id),
  created_at    timestamptz not null default current_timestamp
);

-- On signup: create the trading entity and link it to the auth user.
create or replace function handle_new_user()
  returns trigger
  language plpgsql
  security definer
  set search_path = public, auth, pg_temp
as $$
declare
  pub text;
  eid bigint;
begin
  pub := create_client(new.id::text);                 -- external_id = auth uid
  select id into eid from app_entity where pub_id = pub;
  insert into app_user(user_id, app_entity_id) values (new.id, eid);
  return new;
end $$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function handle_new_user();

-- ── current-user helpers (definer: bypass RLS to resolve identity) ───────────
create or replace function current_app_entity_id()
  returns bigint
  language sql
  stable
  security definer
  set search_path = public, pg_temp
as $$ select app_entity_id from app_user where user_id = auth.uid() $$;

create or replace function current_app_entity_pub()
  returns text
  language sql
  stable
  security definer
  set search_path = public, pg_temp
as $$
  select ae.pub_id from app_entity ae
  join app_user au on au.app_entity_id = ae.id
  where au.user_id = auth.uid()
$$;

-- ── authenticated trading API (resolves caller's own account) ────────────────
create or replace function place_order(
    instrument_name_param text,
    side_param            order_side,
    order_type_param      text,
    price_param           numeric,
    amount_param          numeric,
    time_in_force_param   text
  )
  returns text
  language plpgsql
  security definer
  set search_path = public, pg_temp
as $$
declare
  ia  text;
  iid bigint;
begin
  select ia2.pub_id into ia
  from instrument_account ia2
  where ia2.app_entity_id = current_app_entity_id()
  limit 1;
  if ia is null then raise exception 'not_authenticated_or_no_account'; end if;

  select id into iid from instrument where name = instrument_name_param;
  if iid is null then raise exception 'instrument_not_found: %', instrument_name_param; end if;

  perform pg_advisory_xact_lock(iid);                 -- per-instrument serialization
  return process_trade_order(ia, instrument_name_param, order_type_param,
    side_param, price_param, amount_param, time_in_force_param, 0);
end $$;

create or replace function cancel_order(trade_order_id_param text)
  returns void
  language plpgsql
  security definer
  set search_path = public, pg_temp
as $$
declare
  iid   bigint;
  owner bigint;
begin
  select o.instrument_id, ia.app_entity_id into iid, owner
  from trade_order o
  join instrument_account ia on ia.id = o.instrument_account_id
  where o.pub_id = trade_order_id_param;
  if iid is null then raise exception 'trade_order_not_found'; end if;
  if owner is distinct from current_app_entity_id() then
    raise exception 'not_owner';
  end if;
  perform pg_advisory_xact_lock(iid);
  perform cancel_trade_order(trade_order_id_param);
end $$;

-- ── privilege tightening ─────────────────────────────────────────────────────
-- Authenticated users only get the self-scoped API. Funding + raw engine entry
-- points (which take an arbitrary account) are admin-only via service_role.
-- NB: functions carry an implicit EXECUTE-to-PUBLIC grant, so we must revoke
-- from PUBLIC (not just anon/authenticated) and re-grant to service_role.
-- The SECURITY DEFINER wrappers (place_order, handle_new_user) still call these
-- internally because they execute as their owner (postgres), not the caller.
revoke execute on function
  process_transfer(transfer_type,text,numeric,text,text,text,text,text),
  process_trade_order(text,text,text,order_side,numeric,numeric,text,bigint),
  submit_order(text,text,text,order_side,numeric,numeric,text),
  submit_cancel(text),
  cancel_trade_order(text),
  create_client(text),
  create_currency_account(text,text),
  create_transfer(transfer_type,text,numeric,text,text,text,text),
  create_instrument_account_transfer(text,text,instrument,integer),
  find_instrument_account(text)
  from public, anon, authenticated;

grant execute on function
  process_transfer(transfer_type,text,numeric,text,text,text,text,text),
  create_client(text),
  create_currency_account(text,text),
  create_transfer(transfer_type,text,numeric,text,text,text,text),
  create_instrument_account_transfer(text,text,instrument,integer),
  find_instrument_account(text)
  to service_role;

revoke execute on function
  place_order(text,order_side,text,numeric,numeric,text),
  cancel_order(text)
  from public;

grant execute on function
  place_order(text,order_side,text,numeric,numeric,text),
  cancel_order(text),
  current_app_entity_id(),
  current_app_entity_pub()
  to authenticated, service_role;

-- ── RLS: owner-scoped tables ─────────────────────────────────────────────────
alter table app_entity                 enable row level security;
alter table app_user                   enable row level security;
alter table currency_account           enable row level security;
alter table instrument_account         enable row level security;
alter table instrument_account_holding enable row level security;
alter table trade_order                enable row level security;

create policy own_app_entity on app_entity
  for select to authenticated using (id = current_app_entity_id());
create policy own_app_user on app_user
  for select to authenticated using (user_id = auth.uid());
create policy own_currency_account on currency_account
  for select to authenticated using (app_entity_id = current_app_entity_id());
create policy own_instrument_account on instrument_account
  for select to authenticated using (app_entity_id = current_app_entity_id());
create policy own_holding on instrument_account_holding
  for select to authenticated using (
    instrument_account in (select id from instrument_account where app_entity_id = current_app_entity_id()));
create policy own_orders on trade_order
  for select to authenticated using (
    instrument_account_id in (select id from instrument_account where app_entity_id = current_app_entity_id()));

-- ── RLS: default-deny back-office tables (service_role bypasses) ──────────────
alter table transfer                       enable row level security;
alter table transfer_ledger_entry          enable row level security;
alter table instrument_account_transfer    enable row level security;
alter table instrument_account_ledger_entry enable row level security;
alter table stop_order                     enable row level security;
alter table book_order                     enable row level security;

-- price_level, trade, instrument, currency, fee stay public (market/reference data).

-- ── views read with the caller's privileges so RLS applies ───────────────────
alter view open_orders         set (security_invoker = on);
alter view cash_balances       set (security_invoker = on);
alter view instrument_balances set (security_invoker = on);
alter view order_book_l2       set (security_invoker = on);
alter view trade_history       set (security_invoker = on);
