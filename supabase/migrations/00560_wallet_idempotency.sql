-- Stage 4 (hardening): idempotency keys for wallet requests.
-- A client retry (double-click, network retry) with the same key returns the
-- SAME request instead of creating a duplicate / double-reserving funds.
-- Unique on (app_entity_id, idempotency_key); NULL keys stay independent.

alter table wallet_request add column idempotency_key text;
create unique index wallet_request_idem_uq on wallet_request(app_entity_id, idempotency_key);

-- replace the 2-arg versions with idempotent 3-arg versions
drop function if exists request_deposit(text, numeric);
drop function if exists request_withdrawal(text, numeric);

create function request_deposit(
    currency_param text, amount_param numeric, idempotency_key_param text default null)
  returns text language plpgsql security definer set search_path = public, pg_temp
as $$
declare eid bigint := current_app_entity_id(); req text;
begin
  if eid is null then raise exception 'not_authenticated'; end if;
  perform assert_entity_active(eid);
  if amount_param <= 0 then raise exception 'amount_must_be_positive'; end if;
  perform 1 from currency where name = currency_param;
  if not found then raise exception 'unknown_currency: %', currency_param; end if;

  if idempotency_key_param is not null then
    select pub_id into req from wallet_request
      where app_entity_id = eid and idempotency_key = idempotency_key_param;
    if found then return req; end if;          -- idempotent replay
  end if;

  begin
    insert into wallet_request(app_entity_id, direction, currency, amount, idempotency_key)
      values (eid, 'DEPOSIT', currency_param, amount_param, idempotency_key_param)
      returning pub_id into req;
  exception when unique_violation then          -- concurrent duplicate
    select pub_id into req from wallet_request
      where app_entity_id = eid and idempotency_key = idempotency_key_param;
    return req;
  end;
  return req;
end $$;

create function request_withdrawal(
    currency_param text, amount_param numeric, idempotency_key_param text default null)
  returns text language plpgsql security definer set search_path = public, pg_temp
as $$
declare eid bigint := current_app_entity_id(); ca currency_account%rowtype; req text;
begin
  if eid is null then raise exception 'not_authenticated'; end if;
  perform assert_entity_active(eid);
  if amount_param <= 0 then raise exception 'amount_must_be_positive'; end if;

  if idempotency_key_param is not null then
    select pub_id into req from wallet_request
      where app_entity_id = eid and idempotency_key = idempotency_key_param;
    if found then return req; end if;          -- idempotent replay: no double-reserve
  end if;

  select * into ca from currency_account where app_entity_id = eid and currency_name = currency_param;
  if not found then raise exception 'no_currency_account: %', currency_param; end if;
  if ca.amount - ca.amount_reserved < amount_param then
    raise exception 'insufficient_available_balance: available %, requested %',
      ca.amount - ca.amount_reserved, amount_param;
  end if;

  begin
    insert into wallet_request(app_entity_id, direction, currency, amount, idempotency_key)
      values (eid, 'WITHDRAWAL', currency_param, amount_param, idempotency_key_param)
      returning pub_id into req;
  exception when unique_violation then          -- concurrent duplicate: don't reserve again
    select pub_id into req from wallet_request
      where app_entity_id = eid and idempotency_key = idempotency_key_param;
    return req;
  end;

  update currency_account
    set amount_reserved = amount_reserved + amount_param, updated_at = current_timestamp
    where id = ca.id;
  return req;
end $$;

grant execute on function request_deposit(text,numeric,text), request_withdrawal(text,numeric,text)
  to authenticated, service_role;
revoke execute on function request_deposit(text,numeric,text), request_withdrawal(text,numeric,text)
  from public;
