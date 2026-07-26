-- Auth + RLS, internal wallet, pre-trade risk, back-office basics
--
-- Squashed from the pre-launch incremental migrations, concatenated in their
-- original apply order (so the resulting schema is identical). Section headers
-- below name the migration each block came from.


-- ══ 00490_auth_rls.sql ══════════════════════════════════════════

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


-- ══ 00500_wallet.sql ══════════════════════════════════════════

-- Stage 4: internal-ledger wallet (deposits & withdrawals) with admin approval.
--
-- No external chain/bank integration: deposits are admin-confirmed credits and
-- withdrawals are admin-approved debits, both settling through the engine's
-- double-entry ledger (process_transfer / create_transfer to & from MASTER).
-- Withdrawal funds are reserved at request time so they can't also be traded.

create table wallet_request (
  id            bigserial primary key,
  pub_id        text not null unique default uuid_generate_v4(),
  app_entity_id bigint not null references app_entity(id),
  direction     text not null check (direction in ('DEPOSIT','WITHDRAWAL')),
  currency      text not null references currency(name),
  amount        numeric not null check (amount > 0),
  status        text not null default 'PENDING' check (status in ('PENDING','APPROVED','REJECTED')),
  transfer_pub_id text,                  -- engine transfer once settled
  note          text,
  created_at    timestamptz not null default current_timestamp,
  resolved_at   timestamptz
);
create index wallet_request_entity_idx on wallet_request(app_entity_id);
create index wallet_request_status_idx on wallet_request(status);

-- ── user-facing: submit requests ─────────────────────────────────────────────
create or replace function request_withdrawal(currency_param text, amount_param numeric)
  returns text                          -- wallet_request pub_id
  language plpgsql security definer set search_path = public, pg_temp
as $$
declare
  eid bigint := current_app_entity_id();
  ca  currency_account%rowtype;
  req text;
begin
  if eid is null then raise exception 'not_authenticated'; end if;
  if amount_param <= 0 then raise exception 'amount_must_be_positive'; end if;
  select * into ca from currency_account where app_entity_id = eid and currency_name = currency_param;
  if not found then raise exception 'no_currency_account: %', currency_param; end if;
  if ca.amount - ca.amount_reserved < amount_param then
    raise exception 'insufficient_available_balance: available %, requested %',
      ca.amount - ca.amount_reserved, amount_param;
  end if;
  -- reserve so the funds can't be traded or double-withdrawn while pending
  update currency_account
    set amount_reserved = amount_reserved + amount_param, updated_at = current_timestamp
    where id = ca.id;
  insert into wallet_request(app_entity_id, direction, currency, amount)
    values (eid, 'WITHDRAWAL', currency_param, amount_param)
    returning pub_id into req;
  return req;
end $$;

create or replace function request_deposit(currency_param text, amount_param numeric)
  returns text
  language plpgsql security definer set search_path = public, pg_temp
as $$
declare
  eid bigint := current_app_entity_id();
  req text;
begin
  if eid is null then raise exception 'not_authenticated'; end if;
  if amount_param <= 0 then raise exception 'amount_must_be_positive'; end if;
  perform 1 from currency where name = currency_param;
  if not found then raise exception 'unknown_currency: %', currency_param; end if;
  insert into wallet_request(app_entity_id, direction, currency, amount)
    values (eid, 'DEPOSIT', currency_param, amount_param)
    returning pub_id into req;
  return req;          -- intent only; admin confirms when real funds arrive
end $$;

-- ── admin-facing: resolve requests (service_role only) ───────────────────────
create or replace function approve_wallet_request(request_pub_param text, note_param text default null)
  returns text                          -- engine transfer pub_id
  language plpgsql security definer set search_path = public, pg_temp
as $$
declare
  r   wallet_request%rowtype;
  pub text;
  tr  text;
begin
  select * into r from wallet_request where pub_id = request_pub_param for update;
  if not found then raise exception 'request_not_found'; end if;
  if r.status <> 'PENDING' then raise exception 'request_not_pending: %', r.status; end if;
  select pub_id into pub from app_entity where id = r.app_entity_id;

  if r.direction = 'DEPOSIT' then
    tr := process_transfer('DEPOSIT', 'MASTER', r.amount, r.currency, pub,
                           'wallet:' || r.pub_id, 'wallet deposit', null);
  else  -- WITHDRAWAL: debit user -> MASTER. create_transfer reduces `amount` but only
        -- releases reservations for INSTRUMENT_* types, so free the hold HERE — and BEFORE
        -- the debit, else a full-balance withdrawal transiently leaves amount_reserved >
        -- amount (violates currency_account_check).
    update currency_account
      set amount_reserved = greatest(amount_reserved - r.amount, 0), updated_at = current_timestamp
      where app_entity_id = r.app_entity_id and currency_name = r.currency;
    tr := create_transfer('WITHDRAWAL', pub, r.amount, r.currency, 'MASTER',
                          'wallet:' || r.pub_id, 'wallet withdrawal');
  end if;

  update wallet_request
    set status = 'APPROVED', transfer_pub_id = tr, note = note_param, resolved_at = current_timestamp
    where id = r.id;
  return tr;
end $$;

create or replace function reject_wallet_request(request_pub_param text, note_param text default null)
  returns void
  language plpgsql security definer set search_path = public, pg_temp
as $$
declare r wallet_request%rowtype;
begin
  select * into r from wallet_request where pub_id = request_pub_param for update;
  if not found then raise exception 'request_not_found'; end if;
  if r.status <> 'PENDING' then raise exception 'request_not_pending: %', r.status; end if;

  if r.direction = 'WITHDRAWAL' then  -- release the reservation
    update currency_account
      set amount_reserved = greatest(amount_reserved - r.amount, 0), updated_at = current_timestamp
      where app_entity_id = r.app_entity_id and currency_name = r.currency;
  end if;

  update wallet_request
    set status = 'REJECTED', note = note_param, resolved_at = current_timestamp
    where id = r.id;
end $$;

-- ── RLS + grants ─────────────────────────────────────────────────────────────
alter table wallet_request enable row level security;
create policy own_wallet_requests on wallet_request
  for select to authenticated using (app_entity_id = current_app_entity_id());
grant select on wallet_request to authenticated;

-- Supabase default privileges auto-grant EXECUTE to anon+authenticated on every
-- new public function, so we must revoke from those roles explicitly (not just
-- PUBLIC) to actually restrict admin functions.
revoke execute on function
  request_withdrawal(text,numeric), request_deposit(text,numeric),
  approve_wallet_request(text,text), reject_wallet_request(text,text)
  from public, anon, authenticated;
grant execute on function request_withdrawal(text,numeric), request_deposit(text,numeric)
  to authenticated, service_role;
grant execute on function approve_wallet_request(text,text), reject_wallet_request(text,text)
  to service_role;


-- ══ 00510_realtime_wallet.sql ══════════════════════════════════════════

-- Stage 6: extend the authenticated private feed with wallet status.
-- wallet_request is RLS-scoped (own_wallet_requests), so publishing it to Realtime
-- lets a user receive live updates on THEIR OWN requests (e.g. PENDING -> APPROVED)
-- while Postgres Changes enforces the RLS per subscriber. Combined with the
-- already-published trade_order, an authenticated client gets a complete private
-- stream: order lifecycle + fills + wallet status.

alter publication supabase_realtime add table wallet_request;
alter table wallet_request replica identity full;


-- ══ 00520_risk_controls.sql ══════════════════════════════════════════

-- Stage 2 (part 3): pre-trade risk controls (per instrument).
-- Enforced on the authenticated user path (place_order). The admin path
-- (submit_order via service_role) intentionally bypasses risk for overrides.

create table instrument_risk (
  instrument_id      bigint primary key references instrument(id),
  max_order_amount   numeric,        -- max base qty per order (null = unlimited)
  max_order_notional numeric,        -- max price*amount in quote per order
  price_band_pct     numeric,        -- limit price must be within +/- pct of last trade
  enabled            boolean not null default true,
  updated_at         timestamptz not null default current_timestamp
);

create or replace function check_order_risk(
    iid bigint, side_param order_side, price_param numeric, amount_param numeric)
  returns void
  language plpgsql security definer set search_path = public, pg_temp
as $$
declare
  r   instrument_risk%rowtype;
  ref numeric;
begin
  select * into r from instrument_risk where instrument_id = iid;
  if not found or not r.enabled then return; end if;

  if r.max_order_amount is not null and amount_param > r.max_order_amount then
    raise exception 'risk_max_order_amount: % > %', amount_param, r.max_order_amount;
  end if;

  if r.max_order_notional is not null and price_param is not null
     and price_param * amount_param > r.max_order_notional then
    raise exception 'risk_max_order_notional: % > %', price_param * amount_param, r.max_order_notional;
  end if;

  if r.price_band_pct is not null and price_param is not null then
    select price into ref from trade where instrument_id = iid order by created_at desc limit 1;
    if ref is not null and abs(price_param - ref) / ref * 100 > r.price_band_pct then
      raise exception 'risk_price_band: % beyond % pct band of last %', price_param, r.price_band_pct, ref;
    end if;
  end if;
end $$;

-- place_order + risk check (resolves caller's own account from auth.uid()).
create or replace function place_order(
    instrument_name_param text,
    side_param            order_side,
    order_type_param      text,
    price_param           numeric,
    amount_param          numeric,
    time_in_force_param   text
  )
  returns text
  language plpgsql security definer set search_path = public, pg_temp
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

  perform check_order_risk(iid, side_param, price_param, amount_param);
  perform pg_advisory_xact_lock(iid);
  return process_trade_order(ia, instrument_name_param, order_type_param,
    side_param, price_param, amount_param, time_in_force_param, 0);
end $$;

-- Sensible default band/limits for the demo instrument.
insert into instrument_risk(instrument_id, max_order_amount, max_order_notional, price_band_pct)
select id, 100, 100000, 10 from instrument where name = 'BTC_EUR';


-- ══ 00530_market_order_risk.sql ══════════════════════════════════════════

-- Market orders carry no meaningful limit price, so the price-band and
-- max-notional sanity checks in `check_order_risk` (which compare against a
-- limit price) don't apply. The frontend sends price = 0 for MARKET orders,
-- which the old place_order fed straight into the band check and got rejected
-- with `risk_price_band: 0 beyond N pct band of last <price>`.
--
-- Also note the engine's BUY MARKET model treats `amount` as the QUOTE budget
-- (currency to spend), not a base quantity — so the per-instrument max base
-- amount limit doesn't map to a BUY MARKET either. SELL MARKET `amount` is
-- still base, so we keep the amount cap for that side.
--
-- Re-define place_order to apply the right risk checks per order type:
--   LIMIT / STOPLIMIT / STOPLOSS → full check (band/notional/amount)
--   SELL MARKET                  → amount cap only (price-based checks skipped)
--   BUY  MARKET                  → no instrument risk check (bounded by funds)

create or replace function place_order(
    instrument_name_param text,
    side_param            order_side,
    order_type_param      text,
    price_param           numeric,
    amount_param          numeric,
    time_in_force_param   text
  )
  returns text
  language plpgsql security definer set search_path = public, pg_temp
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

  if order_type_param = 'MARKET' then
    -- price-based checks (band/notional) are meaningless without a limit price.
    -- SELL MARKET amount is base → keep the amount cap by passing a null price
    -- (check_order_risk guards band/notional on `price is not null`).
    -- BUY MARKET amount is a quote budget → skip the instrument risk check.
    if side_param = 'SELL' then
      perform check_order_risk(iid, side_param, null, amount_param);
    end if;
  else
    perform check_order_risk(iid, side_param, price_param, amount_param);
  end if;

  perform pg_advisory_xact_lock(iid);
  return process_trade_order(ia, instrument_name_param, order_type_param,
    side_param, price_param, amount_param, time_in_force_param, 0);
end $$;


-- ══ 00540_market_order_dust.sql ══════════════════════════════════════════

-- Dust guard for process_trade_order.
--
-- The matching loops compute a per-fill `trade_amount_var` by dividing the
-- remaining quote budget by the maker price and rounding. When only a tiny
-- amount of budget is left, that rounds to 0 and the engine still tried to
-- emit a 0-amount trade, which fails `transfer_amount_check` (transfers must be
-- > 0). This surfaced as BUY MARKET orders erroring with
-- `new row for relation "transfer" violates check constraint "transfer_amount_check"`.
--
-- Add a guard in both the market and limit matching loops: if the computed fill
-- amount is null or <= 0, stop matching. The remaining (dust) budget is then
-- released by the existing per-TIF leftover handling. Market orders are sent
-- IOC by the client, so the dust is released rather than rested on the book.
--
-- This redefinition mirrors engine/pkg/services/trade_order/process_trade_order.sql.

CREATE OR REPLACE FUNCTION
    process_trade_order(
        instrument_account_id_param text,
        instrument_name_param text,
        order_type_param text,
        side_param order_side,
        price_param NUMERIC,
        amount_param NUMERIC,
        time_in_force_param text,
        trade_order_id_param BIGINT
    )
    RETURNS TEXT
    LANGUAGE 'plpgsql'
AS $$
DECLARE
instrument_account_instance instrument_account%ROWTYPE;
    currency_account_instance currency_account%ROWTYPE;
    taker_trade_order_instance trade_order%ROWTYPE;
    maker_book_order_instance trade_order%ROWTYPE;
    book_order_instance book_order%ROWTYPE;
    instrument_instance instrument%ROWTYPE;

    base_currency_precision INTEGER;
    quote_currency_precision INTEGER;

    opposite_side_var order_side;
    book_order_volume_var NUMERIC;
    total_available_volume_var NUMERIC;
    trade_amount_var NUMERIC;
    order_currency_var text;
    trade_price_var NUMERIC;

    trigger_loop_restart BOOLEAN := FALSE;

    original_amount NUMERIC;
    remaining_amount NUMERIC;

    reserve_amount NUMERIC;
    release_amount NUMERIC;
BEGIN
    IF instrument_name_param IS NULL OR length(instrument_name_param) = 0 THEN
        RAISE EXCEPTION 'invalid_instrument';
END IF;

    IF amount_param IS NULL OR amount_param <= 0 THEN
        RAISE EXCEPTION 'invalid_amount';
END IF;

    IF order_type_param IN ('LIMIT','STOPLIMIT') AND (price_param IS NULL OR price_param <= 0) THEN
        RAISE EXCEPTION 'invalid_price';
END IF;

    original_amount := amount_param;
    remaining_amount := amount_param;

    IF instrument_account_id_param != 'VOID' THEN
SELECT *
FROM instrument_account
WHERE pub_id = instrument_account_id_param
    INTO instrument_account_instance;

IF NOT FOUND THEN
            RAISE EXCEPTION 'instrument_account_instance_not_found';
END IF;
END IF;

SELECT *
FROM instrument
WHERE name = instrument_name_param
    INTO instrument_instance;

IF NOT FOUND THEN
        RAISE EXCEPTION 'instrument_instance_not_found';
END IF;

    IF side_param = 'SELL' THEN
        opposite_side_var := 'BUY'::order_side;
        order_currency_var := instrument_instance.base_currency;
ELSE
        opposite_side_var := 'SELL'::order_side;
        order_currency_var := instrument_instance.quote_currency;
END IF;

SELECT c.precision
INTO base_currency_precision
FROM currency c
WHERE c.name = instrument_instance.base_currency;

IF NOT FOUND THEN
        RAISE EXCEPTION 'base_currency_precision_not_found';
END IF;

SELECT c.precision
INTO quote_currency_precision
FROM currency c
WHERE c.name = instrument_instance.quote_currency;

IF NOT FOUND THEN
        RAISE EXCEPTION 'quote_currency_precision_not_found';
END IF;

    IF instrument_account_id_param != 'VOID' THEN
SELECT pa.*
FROM currency_account pa
         INNER JOIN app_entity ae
                    ON pa.app_entity_id = ae.id
WHERE ae.id = instrument_account_instance.app_entity_id
  AND pa.currency_name = order_currency_var
    FOR UPDATE
    INTO currency_account_instance;

IF NOT FOUND THEN
            RAISE EXCEPTION 'currency_account_instance_not_found';
END IF;

        remaining_amount := round(remaining_amount, base_currency_precision);
        original_amount := remaining_amount;

        IF price_param IS NOT NULL THEN
            price_param := round(price_param, quote_currency_precision);
END IF;

        IF side_param = 'SELL' OR (side_param = 'BUY' AND order_type_param = 'MARKET') THEN
            reserve_amount := remaining_amount;
            IF currency_account_instance.amount - currency_account_instance.amount_reserved < reserve_amount THEN
                RAISE EXCEPTION 'insufficient_funds'
                    USING DETAIL = format(
                        'available=%s required=%s',
                        currency_account_instance.amount - currency_account_instance.amount_reserved,
                        reserve_amount
                    );
END IF;

UPDATE currency_account
SET amount_reserved = round(currency_account.amount_reserved + reserve_amount, base_currency_precision)
WHERE id = currency_account_instance.id;
ELSE
            reserve_amount := banker_round(remaining_amount * price_param, quote_currency_precision);
            IF currency_account_instance.amount - currency_account_instance.amount_reserved < reserve_amount THEN
                RAISE EXCEPTION 'insufficient_funds'
                    USING DETAIL = format(
                        'available=%s required=%s',
                        currency_account_instance.amount - currency_account_instance.amount_reserved,
                        reserve_amount
                    );
END IF;

UPDATE currency_account
SET amount_reserved = round(currency_account.amount_reserved + reserve_amount, quote_currency_precision)
WHERE id = currency_account_instance.id;
END IF;

INSERT INTO trade_order (
    instrument_account_id,
    instrument_id,
    order_type,
    side,
    price,
    amount,
    open_amount,
    time_in_force
)
VALUES (
           instrument_account_instance.id,
           instrument_instance.id,
           order_type_param::order_type,
           side_param,
           price_param,
           original_amount,
           original_amount,
           time_in_force_param::order_time_in_force
       )
    RETURNING * INTO taker_trade_order_instance;

ELSE
SELECT *
FROM trade_order
WHERE id = trade_order_id_param
    INTO taker_trade_order_instance;

SELECT *
FROM instrument_account
WHERE id = taker_trade_order_instance.instrument_account_id
    INTO instrument_account_instance;

remaining_amount := taker_trade_order_instance.open_amount;
        original_amount := taker_trade_order_instance.amount;
END IF;

    IF order_type_param = 'STOPLOSS' OR order_type_param = 'STOPLIMIT' THEN
        INSERT INTO stop_order (
            trade_order_id,
            price
        )
        VALUES (
            taker_trade_order_instance.id,
            price_param
        );

RETURN taker_trade_order_instance.pub_id;
END IF;

<<matching_loop>>
    LOOP
        total_available_volume_var =
            get_available_market_volume(instrument_instance.id, opposite_side_var)
            + get_available_limit_volume(instrument_instance.id, opposite_side_var, price_param)
            - get_potential_self_trade_volume(instrument_instance.id, opposite_side_var, instrument_account_instance.id, price_param);

        IF taker_trade_order_instance.time_in_force = 'FOK'::order_time_in_force
           AND total_available_volume_var < remaining_amount THEN

UPDATE trade_order
SET status = 'REJECTED'::trade_order_status
WHERE id = taker_trade_order_instance.id;

IF instrument_account_id_param != 'VOID' THEN
                IF side_param = 'SELL' OR (side_param = 'BUY' AND order_type_param = 'MARKET') THEN
                    release_amount := remaining_amount;
UPDATE currency_account
SET amount_reserved = round(currency_account.amount_reserved - release_amount, base_currency_precision)
WHERE id = currency_account_instance.id;
ELSE
                    release_amount := banker_round(remaining_amount * price_param, quote_currency_precision);
UPDATE currency_account
SET amount_reserved = round(currency_account.amount_reserved - release_amount, quote_currency_precision)
WHERE id = currency_account_instance.id;
END IF;
END IF;

RETURN taker_trade_order_instance.pub_id;
END IF;

<<market_matching_loop>>
        FOR maker_book_order_instance
            IN SELECT t.*
               FROM trade_order t
                        INNER JOIN book_order b
                                   ON b.trade_order_id = t.id
               WHERE t.instrument_id = instrument_instance.id
                 AND t.instrument_account_id != instrument_account_instance.id
                 AND t.side = opposite_side_var
                 AND t.order_type = 'MARKET'::order_type
               ORDER BY t.created_at
                   LOOP
                   trade_price_var := get_trade_price(
                   side_param::order_side,
                   order_type_param::order_type,
                   price_param,
                   opposite_side_var,
                   'MARKET'::order_type,
                   0,
                   instrument_instance.id
                   );

IF trade_price_var IS NULL OR trade_price_var <= 0 OR remaining_amount <= 0 THEN
                EXIT market_matching_loop;
END IF;

            IF side_param = 'SELL' THEN
                trade_amount_var :=
                    banker_round(maker_book_order_instance.open_amount / trade_price_var, quote_currency_precision);
                book_order_volume_var :=
                    maker_book_order_instance.open_amount
                    - banker_round(trade_amount_var * trade_price_var, quote_currency_precision);

                remaining_amount := remaining_amount - trade_amount_var;
ELSE
                IF order_type_param = 'MARKET' THEN
                    IF maker_book_order_instance.open_amount < banker_round(remaining_amount / trade_price_var, quote_currency_precision) THEN
                        trade_amount_var := maker_book_order_instance.open_amount;
ELSE
                        trade_amount_var := banker_round(remaining_amount / trade_price_var, quote_currency_precision);
END IF;

                    remaining_amount := remaining_amount
                        - banker_round(trade_amount_var * trade_price_var, quote_currency_precision);
END IF;

                IF order_type_param = 'LIMIT' THEN
                    IF maker_book_order_instance.open_amount < remaining_amount THEN
                        trade_amount_var := maker_book_order_instance.open_amount;
ELSE
                        trade_amount_var := remaining_amount;
END IF;

                    remaining_amount := remaining_amount - trade_amount_var;
END IF;

                book_order_volume_var := maker_book_order_instance.open_amount - trade_amount_var;
END IF;

            IF trade_amount_var IS NULL OR trade_amount_var <= 0 THEN
                EXIT market_matching_loop;
END IF;

            IF book_order_volume_var = 0 THEN
DELETE FROM book_order
WHERE trade_order_id = maker_book_order_instance.id;
END IF;

            IF side_param = 'SELL' THEN
                PERFORM create_trade(
                    instrument_instance,
                    trade_price_var,
                    trade_amount_var,
                    taker_trade_order_instance,
                    maker_book_order_instance,
                    taker_trade_order_instance
                );
ELSE
                PERFORM create_trade(
                    instrument_instance,
                    trade_price_var,
                    trade_amount_var,
                    maker_book_order_instance,
                    taker_trade_order_instance,
                    taker_trade_order_instance
                );
END IF;

            trigger_loop_restart := activate_crossing_stop_orders(
                instrument_instance.id,
                opposite_side_var::order_side,
                trade_price_var
            );

            IF trigger_loop_restart IS TRUE OR remaining_amount = 0 THEN
                EXIT market_matching_loop;
END IF;
END LOOP;

        IF remaining_amount > 0 THEN
            <<limit_matching_loop>>
            FOR book_order_instance
                IN SELECT *
                   FROM get_crossing_limit_orders(
                                instrument_instance.id,
                                opposite_side_var,
                                price_param,
                                instrument_account_instance.id
                        )
                            LOOP
SELECT *
FROM trade_order
WHERE id = book_order_instance.trade_order_id
    INTO maker_book_order_instance;

trade_price_var := get_trade_price(
                    side_param,
                    order_type_param::order_type,
                    price_param,
                    opposite_side_var,
                    'LIMIT'::order_type,
                    maker_book_order_instance.price,
                    instrument_instance.id
                );

                IF trade_price_var IS NULL OR trade_price_var <= 0 THEN
                    EXIT limit_matching_loop;
END IF;

                IF side_param = 'BUY' AND order_type_param = 'MARKET' THEN
                    trade_amount_var := banker_round(remaining_amount / maker_book_order_instance.price, quote_currency_precision);

                    IF maker_book_order_instance.open_amount < trade_amount_var THEN
                        trade_amount_var := maker_book_order_instance.open_amount;
                        book_order_volume_var := 0;
ELSE
                        book_order_volume_var := maker_book_order_instance.open_amount - trade_amount_var;
END IF;

                    remaining_amount := remaining_amount
                        - banker_round(trade_amount_var * maker_book_order_instance.price, quote_currency_precision);
ELSE
                    IF maker_book_order_instance.open_amount < remaining_amount THEN
                        trade_amount_var := maker_book_order_instance.open_amount;
ELSE
                        trade_amount_var := remaining_amount;
END IF;

                    book_order_volume_var := maker_book_order_instance.open_amount - trade_amount_var;
                    remaining_amount := remaining_amount - trade_amount_var;
END IF;

                IF trade_amount_var IS NULL OR trade_amount_var <= 0 THEN
                    EXIT limit_matching_loop;
END IF;

                IF book_order_volume_var = 0 THEN
DELETE FROM book_order
WHERE id = book_order_instance.id;
END IF;

                IF side_param = 'SELL' THEN
                    PERFORM create_trade(
                        instrument_instance,
                        trade_price_var,
                        trade_amount_var,
                        taker_trade_order_instance,
                        maker_book_order_instance,
                        taker_trade_order_instance
                    );
ELSE
                    PERFORM create_trade(
                        instrument_instance,
                        trade_price_var,
                        trade_amount_var,
                        maker_book_order_instance,
                        taker_trade_order_instance,
                        taker_trade_order_instance
                    );
END IF;

                trigger_loop_restart := activate_crossing_stop_orders(
                    instrument_instance.id,
                    opposite_side_var::order_side,
                    trade_price_var
                );

                IF trigger_loop_restart IS TRUE OR remaining_amount = 0 THEN
                    EXIT limit_matching_loop;
END IF;
END LOOP;
END IF;

        IF trigger_loop_restart IS TRUE THEN
            trigger_loop_restart := FALSE;
ELSE
            EXIT matching_loop;
END IF;
END LOOP;

    IF remaining_amount > 0 THEN
        IF taker_trade_order_instance.time_in_force = 'IOC'::order_time_in_force THEN
            IF taker_trade_order_instance.open_amount != remaining_amount THEN
UPDATE trade_order
SET status = 'PARTIALLY_REJECTED'::trade_order_status
WHERE id = taker_trade_order_instance.id
    RETURNING * INTO taker_trade_order_instance;
ELSE
UPDATE trade_order
SET status = 'REJECTED'::trade_order_status
WHERE id = taker_trade_order_instance.id
    RETURNING * INTO taker_trade_order_instance;
END IF;

            IF instrument_account_id_param != 'VOID' THEN
                IF side_param = 'SELL' OR (side_param = 'BUY' AND order_type_param = 'MARKET') THEN
UPDATE currency_account
SET amount_reserved = round(currency_account.amount_reserved - remaining_amount, base_currency_precision)
WHERE id = currency_account_instance.id;
ELSE
UPDATE currency_account
SET amount_reserved =
        round(currency_account.amount_reserved - banker_round(remaining_amount * price_param, quote_currency_precision), quote_currency_precision)
WHERE id = currency_account_instance.id;
END IF;
END IF;
ELSE
SELECT *
FROM trade_order
WHERE id = taker_trade_order_instance.id
    INTO taker_trade_order_instance;

PERFORM create_book_order(taker_trade_order_instance);
END IF;
END IF;

    PERFORM process_crossing_stop_orders(instrument_instance.id, side_param::order_side, trade_price_var);

RETURN taker_trade_order_instance.pub_id;
END;
$$;


-- ══ 00550_backoffice.sql ══════════════════════════════════════════

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


-- ══ 00560_wallet_idempotency.sql ══════════════════════════════════════════

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
