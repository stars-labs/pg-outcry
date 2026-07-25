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
