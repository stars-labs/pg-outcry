-- Withdrawal send-queue: hand APPROVED on-chain withdrawals to an external signer.
--
-- Why an external signer at all? pgcrypto (schema `extensions`) has no secp256k1
-- or keccak, so Postgres cannot sign an EVM transaction. Deposits CAN be watched
-- in-DB (9920), but a WITHDRAWAL must be signed+broadcast by an outside process
-- that holds the hot key. This migration is ONLY the on-chain send bookkeeping;
-- it never moves ledger funds.
--
-- LEDGER NOTE — do NOT double-spend: approve_wallet_request (9300) already did
-- the money side for a WITHDRAWAL: it create_transfer'd user -> MASTER AND
-- released the reservation (amount_reserved -= amount). By the time a row is
-- APPROVED with a to_address, the user has already been debited. So the signer
-- queue here strictly tracks "did we put it on the chain yet", with NO currency_
-- account / transfer writes whatsoever.
--
-- Numbered >9900 so 9900_lockdown's deny-by-default sweep does not strip these
-- grants (it runs once, earlier; new funcs created here keep their grants).

-- ── lifecycle columns on wallet_request ──────────────────────────────────────
-- A withdrawal's on-chain send moves through:
--   APPROVED (status) + to_address set      -> eligible to claim
--   signing_claimed_at set                  -> a signer owns it (won't be re-handed out)
--   broadcast_txid + broadcast_at set       -> tx is on the chain
--   confirmed_at set                        -> tx is mined/confirmed (terminal)
alter table wallet_request add column if not exists signing_claimed_at timestamptz;
alter table wallet_request add column if not exists broadcast_txid     text;
alter table wallet_request add column if not exists broadcast_at       timestamptz;
alter table wallet_request add column if not exists confirmed_at       timestamptz;

-- ── service_role: claim the next withdrawal to sign ──────────────────────────
-- Atomic claim so two concurrent signers never both send the same withdrawal.
-- The SELECT ... FOR UPDATE SKIP LOCKED row-locks one eligible row (skipping any
-- a sibling signer already holds in its open transaction); we then stamp
-- signing_claimed_at inside the SAME transaction so once committed the row no
-- longer matches the `signing_claimed_at is null` predicate. Result: each
-- withdrawal is handed out at most once. (broadcast_txid is also re-checked so a
-- crashed-before-commit claim that left no stamp still can't be re-broadcast once
-- a txid exists.)
create or replace function next_withdrawal_to_sign()
  returns json
  language plpgsql security definer set search_path = public, pg_temp
as $$
declare r wallet_request%rowtype;
begin
  select * into r from wallet_request
   where direction = 'WITHDRAWAL'
     and status = 'APPROVED'
     and to_address is not null
     and signing_claimed_at is null
     and broadcast_txid is null
   order by resolved_at nulls last, id
   for update skip locked
   limit 1;
  if not found then return null; end if;

  update wallet_request set signing_claimed_at = current_timestamp where id = r.id;

  return json_build_object(
    'pub_id',     r.pub_id,
    'currency',   r.currency,
    'amount',     r.amount,
    'to_address', r.to_address);
end $$;

-- ── service_role: record broadcast (idempotent) ──────────────────────────────
-- Stamp the on-chain tx hash. No-op if a txid is already recorded so a signer
-- retry never overwrites the first broadcast.
create or replace function mark_withdrawal_broadcast(request_pub text, txid text)
  returns boolean
  language plpgsql security definer set search_path = public, pg_temp
as $$
declare n int;
begin
  if coalesce(trim(txid), '') = '' then raise exception 'txid_required'; end if;
  update wallet_request
     set broadcast_txid = txid, broadcast_at = current_timestamp
   where pub_id = request_pub
     and direction = 'WITHDRAWAL'
     and broadcast_txid is null;        -- idempotent: don't clobber an existing txid
  get diagnostics n = row_count;
  if n > 0 then return true; end if;
  -- already broadcast (idempotent replay) is success; a missing row is an error
  if exists (select 1 from wallet_request where pub_id = request_pub) then return false; end if;
  raise exception 'request_not_found: %', request_pub;
end $$;

-- ── service_role: record confirmation (idempotent) ───────────────────────────
create or replace function mark_withdrawal_confirmed(request_pub text)
  returns boolean
  language plpgsql security definer set search_path = public, pg_temp
as $$
declare n int;
begin
  update wallet_request
     set confirmed_at = current_timestamp
   where pub_id = request_pub
     and direction = 'WITHDRAWAL'
     and broadcast_txid is not null     -- can only confirm something we broadcast
     and confirmed_at is null;          -- idempotent
  get diagnostics n = row_count;
  if n > 0 then return true; end if;
  if exists (select 1 from wallet_request where pub_id = request_pub and confirmed_at is not null)
    then return false; end if;          -- already confirmed: idempotent replay
  raise exception 'not_broadcast_or_not_found: %', request_pub;
end $$;

-- ── grants ───────────────────────────────────────────────────────────────────
-- These are the operator/signer plane only. Users see send status through the
-- existing wallet_request RLS select grant (broadcast_txid / confirmed_at are
-- now visible on their own rows) — they must NOT be able to claim or mark.
-- Supabase default privileges auto-grant EXECUTE on every new public function to
-- anon+authenticated, so revoke from those roles explicitly (not just PUBLIC).
revoke execute on function
  next_withdrawal_to_sign(),
  mark_withdrawal_broadcast(text,text),
  mark_withdrawal_confirmed(text)
  from public, anon, authenticated;
grant execute on function
  next_withdrawal_to_sign(),
  mark_withdrawal_broadcast(text,text),
  mark_withdrawal_confirmed(text)
  to service_role;
