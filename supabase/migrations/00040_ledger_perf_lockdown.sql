-- Append-only ledger + reconciliation, partitioning, performance, deny-by-default lockdown
--
-- Squashed from the pre-launch incremental migrations, concatenated in their
-- original apply order (so the resulting schema is identical). Section headers
-- below name the migration each block came from.


-- ══ 00570_reconciliation.sql ══════════════════════════════════════════

-- Stage 4 (hardening): append-only ledger + reconciliation report.
--
-- The double-entry ledger entry tables are immutable: the engine only INSERTs
-- DEBIT/CREDIT rows, never updates/deletes them. Enforce that so balances can
-- always be re-derived and audited.

create or replace function forbid_ledger_mutation()
  returns trigger language plpgsql as $$
begin
  raise exception 'append_only_ledger: % on % is not allowed', tg_op, tg_table_name;
end $$;

create trigger transfer_ledger_append_only
  before update or delete on transfer_ledger_entry
  for each row execute function forbid_ledger_mutation();
create trigger iae_ledger_append_only
  before update or delete on instrument_account_ledger_entry
  for each row execute function forbid_ledger_mutation();

-- ── reconciliation report ────────────────────────────────────────────────────
-- Each row is one invariant; failures = 0 means healthy. Admin-only (service_role).

create or replace function reconcile()
  returns table(check_name text, failures bigint, status text)
  language sql security definer set search_path = public, pg_temp
as $$
  -- 1) per-customer cash balance == sum(CREDIT) - sum(DEBIT) of its ledger
  select 'cash_balance_matches_ledger', count(*),
         case when count(*) = 0 then 'PASS' else 'FAIL' end
  from (
    select ca.id
    from currency_account ca
    join app_entity ae on ae.id = ca.app_entity_id and ae.type <> 'MASTER'
    left join transfer_ledger_entry le on le.currency_account_id = ca.id
    group by ca.id, ca.amount
    having ca.amount <> coalesce(sum(case when le.entry_type = 'CREDIT' then le.amount else -le.amount end), 0)
  ) bad

  union all
  -- 2) every transfer is balanced: total debits == total credits
  select 'transfer_double_entry_balanced', count(*),
         case when count(*) = 0 then 'PASS' else 'FAIL' end
  from (
    select transfer_id
    from transfer_ledger_entry
    group by transfer_id
    having sum(case when entry_type = 'DEBIT' then amount else 0 end)
         <> sum(case when entry_type = 'CREDIT' then amount else 0 end)
  ) bad

  union all
  -- 3) reservations sane: covers pending withdrawals, never exceeds balance, available >= 0
  select 'reservations_consistent', count(*),
         case when count(*) = 0 then 'PASS' else 'FAIL' end
  from currency_account ca
  left join (
    select app_entity_id, currency, sum(amount) amt
    from wallet_request where status = 'PENDING' and direction = 'WITHDRAWAL'
    group by app_entity_id, currency
  ) p on p.app_entity_id = ca.app_entity_id and p.currency = ca.currency_name
  join app_entity ae on ae.id = ca.app_entity_id and ae.type <> 'MASTER'
  where ca.amount_reserved < coalesce(p.amt, 0)
     or ca.amount_reserved > ca.amount
     or ca.amount < 0

  union all
  -- 4) every APPROVED wallet request points at a real settlement transfer
  select 'approved_wallet_has_transfer', count(*),
         case when count(*) = 0 then 'PASS' else 'FAIL' end
  from wallet_request w
  where w.status = 'APPROVED'
    and (w.transfer_pub_id is null or not exists (select 1 from transfer t where t.pub_id = w.transfer_pub_id))

  union all
  -- 5) issuance: per currency, total customer balances == MASTER net outflow
  select 'issuance_conserved', count(*),
         case when count(*) = 0 then 'PASS' else 'FAIL' end
  from (
    select cust.currency_name
    from (
      select currency_name, coalesce(sum(amount),0) bal
      from currency_account ca join app_entity ae on ae.id = ca.app_entity_id and ae.type <> 'MASTER'
      group by currency_name
    ) cust
    join (
      select ca.currency_name,
             coalesce(sum(case when le.entry_type = 'DEBIT' then le.amount else -le.amount end),0) net_out
      from currency_account ca
      join app_entity ae on ae.id = ca.app_entity_id and ae.type = 'MASTER'
      left join transfer_ledger_entry le on le.currency_account_id = ca.id
      group by ca.currency_name
    ) m on m.currency_name = cust.currency_name
    where cust.bal <> m.net_out
  ) bad;
$$;

create or replace view reconciliation_report as select * from reconcile();

grant execute on function reconcile() to service_role;
grant select on reconciliation_report to service_role;


-- ══ 00580_cold_partitioning.sql ══════════════════════════════════════════

-- Performance: cold-data partitioning of append-only history tables.
--
-- trade (tape) and the ledger entry tables grow unbounded. Convert them to
-- monthly RANGE partitions on created_at so recent data stays hot and old
-- partitions can be detached/compressed/exported. These tables have NO incoming
-- FKs and are empty at migration time, so we recreate them as partitioned with
-- faithful DDL (partition key must be in the PK -> PK becomes (id, created_at)).
-- A DEFAULT partition guarantees inserts never fail; pg_cron rolls future months.

-- reusable helper: create monthly partitions [start, start+months)
create or replace function create_monthly_partitions(tbl text, start_month date, months int)
  returns void language plpgsql as $$
declare m date; pname text;
begin
  for i in 0..months-1 loop
    m := date_trunc('month', start_month)::date + (i || ' months')::interval;
    pname := tbl || '_p' || to_char(m, 'YYYY_MM');
    execute format('create table if not exists %I partition of %I for values from (%L) to (%L)',
      pname, tbl, to_char(m,'YYYY-MM-DD'), to_char((m + interval '1 month'),'YYYY-MM-DD'));
  end loop;
end $$;

-- ── trade (public tape) ──────────────────────────────────────────────────────
drop table if exists trade cascade;          -- also drops dependent view trade_history
create sequence if not exists trade_id_seq;
create table trade (
  id              bigint not null default nextval('trade_id_seq'::regclass),
  pub_id          text   not null default extensions.uuid_generate_v4(),
  instrument_id   bigint not null references instrument(id),
  price           numeric not null,
  amount          numeric not null,
  seller_order_id bigint not null references trade_order(id),
  buyer_order_id  bigint not null references trade_order(id),
  taker_order_id  bigint not null references trade_order(id),
  updated_at      timestamptz not null default current_timestamp,
  created_at      timestamptz not null default current_timestamp,
  primary key (id, created_at),
  unique (pub_id, created_at)
) partition by range (created_at);
alter sequence trade_id_seq owned by trade.id;
create index idx_trade_instrument_created on trade(instrument_id, created_at desc);
create index idx_trade_buyer_order  on trade(buyer_order_id);
create index idx_trade_seller_order on trade(seller_order_id);
create index idx_trade_taker_order  on trade(taker_order_id);
alter table trade replica identity default;
grant select on trade to anon, authenticated, service_role;
grant all on sequence trade_id_seq to anon, authenticated, service_role;

-- ── transfer_ledger_entry (cash ledger, append-only) ─────────────────────────
drop table if exists transfer_ledger_entry cascade;
create sequence if not exists transfer_ledger_entry_id_seq;
create table transfer_ledger_entry (
  id                  bigint not null default nextval('transfer_ledger_entry_id_seq'::regclass),
  pub_id              text   not null default extensions.uuid_generate_v4(),
  transfer_id         bigint not null references transfer(id) on delete cascade,
  currency_account_id bigint not null references currency_account(id),
  entry_type          ledger_entry_type not null,
  amount              numeric not null default 0.00 check (amount > 0),
  resulting_balance   numeric not null default 0.00 check (resulting_balance >= 0),
  created_at          timestamptz not null default current_timestamp,
  primary key (id, created_at),
  unique (pub_id, created_at)
) partition by range (created_at);
alter sequence transfer_ledger_entry_id_seq owned by transfer_ledger_entry.id;
create index idx_tle_currency_account_id on transfer_ledger_entry(currency_account_id);
create index idx_tle_transfer_id on transfer_ledger_entry(transfer_id);
create trigger transfer_ledger_append_only before update or delete on transfer_ledger_entry
  for each row execute function forbid_ledger_mutation();
alter table transfer_ledger_entry enable row level security;
grant select on transfer_ledger_entry to service_role;
grant all on sequence transfer_ledger_entry_id_seq to anon, authenticated, service_role;

-- ── instrument_account_ledger_entry (asset ledger, append-only) ──────────────
drop table if exists instrument_account_ledger_entry cascade;
create sequence if not exists instrument_account_ledger_entry_id_seq;
create table instrument_account_ledger_entry (
  id                            bigint not null default nextval('instrument_account_ledger_entry_id_seq'::regclass),
  pub_id                        text   not null default extensions.uuid_generate_v4(),
  transfer_id                   bigint not null references instrument_account_transfer(id),
  instrument_account_holding_id bigint not null references instrument_account_holding(id),
  entry_type                    ledger_entry_type not null,
  amount                        integer not null default 0 check (amount > 0),
  resulting_balance             integer not null default 0 check (resulting_balance >= 0),
  created_at                    timestamptz not null default current_timestamp,
  primary key (id, created_at),
  unique (pub_id, created_at)
) partition by range (created_at);
alter sequence instrument_account_ledger_entry_id_seq owned by instrument_account_ledger_entry.id;
create index idx_tale_tai_id on instrument_account_ledger_entry(instrument_account_holding_id);
create index idx_tale_transfer_id on instrument_account_ledger_entry(transfer_id);
create trigger iae_ledger_append_only before update or delete on instrument_account_ledger_entry
  for each row execute function forbid_ledger_mutation();
alter table instrument_account_ledger_entry enable row level security;
grant select on instrument_account_ledger_entry to service_role;
grant all on sequence instrument_account_ledger_entry_id_seq to anon, authenticated, service_role;

-- ── create partitions: previous month .. +14 months, plus DEFAULT catch-all ──
do $$
declare t text; start date := (date_trunc('month', now()) - interval '1 month')::date;
begin
  foreach t in array array['trade','transfer_ledger_entry','instrument_account_ledger_entry'] loop
    perform create_monthly_partitions(t, start, 16);
    execute format('create table if not exists %I partition of %I default', t || '_default', t);
  end loop;
end $$;

-- ── recreate the trade_history view dropped by CASCADE ───────────────────────
create or replace view trade_history as
  select t.pub_id, i.name as instrument, t.price, t.amount, t.created_at
  from trade t join instrument i on i.id = t.instrument_id;
alter view trade_history set (security_invoker = on);
grant select on trade_history to anon, authenticated, service_role;

-- ── re-publish trade for realtime (CASCADE removed it) ───────────────────────
-- partitioned tables must publish as the root so Postgres Changes reports table
-- name 'trade' (not the partition name). Best-effort: SET needs publication
-- ownership (supabase_admin) which the hosted migration role lacks — and it's
-- moot here because 9720 removes `trade` from the publication entirely (tape ->
-- Broadcast). Kept for self-host completeness.
do $$
begin
  alter publication supabase_realtime set (publish_via_partition_root = true);
exception when insufficient_privilege or wrong_object_type then
  raise notice 'publish_via_partition_root skipped (no publication ownership on hosted)';
end $$;
do $$
begin
  alter publication supabase_realtime add table trade;
exception when insufficient_privilege or duplicate_object then
  raise notice 'add trade to publication skipped';
end $$;

-- ── monthly maintenance: roll next partitions (best-effort; needs pg_cron) ───
create or replace function roll_partitions() returns void language plpgsql as $$
declare t text;
begin
  foreach t in array array['trade','transfer_ledger_entry','instrument_account_ledger_entry'] loop
    perform create_monthly_partitions(t, date_trunc('month', now())::date, 2);
  end loop;
end $$;

do $$
begin
  create extension if not exists pg_cron;
  perform cron.schedule('roll-partitions', '0 0 1 * *', 'select roll_partitions()');
exception when others then
  raise notice 'pg_cron scheduling skipped: %', sqlerrm;
end $$;


-- ══ 00590_platform.sql ══════════════════════════════════════════

-- Stage 2 (platform): give the API roles headroom for the matching loop.
-- process_trade_order can sweep many resting orders in one call; the default
-- per-statement timeout can be too tight under depth. Concurrency correctness is
-- handled by per-instrument advisory locks (not SERIALIZABLE), so there is no
-- serialization_failure to retry — same-instrument calls simply queue on the lock.

-- Best-effort: on hosted Supabase the migration role may not own these roles.
-- (On hosted you can also set these per-role in the dashboard.)
do $$
begin
  alter role authenticated set statement_timeout = '15s';
  alter role anon          set statement_timeout = '10s';
  alter role service_role  set statement_timeout = '30s';   -- back-office / batch
exception when insufficient_privilege then
  raise notice 'statement_timeout per-role skipped (no privilege on hosted) — set in dashboard';
end $$;


-- ══ 00600_wal_reduction.sql ══════════════════════════════════════════

-- Performance: reduce WAL pressure from realtime publication.
--
-- 9001/9101/9310 set REPLICA IDENTITY FULL on published tables, which writes the
-- ENTIRE old row to WAL on every UPDATE/DELETE. Postgres Changes only needs the
-- NEW tuple (always in WAL) for INSERT/UPDATE, so for tables with a primary key
-- we can use REPLICA IDENTITY DEFAULT (PK only) and cut WAL volume sharply.
--
-- Exception: price_level keeps FULL because a client rendering the L2 book needs
-- the price/side on a DELETE event (volume → 0) to remove the right level; with
-- DEFAULT a DELETE would carry only the row id.

alter table trade          replica identity default;  -- insert-only tape: biggest win
alter table trade_order    replica identity default;  -- consumers read NEW (status/open_amount)
alter table book_order     replica identity default;  -- not the client-facing L2
alter table wallet_request replica identity default;  -- consumers read NEW (status)
-- price_level stays FULL (L2 delete needs old price/side)


-- ══ 00610_async_marketdata.sql ══════════════════════════════════════════

-- Performance: asynchronous, coalesced market-data fan-out.
--
-- Instead of emitting a Postgres Changes event for every price_level row change
-- (one WS message + logical-decode + FULL replica identity per change), the
-- matching tx only marks the instrument dirty. A ticker calls broadcast_md()
-- which coalesces each dirty book into ONE realtime.send() L2 snapshot on topic
-- md:<symbol>. This moves fan-out off the matching critical path, bounds the
-- message rate, and lets price_level leave the Postgres Changes publication
-- (less WAL). Public data -> private=false (anon may subscribe, no auth).

create table md_dirty (instrument_id bigint primary key references instrument(id));
grant select on md_dirty to service_role;

create or replace function mark_md_dirty() returns trigger
  language plpgsql security definer set search_path = public, pg_temp as $$
begin
  insert into md_dirty(instrument_id) values (coalesce(new.instrument_id, old.instrument_id))
    on conflict do nothing;
  return null;
end $$;

create trigger price_level_dirty
  after insert or update or delete on price_level
  for each row execute function mark_md_dirty();

-- Coalesce every dirty book into one L2 broadcast. Call from a ticker (or pg_cron).
-- SKIP LOCKED so overlapping ticker runs never double-send the same instrument.
create or replace function broadcast_md() returns integer
  language plpgsql security definer set search_path = public, pg_temp as $$
declare r record; bids jsonb; asks jsonb; n int := 0;
begin
  for r in
    select d.instrument_id, i.name
    from md_dirty d join instrument i on i.id = d.instrument_id
    for update of d skip locked
  loop
    select coalesce(jsonb_agg(jsonb_build_object('price', price, 'volume', volume) order by price desc), '[]'::jsonb)
      into bids from (
        select price, volume from price_level
        where instrument_id = r.instrument_id and side = 'BUY' and volume > 0
        order by price desc limit 50) b;
    select coalesce(jsonb_agg(jsonb_build_object('price', price, 'volume', volume) order by price asc), '[]'::jsonb)
      into asks from (
        select price, volume from price_level
        where instrument_id = r.instrument_id and side = 'SELL' and volume > 0
        order by price asc limit 50) a;

    perform realtime.send(
      jsonb_build_object('symbol', r.name, 'bids', bids, 'asks', asks),
      'l2', 'md:' || r.name, false);

    delete from md_dirty where instrument_id = r.instrument_id;
    n := n + 1;
  end loop;
  return n;
end $$;

grant execute on function broadcast_md() to service_role;

-- Public trade tape: also async broadcast. (trade is partitioned, and Postgres
-- Changes does not deliver from partitioned tables, so the tape moves to Broadcast
-- on the same md:<symbol> topic with event 'trade'.) One small message per trade.
create or replace function broadcast_trade() returns trigger
  language plpgsql security definer set search_path = public, pg_temp as $$
declare sym text;
begin
  select name into sym from instrument where id = new.instrument_id;
  perform realtime.send(
    jsonb_build_object('symbol', sym, 'price', new.price, 'amount', new.amount,
                       'pub_id', new.pub_id, 'ts', new.created_at),
    'trade', 'md:' || sym, false);
  return null;
end $$;

create trigger trade_broadcast after insert on trade
  for each row execute function broadcast_trade();

-- both heavy tables now fan out via Broadcast; remove from Postgres Changes
-- (cuts logical-decode WAL + frees them for partitioning).
do $$
begin
  alter publication supabase_realtime drop table price_level;
  alter publication supabase_realtime drop table trade;
exception when others then
  raise notice 'publication drop skipped: %', sqlerrm;
end $$;


-- ══ 00620_hot_data.sql ══════════════════════════════════════════

-- Performance: hot-data-in-memory + WAL reduction for the live book.
--
-- book_order and price_level are the live order book — pure derived state,
-- rebuildable from the durable trade_order rows. Make them UNLOGGED: writes skip
-- WAL (big saving on the matching hot path) and the data effectively lives in
-- memory. Trade-off: UNLOGGED tables are TRUNCATEd on crash recovery and are not
-- logically replicated — neither is client-facing on Realtime anymore (L2 is
-- broadcast from price_level reads, the private feed uses trade_order), so this
-- is safe. rebuild_book() reconstructs them after a crash.

-- book_order is not consumed by any Realtime client; drop it so it can be UNLOGGED.
do $$ begin
  alter publication supabase_realtime drop table book_order;
exception when others then null; end $$;

alter table book_order  set unlogged;
alter table price_level set unlogged;

-- Crash recovery: rebuild the in-memory book from durable open orders.
-- Run once on startup after an unclean shutdown (UNLOGGED tables come back empty).
create or replace function rebuild_book()
  returns void language plpgsql security definer set search_path = public, pg_temp
as $$
begin
  truncate book_order;
  delete from price_level;
  insert into book_order (trade_order_id)
    select id from trade_order where status in ('OPEN','PARTIALLY_FILLED');
  insert into price_level (instrument_id, side, price, volume)
    select instrument_id, side, price, sum(open_amount)
    from trade_order
    where status in ('OPEN','PARTIALLY_FILLED')
    group by instrument_id, side, price;
end $$;

grant execute on function rebuild_book() to service_role;


-- ══ 00630_perf_indexes.sql ══════════════════════════════════════════

-- Performance: kill the per-trade stop-order seq scan.
--
-- process_crossing_stop_orders / activate_crossing_stop_orders run on EVERY trade
-- and scan trade_order for crossing STOPLOSS/STOPLIMIT orders. No index covered
-- order_type, so each trade did a Seq Scan over all live orders (profiled:
-- "Rows Removed by Filter: 2602" per call). A partial index over just the stop
-- orders makes that probe instant (0 rows) and stays tiny since stops are rare.

create index if not exists trade_order_stops_idx
  on trade_order (instrument_id, side, price)
  where order_type in ('STOPLOSS','STOPLIMIT');


-- ══ 00640_batch_settlement.sql ══════════════════════════════════════════

-- Performance: batch the double-entry ledger writes in create_transfer.
--
-- The original inserts the DEBIT and CREDIT rows as two separate single-row
-- INSERTs. Per FX trade create_trade calls create_transfer 4x → 8 single-row
-- ledger INSERTs. Merging each transfer's DEBIT+CREDIT into ONE 2-row INSERT
-- halves the ledger-insert statement count (8→4/trade) with identical rows and
-- semantics. Override via CREATE OR REPLACE (engine source stays vendored).

CREATE OR REPLACE FUNCTION
  create_transfer(
      type_param transfer_type,
      from_customer_id_param text,
      amount_param numeric,
      currency_param text,
      to_customer_id_param text,
      reference_param text,
      details_param text
  )
  RETURNS TEXT
LANGUAGE 'plpgsql'
AS $$
DECLARE
    from_currency_account_instance currency_account%ROWTYPE;
    to_currency_account_instance currency_account%ROWTYPE;
    transfer_instance transfer%ROWTYPE;
    currency_instance currency%ROWTYPE;
BEGIN
  IF from_customer_id_param = to_customer_id_param THEN
    RAISE EXCEPTION 'Self-transfer not allowed --> (%, %)', from_customer_id_param, to_customer_id_param;
  END IF;
  SELECT * FROM currency WHERE name = currency_param INTO currency_instance;
  IF NOT FOUND THEN RAISE EXCEPTION 'currency_instance_not_found'; END IF;

  SELECT * FROM currency_account
  WHERE app_entity_id = (SELECT id FROM app_entity WHERE pub_id = from_customer_id_param)
    AND currency_name = currency_instance.name
  INTO from_currency_account_instance;
  IF NOT FOUND THEN RAISE EXCEPTION 'from_currency_account_instance_not_found'; END IF;

  IF from_customer_id_param != 'MASTER' THEN
    IF from_currency_account_instance.amount < amount_param THEN
      RAISE EXCEPTION 'insufficient_funds available: %, required % ', from_currency_account_instance.amount, amount_param;
    END IF;
  END IF;

  SELECT * FROM currency_account
  WHERE app_entity_id = (SELECT id FROM app_entity WHERE pub_id = to_customer_id_param)
    AND currency_name = currency_instance.name
  INTO to_currency_account_instance;
  IF NOT FOUND THEN RAISE EXCEPTION 'to_currency_account_instance_not_found'; END IF;

  -- 1. journal header
  INSERT INTO transfer (type, amount, currency_name, details, external_reference_number, status)
  VALUES (type_param, amount_param, currency_instance.name, details_param, reference_param, 'COMPLETE')
  RETURNING * INTO transfer_instance;

  -- 2+3. DEBIT + CREDIT ledger entries in a single batched INSERT
  INSERT INTO transfer_ledger_entry (transfer_id, currency_account_id, entry_type, amount, resulting_balance)
  VALUES
    (transfer_instance.id, from_currency_account_instance.id, 'DEBIT', amount_param,
     (CASE WHEN from_customer_id_param = 'MASTER' THEN 0 ELSE from_currency_account_instance.amount - amount_param END)),
    (transfer_instance.id, to_currency_account_instance.id, 'CREDIT', amount_param,
     (CASE WHEN to_customer_id_param = 'MASTER' THEN 0 ELSE to_currency_account_instance.amount + amount_param END));

  -- 4. sender balance
  IF from_customer_id_param != 'MASTER' THEN
    UPDATE currency_account
    SET amount = from_currency_account_instance.amount - amount_param,
        amount_reserved = (CASE WHEN type_param IN ('INSTRUMENT_SELL'::transfer_type,'INSTRUMENT_BUY'::transfer_type)
                                THEN from_currency_account_instance.amount_reserved - amount_param
                                ELSE from_currency_account_instance.amount_reserved END),
        updated_at = current_timestamp
    WHERE id = from_currency_account_instance.id;
  END IF;
  -- 5. receiver balance
  IF to_customer_id_param != 'MASTER' THEN
    UPDATE currency_account
    SET amount = to_currency_account_instance.amount + amount_param, updated_at = current_timestamp
    WHERE id = to_currency_account_instance.id;
  END IF;

  RETURN transfer_instance.pub_id;
END;
$$;


-- ══ 00650_batch_orders.sql ══════════════════════════════════════════

-- Group-commit batch order submission.
--
-- Durable-settlement throughput is bound by the per-commit WAL fsync (see
-- TUNING.md): one submit_order = one transaction = one fsync. Processing N
-- orders for an instrument in ONE transaction amortizes that fsync over N
-- orders — a large throughput gain WITHOUT relaxing durability
-- (synchronous_commit stays on). The whole batch also takes the per-instrument
-- advisory lock once.
--
-- Trade-off to tune (see scripts/bench-batch.sh): a bigger batch raises
-- throughput but holds the instrument lock longer, so concurrent submitters on
-- the same symbol wait more — pick the batch size at the throughput/latency knee.
--
-- orders: jsonb array of {"type","side","price","amount","tif"}.
-- Returns the taker pub_ids in order. All-or-nothing: any order that raises
-- aborts the whole batch (one transaction).

create or replace function submit_orders(
    instrument_account_id_param text,
    instrument_name_param       text,
    orders                      jsonb
  )
  returns text[]
  language plpgsql
  security definer
  set search_path = public, pg_temp
as $$
declare
  iid  bigint;
  o    jsonb;
  ids  text[] := '{}';
begin
  if jsonb_typeof(orders) <> 'array' then
    raise exception 'orders must be a JSON array';
  end if;

  select id into iid from instrument where name = instrument_name_param;
  if iid is null then raise exception 'instrument_not_found: %', instrument_name_param; end if;

  perform pg_advisory_xact_lock(iid);   -- one lock for the whole batch

  for o in select value from jsonb_array_elements(orders) loop
    ids := ids || process_trade_order(
      instrument_account_id_param, instrument_name_param,
      o->>'type', (o->>'side')::order_side,
      nullif(o->>'price','')::numeric, (o->>'amount')::numeric,
      coalesce(o->>'tif','GTC'), 0);
  end loop;

  return ids;
end $$;

-- Like submit_order, this takes an explicit account id, so it is an operator /
-- market-maker tool on the service_role plane — NOT a self-scoped end-user RPC.
-- 9900_lockdown revokes execute from public/anon/authenticated on every function
-- and re-grants service_role, so we only need to lock out PUBLIC here; the
-- service_role grant is (re)applied by lockdown. End users place single orders
-- via the auth.uid()-scoped place_order; an auth-scoped place_orders could be
-- added later if per-user batching is needed.
revoke execute on function submit_orders(text,text,jsonb) from public;
grant  execute on function submit_orders(text,text,jsonb) to service_role;


-- ══ 00660_public_read.sql ══════════════════════════════════════════

-- Public market/reference data is readable by anyone (anon + authenticated).
--
-- Hosted Supabase enables RLS on public tables by default; locally RLS was off,
-- so these read fine locally but returned empty over the API on hosted. Make both
-- environments consistent: RLS ON + an explicit permissive SELECT policy, so the
-- order book / tape / instrument list are publicly readable either way (and the
-- Supabase linter stays happy — no RLS-disabled public tables).
--
-- Runs after 9640 (which recreates `trade` as partitioned) so the policy sticks.

do $$
declare t text;
begin
  foreach t in array array['price_level','trade','instrument','currency','fee'] loop
    execute format('alter table %I enable row level security', t);
    execute format('drop policy if exists public_read on %I', t);
    execute format('create policy public_read on %I for select to anon, authenticated using (true)', t);
  end loop;
end $$;


-- ══ 00670_lockdown.sql ══════════════════════════════════════════

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
