-- Stage 3 (part 2): back-office / admin plane.
-- Account suspension, fee + risk management, and an audit log. Admin RPCs run as
-- service_role (the back-office app authenticates separately and uses that key).

alter table app_entity
  add column status text not null default 'ACTIVE' check (status in ('ACTIVE','SUSPENDED'));

create table admin_audit_log (
  id         bigserial primary key,
  action     text not null,
  target     text,
  detail     jsonb,
  created_at timestamptz not null default current_timestamp
);

create or replace function assert_entity_active(eid bigint)
  returns void
  language plpgsql security definer set search_path = public, pg_temp
as $$
declare st text;
begin
  select status into st from app_entity where id = eid;
  if st is null then raise exception 'entity_not_found'; end if;
  if st <> 'ACTIVE' then raise exception 'account_suspended'; end if;
end $$;

-- ── admin RPCs (service_role) ────────────────────────────────────────────────
create or replace function admin_suspend_entity(entity_pub text, reason text default null)
  returns void language plpgsql security definer set search_path = public, pg_temp
as $$
begin
  update app_entity set status = 'SUSPENDED', updated_at = current_timestamp where pub_id = entity_pub;
  if not found then raise exception 'entity_not_found'; end if;
  insert into admin_audit_log(action, target, detail)
    values ('SUSPEND_ENTITY', entity_pub, jsonb_build_object('reason', reason));
end $$;

create or replace function admin_unsuspend_entity(entity_pub text)
  returns void language plpgsql security definer set search_path = public, pg_temp
as $$
begin
  update app_entity set status = 'ACTIVE', updated_at = current_timestamp where pub_id = entity_pub;
  if not found then raise exception 'entity_not_found'; end if;
  insert into admin_audit_log(action, target, detail) values ('UNSUSPEND_ENTITY', entity_pub, '{}'::jsonb);
end $$;

create or replace function admin_set_fee(
    fee_type text, currency_param text, percentage_param numeric,
    min_param numeric default null, max_param numeric default null)
  returns void language plpgsql security definer set search_path = public, pg_temp
as $$
begin
  perform 1 from currency where name = currency_param;
  if not found then raise exception 'unknown_currency: %', currency_param; end if;
  delete from fee where type = fee_type and currency_name = currency_param;
  insert into fee(type, currency_name, percentage, min, max)
    values (fee_type, currency_param, percentage_param, min_param, max_param);
  insert into admin_audit_log(action, target, detail)
    values ('SET_FEE', fee_type, jsonb_build_object(
      'currency', currency_param, 'percentage', percentage_param, 'min', min_param, 'max', max_param));
end $$;

create or replace function admin_set_instrument_risk(
    instrument_name_param text, max_amount numeric, max_notional numeric, band_pct numeric)
  returns void language plpgsql security definer set search_path = public, pg_temp
as $$
declare iid bigint;
begin
  select id into iid from instrument where name = instrument_name_param;
  if iid is null then raise exception 'instrument_not_found'; end if;
  insert into instrument_risk(instrument_id, max_order_amount, max_order_notional, price_band_pct)
    values (iid, max_amount, max_notional, band_pct)
  on conflict (instrument_id) do update
    set max_order_amount = excluded.max_order_amount,
        max_order_notional = excluded.max_order_notional,
        price_band_pct = excluded.price_band_pct,
        updated_at = current_timestamp;
  insert into admin_audit_log(action, target, detail)
    values ('SET_RISK', instrument_name_param, jsonb_build_object(
      'max_order_amount', max_amount, 'max_order_notional', max_notional, 'price_band_pct', band_pct));
end $$;

-- ── enforce account status on the user paths ─────────────────────────────────
create or replace function place_order(
    instrument_name_param text, side_param order_side, order_type_param text,
    price_param numeric, amount_param numeric, time_in_force_param text)
  returns text language plpgsql security definer set search_path = public, pg_temp
as $$
declare
  eid bigint := current_app_entity_id();
  ia  text;
  iid bigint;
begin
  if eid is null then raise exception 'not_authenticated'; end if;
  perform assert_entity_active(eid);
  select ia2.pub_id into ia from instrument_account ia2 where ia2.app_entity_id = eid limit 1;
  if ia is null then raise exception 'no_account'; end if;
  select id into iid from instrument where name = instrument_name_param;
  if iid is null then raise exception 'instrument_not_found: %', instrument_name_param; end if;
  perform check_order_risk(iid, side_param, price_param, amount_param);
  perform pg_advisory_xact_lock(iid);
  return process_trade_order(ia, instrument_name_param, order_type_param,
    side_param, price_param, amount_param, time_in_force_param, 0);
end $$;

create or replace function request_withdrawal(currency_param text, amount_param numeric)
  returns text language plpgsql security definer set search_path = public, pg_temp
as $$
declare
  eid bigint := current_app_entity_id();
  ca  currency_account%rowtype;
  req text;
begin
  if eid is null then raise exception 'not_authenticated'; end if;
  perform assert_entity_active(eid);
  if amount_param <= 0 then raise exception 'amount_must_be_positive'; end if;
  select * into ca from currency_account where app_entity_id = eid and currency_name = currency_param;
  if not found then raise exception 'no_currency_account: %', currency_param; end if;
  if ca.amount - ca.amount_reserved < amount_param then
    raise exception 'insufficient_available_balance: available %, requested %',
      ca.amount - ca.amount_reserved, amount_param;
  end if;
  update currency_account
    set amount_reserved = amount_reserved + amount_param, updated_at = current_timestamp
    where id = ca.id;
  insert into wallet_request(app_entity_id, direction, currency, amount)
    values (eid, 'WITHDRAWAL', currency_param, amount_param) returning pub_id into req;
  return req;
end $$;
