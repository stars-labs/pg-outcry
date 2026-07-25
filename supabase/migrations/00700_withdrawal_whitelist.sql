-- Withdrawal security: address whitelist (with a cooling period) + rolling-window
-- limits. A withdrawal to an address is only allowed once the address has been
-- whitelisted and its cooling period has elapsed, and only if it stays under the
-- per-currency limit over the trailing window.
--
-- Numbered >9900 so 9900_lockdown does not strip the grants.

alter table wallet_request add column if not exists to_address text;

create table if not exists withdrawal_address (
  id            bigint generated always as identity primary key,
  app_entity_id bigint not null references app_entity(id) on delete cascade,
  currency      text not null,
  address       text not null,
  label         text,
  created_at    timestamptz not null default now(),
  active_at     timestamptz not null default now() + interval '24 hours',  -- cooling period
  removed_at    timestamptz,
  unique (app_entity_id, currency, address)
);
create index if not exists withdrawal_address_entity_idx on withdrawal_address(app_entity_id);

-- per-currency rolling-window limit (global defaults; a venue can tune per row)
create table if not exists withdrawal_limit (
  currency     text primary key,
  window_hours int   not null default 24,
  max_amount   numeric not null
);
insert into withdrawal_limit(currency, max_amount) values
  ('EUR', 50000), ('BTC', 5)
on conflict do nothing;

create or replace function add_withdrawal_address(currency_param text, address_param text,
                                                  label_param text default null)
  returns json language plpgsql security definer set search_path = public, pg_temp
as $$
declare eid bigint := current_app_entity_id(); r withdrawal_address%rowtype;
begin
  if eid is null then raise exception 'not_authenticated'; end if;
  if coalesce(trim(address_param), '') = '' then raise exception 'address_required'; end if;
  insert into withdrawal_address(app_entity_id, currency, address, label)
    values (eid, currency_param, address_param, label_param)
    on conflict (app_entity_id, currency, address) do update
      set removed_at = null, label = excluded.label  -- re-add resets removal (cooling already passed)
    returning * into r;
  return json_build_object('id', r.id, 'currency', r.currency, 'address', r.address,
    'active_at', r.active_at, 'note', 'usable after the cooling period (active_at)');
end $$;

create or replace function remove_withdrawal_address(address_id_param bigint)
  returns boolean language plpgsql security definer set search_path = public, pg_temp
as $$
declare eid bigint := current_app_entity_id(); n int;
begin
  if eid is null then raise exception 'not_authenticated'; end if;
  update withdrawal_address set removed_at = now()
    where id = address_id_param and app_entity_id = eid and removed_at is null;
  get diagnostics n = row_count; return n > 0;
end $$;

-- whitelisted, cooled, rolling-limit-checked withdrawal request.
create or replace function request_withdrawal_to(
    currency_param text, amount_param numeric, to_address_param text,
    idempotency_key_param text default null)
  returns text language plpgsql security definer set search_path = public, pg_temp
as $$
declare
  eid bigint := current_app_entity_id();
  ca currency_account%rowtype; req text;
  win int; lim numeric; used numeric;
begin
  if eid is null then raise exception 'not_authenticated'; end if;
  perform assert_entity_active(eid);
  if amount_param <= 0 then raise exception 'amount_must_be_positive'; end if;

  -- address must be whitelisted and past its cooling period
  if not exists (select 1 from withdrawal_address w
                 where w.app_entity_id = eid and w.currency = currency_param
                   and w.address = to_address_param and w.removed_at is null
                   and w.active_at <= now()) then
    raise exception 'address_not_whitelisted_or_cooling: %', to_address_param;
  end if;

  -- rolling-window limit (counts pending + completed requests in the window)
  select window_hours, max_amount into win, lim from withdrawal_limit where currency = currency_param;
  if lim is not null then
    select coalesce(sum(amount), 0) into used from wallet_request
      where app_entity_id = eid and direction = 'WITHDRAWAL' and currency = currency_param
        and status <> 'REJECTED' and created_at > now() - make_interval(hours => win);
    if used + amount_param > lim then
      raise exception 'withdrawal_limit_exceeded: % + % > % per %h',
        used, amount_param, lim, win;
    end if;
  end if;

  -- idempotency replay
  if idempotency_key_param is not null then
    select pub_id into req from wallet_request
      where app_entity_id = eid and idempotency_key = idempotency_key_param;
    if found then return req; end if;
  end if;

  select * into ca from currency_account where app_entity_id = eid and currency_name = currency_param;
  if not found then raise exception 'no_currency_account: %', currency_param; end if;
  if ca.amount - ca.amount_reserved < amount_param then
    raise exception 'insufficient_available_balance: available %, requested %',
      ca.amount - ca.amount_reserved, amount_param;
  end if;

  begin
    insert into wallet_request(app_entity_id, direction, currency, amount, idempotency_key, to_address)
      values (eid, 'WITHDRAWAL', currency_param, amount_param, idempotency_key_param, to_address_param)
      returning pub_id into req;
  exception when unique_violation then
    select pub_id into req from wallet_request
      where app_entity_id = eid and idempotency_key = idempotency_key_param;
    return req;
  end;

  update currency_account
    set amount_reserved = amount_reserved + amount_param, updated_at = current_timestamp
    where id = ca.id;
  return req;
end $$;

-- own whitelisted addresses
create or replace view withdrawal_addresses as
  select id, currency, address, label, created_at, active_at,
         (active_at <= now()) as usable
  from withdrawal_address where removed_at is null;
alter view withdrawal_addresses set (security_invoker = on);
alter table withdrawal_address enable row level security;
drop policy if exists own_withdrawal_address on withdrawal_address;
create policy own_withdrawal_address on withdrawal_address for select to authenticated
  using (app_entity_id = current_app_entity_id());

grant select on withdrawal_addresses to authenticated;
grant execute on function add_withdrawal_address(text, text, text),
                          remove_withdrawal_address(bigint),
                          request_withdrawal_to(text, numeric, text, text) to authenticated;
-- authenticated-only (revoke the Supabase default anon grant)
revoke execute on function add_withdrawal_address(text, text, text),
                           remove_withdrawal_address(bigint),
                           request_withdrawal_to(text, numeric, text, text) from public, anon;
