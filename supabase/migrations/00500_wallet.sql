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
