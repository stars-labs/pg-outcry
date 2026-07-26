**English** · [中文](./DEVELOPMENT.zh-CN.md)

# pg-outcry

A pure-PostgreSQL central exchange (CEX) backend built on the Supabase stack:
**PostgREST** (API) + **Supabase Realtime** (market data / event push) +
**Supabase Auth / GoTrue** (identity). The matching engine is the PL/pgSQL core
of [tolyo/open-outcry](https://github.com/tolyo/open-outcry) — no Go service in
the request path.

### Goal (staged)

1. **Migrate the SQL matching engine** onto Supabase, driven by PostgREST + Realtime. ✅ *done — Stage 1*
2. Account balances / reservations / settlement / risk / market-data push.
3. Back-office / admin system.
4. Wallet (deposits & withdrawals).

See [`PERFORMANCE.md`](./PERFORMANCE.md) for the scaling plan (sharding, partitioning, async market data, WAL) and feature status.

### Layout

| Path | What |
|------|------|
| `web/` | OUTCRY terminal web app — WASM order book + OAuth2 + realtime (see `web/README.md`) |
| `engine/` | Vendored open-outcry SQL (goose format), `manifest.txt` = dependency order |
| `ext/oc_fastmath/` | Custom C extension (native banker's rounding, ~5.2× PL/pgSQL); `build.sh` builds+loads it |
| `supabase/migrations/00010_engine.sql` | Generated from `engine/` (vendored open-outcry): core schema + matching/settlement functions |
| `supabase/migrations/00020_platform_base.sql` | `SECURITY DEFINER` grants, Realtime publication, seed data (currencies/MASTER/instruments), read views + `submit_order` |
| `supabase/migrations/00030_auth_wallet_risk.sql` | GoTrue→`app_entity` trigger, RLS, `place_order`/`cancel_order`, internal wallet, pre-trade risk, back-office basics, wallet idempotency |
| `supabase/migrations/00040_ledger_perf_lockdown.sql` | Append-only ledger + `reconcile()`, monthly partitions, async market data, UNLOGGED hot book, perf indexes, batch settlement, deny-by-default lockdown |
| `supabase/migrations/00050_features_crypto.sql` | API keys, referral, withdrawal whitelist, chain deposits + send queue, staking/margin/perps, OHLCV, pure-PL/pgSQL secp256k1+keccak256 |
| `supabase/migrations/00060_custody_chain.sql` | Admin product/chain RPCs, HD custody from a vault seed, balance pollers, in-DB EVM/Tron/Solana signing + broadcast, TRC-20, hybrid memo deposits |
| `supabase/migrations/00070_backoffice_rbac.sql` | Reconcile monitor, 1m candle cache, back-office RBAC + audit, ERC-20/SPL tokens, chain-backed funding enforcement, RBAC config switch |
| `scripts/smoke-postgrest.sh` | Stage 1 engine test over HTTP `/rpc` (needs `SERVICE` key after lockdown) |
| `scripts/smoke-realtime.mjs` | Asserts a trade is broadcast over websocket |
| `scripts/smoke-stage2.sh` | Advisory-locked submit + read API (partial fill, settlement, reservation); needs `SERVICE` |
| `scripts/smoke-marketdata.mjs` | Asserts L2 `price_level` updates push over realtime |
| `scripts/smoke-stage3.sh` | GoTrue signup → auto account, JWT trading, RLS isolation, API whitelist enforcement |
| `scripts/smoke-stage4.sh` | Chain deposit funding + wallet withdraw/reject ledger + reservations + test-open admin access |
| `scripts/smoke-stage5.sh` | Risk controls (band/limits) + back-office (suspend/fee/risk/audit) |
| `scripts/smoke-stage6.mjs` | Authenticated private realtime feed (own orders/fills/wallet, no leak) |
| `examples/private-feed.mjs` | Copy-paste frontend client for the private feed |
| `examples/md-ticker.mjs` | 100ms market-data ticker (flushes coalesced L2 broadcasts) |
| `scripts/smoke-stage7.sh` | Chain deposit idempotency + wallet idempotency + core/custody reconciliation + append-only ledger |
| `scripts/smoke-stage8.sh` | Order types: MARKET / IOC / FOK execution + terminal status |
| `scripts/smoke-stage9.sh` | Stop orders: STOPLOSS→MARKET / STOPLIMIT→LIMIT trigger activation |

> The `9xxx_` grants/realtime/seed migrations are **Stage-1 convenience**: RLS is
> off and engine functions run as definer with no per-user scoping. Stage 3
> replaces this with Auth-backed RLS.

### Run it

```bash
supabase start                 # Postgres + PostgREST + Realtime + Auth (docker)
supabase db reset              # apply all migrations from scratch

export ANON="$(supabase status -o json | jq -r .ANON_KEY)"
export SERVICE="$(supabase status -o json | jq -r .SERVICE_ROLE_KEY)"

## Stage 1/2 — engine at the admin plane (service_role, since engine RPCs are locked down)
./scripts/smoke-postgrest.sh
./scripts/smoke-stage2.sh

## Realtime
npm i @supabase/supabase-js
node scripts/smoke-realtime.mjs
node scripts/smoke-marketdata.mjs

## Stage 3/4 — real GoTrue signup, JWT trading, RLS, wallet
./scripts/smoke-stage3.sh
./scripts/smoke-stage4.sh

## Risk controls + back-office admin (suspend / fees / risk / audit)
./scripts/smoke-stage5.sh
```

### Roles & security model

- **anon** — public market data only (`price_level`, `trade`, `instrument`, `currency` via table SELECT). No RPCs.
- **authenticated** (user JWT) — self-scoped API: `place_order`, `cancel_order`, `my_deposit_address`, `request_withdrawal`, `current_app_entity_*`. RLS limits all reads to the caller's own entity.
- **authenticated operator** (user JWT) — the current hosted test build grants every signed-in user full back-office permissions. `admin_operator_role` / `admin_role_permission` remain available for later tightening across approvals, accounts, market/risk, derivatives, security, and audit.
- **service_role** — server-side root for CI, trusted jobs, bootstrap, and raw engine operations; never required by the browser back-office.
- `00040_ledger_perf_lockdown.sql` revokes EXECUTE on every engine function from public/anon/authenticated and re-grants only the whitelist, so internal helpers (`create_trade`, `update_price_level`, …) are unreachable by clients. Later migrations explicitly revoke/grant their own new RPCs.

### Realtime feeds

- **Public market data** (no auth): subscribe to **Broadcast** on channel `md:<symbol>` — events `l2` (coalesced order book, flushed by `examples/md-ticker.mjs` every 100ms) and `trade` (tape, pushed per trade). `price_level`/`trade` are partitioned and no longer on Postgres Changes.
- **Private per-user feed** (auth): call `supabase.realtime.setAuth(jwt)`, then subscribe to `trade_order` (order lifecycle + fills) and `wallet_request` (deposit/withdrawal status). Realtime evaluates each table's RLS per subscriber, so a client receives **only its own rows** — no topic/userId wiring, no server relay. See `examples/private-feed.mjs`. Both maker and taker receive their own `FILLED` updates; cross-user leakage is impossible because the `own_orders` / `own_wallet_requests` policies filter delivery.

### Engine API notes (learned the hard way)

- `create_client(external_id)` returns the **app_entity `pub_id` (UUID)**, not the
  external id. Every other function keys off `pub_id`. `MASTER` is the one entity
  with a literal pub_id (`'MASTER'`).
- `create_client` only opens an **EUR** currency account; open others with
  `create_currency_account(pub_id, currency)`.
- Fund customer accounts through the chain deposit path (`my_deposit_address` + watcher, or service-role `credit_chain_deposit` for deterministic tests).
- Direct `process_transfer('DEPOSIT','MASTER', ...)` remains available to service-role seeds/benchmarks, but custody reconciliation reports it as unbacked customer funding unless it is an internal product movement.
  Pass `fee_type=null` to skip fees (no fee rows are seeded).
- `process_trade_order`: `amount_param` is the **base quantity for both sides**;
  a BUY reserves `amount * price` in the quote currency. (The Go doc comment
  saying "BUY amount is in quote currency" is misleading.)
- **MARKET orders** use `price = 0` as a sentinel (NOT null — `trade_order.price` is
  NOT NULL; the engine itself sets `price=0` when converting a stop to market). Supported
  order types: `LIMIT / MARKET / STOPLOSS / STOPLIMIT`; TIF: `GTC / IOC / FOK / GTD / GTT`.
- MARKET fills report terminal status `PARTIALLY_FILLED` even when fully executed, due to
  the engine's base/quote `open_amount` accounting — they still produce correct trades.

---

## Migration numbering

All migrations use a **5-digit, fixed-width, step-10 numeric prefix**:
`00010_`, `00020_` … `00930_`.

```
supabase/migrations/00010_engine.sql
supabase/migrations/00010_engine.sql
...
supabase/migrations/00070_backoffice_rbac.sql
```

### Why fixed-width

The Supabase CLI applies migrations in **lexical filename order**, and takes the
digits before the first `_` as the migration **version** (the `schema_migrations`
primary key). Two consequences bit us repeatedly under the old mixed-width scheme:

- **Lexical ≠ numeric when widths differ.** `'9' (0x39) < '_' (0x5F)`, so
  `99999_admin_rbac.sql` sorted *before* `9999_stablecoin_tokens.sql`, and
  `100000_…` sorted near the *front* (`'1' < '9'`) rather than the end.
- **Versions must be unique.** `9999_a.sql` and `9999_b.sql` both parse to version
  `9999` and collide on the `schema_migrations` primary key, breaking
  `db reset` / `db push`.
- **Prefixes must be numeric.** A letter prefix (`A001_…`) is silently **skipped**
  by the CLI — the migration never runs, with no error.

With every prefix the same width, lexical order *is* numeric order, and the
ordering surprises disappear.

### Adding a migration

- **Append**: next multiple of 10 after the current last file.
- **Insert between two migrations**: use a spare number in the gap (e.g. `00565_`
  between `00560_` and `00570_`). The step-10 spacing exists for exactly this.
- Never reuse a number, and never change the prefix of a migration that has
  already been applied to a deployed database (see below).

### Renumbering an already-deployed database

Renaming a migration file changes its **version**, so the CLI would treat it as
new and try to re-apply it. Several migrations are destructive on replay (e.g.
`00040_ledger_perf_lockdown.sql` does `drop table if exists trade cascade`), so a
blind re-apply **loses data**.

The safe procedure is to rewrite the recorded versions instead of re-running
anything:

```sql
-- inside a transaction, map every old version string to the new one
update supabase_migrations.schema_migrations set version = '00010' where version = '0001';
...
```

Local/CI databases are disposable — just `supabase db reset`.

---

## Row-Level Security model & conventions

How pg-outcry secures table access, why RLS is **declarative** in migrations, and the CI guard
that stops the recurring "auto-RLS" footgun. [← docs](./README.md) · [← Development](./DEVELOPMENT.md)

### The model: deny-by-default, access via the API surface

Users never touch base tables directly. Everything a client does goes through:

- **`SECURITY DEFINER` RPCs** — `place_order`, `request_withdrawal_to`, `stake`, `my_deposit_address`,
  … They run as the owner, do their own authorization (`current_app_entity_id()`), and bypass RLS.
- **A small set of views** granted to `anon` / `authenticated`.

`00040_ledger_perf_lockdown.sql` revokes `EXECUTE` on every function from `anon`/`authenticated` and re-grants only
the whitelisted RPCs. Tables follow the same spirit: **RLS on, deny-by-default**, opened only where a
client genuinely needs to read.

### Three table classes

| Class | Examples | Policy |
|---|---|---|
| **Public reference / params** | `instrument`, `currency`, `fee`, `price_level`, `stake_pool`, `perp_market`, `margin_config`, `stake_config`, `referral_config`, `instrument_risk`, `withdrawal_limit` | `SELECT … USING (true)` to `anon, authenticated` — non-sensitive market/exchange parameters |
| **Per-user data** | `currency_account`, `trade_order`, `wallet_request`, `watched_address`, `withdrawal_address`, `user_chain_wallet`, `stake_position`, `perp_position`, `margin_loan`, `api_key`, `chain_deposit`, `perp_event`, `margin_liquidation` | `SELECT … USING (app_entity_id = current_app_entity_id())` (or an equivalent owner check, e.g. memo `'oc' || current_app_entity_id()` for `chain_deposit`) |
| **Financial / ledger / engine-internal** | `transfer`, `*_ledger_entry_*`, `book_order`, `admin_audit_log`, `chain_cursor`, `chain_balance_cursor`, `trade` partitions, `stop_order`, `instrument_account_transfer` | **RLS on, no policy = deny-by-default.** Correct and intentional — clients reach these only via `SECURITY DEFINER` RPCs/views. Do **not** add a policy. |

### The crux: `security_invoker` vs `SECURITY DEFINER` views

- A **`SECURITY DEFINER`** view (the Postgres default) runs as its owner and **bypasses RLS** on its base
  tables. `margin_terms`, `perp_markets`, `stake_pools`, `referral_summary`, `reconciliation_report` are
  definer views — they read config/internal tables without needing policies.
- A **`security_invoker = on`** view runs as the **caller**, so RLS on its base tables **applies**. All the
  per-user views are invoker views: `cash_balances`, `my_stakes`, `my_perp`, `my_margin`,
  `my_chain_deposits`, `my_deposit_addresses`, `withdrawal_addresses`, `open_orders`, `order_book_l2`,
  `trade_history`, `instrument_balances`, `api_keys`.

> **An invoker view that reads a table with RLS enabled but _zero policies_ silently returns nothing.**

### The footgun: Supabase auto-enables RLS

Supabase's security advisor enables RLS on public tables **out-of-band** (not via our migrations). If that
hits a table an invoker view reads and we never wrote a policy, the feature breaks on hosted while CI
(a fresh local DB, where RLS was never auto-enabled) stays green. We hit this on `stake_pool`,
`perp_market`, and `chain_deposit`.

**Rule: make RLS declarative.** In the migration that creates a table, both `ENABLE ROW LEVEL SECURITY`
**and** add its policy (or deliberately leave it deny-by-default for internal tables). Then a fresh DB
== hosted, and Supabase's auto-toggle changes nothing.

```sql
alter table stake_pool enable row level security;          -- match what hosted will do anyway
create policy read_stake_pool on stake_pool
  for select to anon, authenticated using (true);          -- … and the intended policy
```

### The CI guard

`scripts/check-rls-policies.sh` (run in `ci.yml` right after migrations apply) walks every
`security_invoker` view granted to `anon`/`authenticated`, resolves its base tables via
`pg_depend`/`pg_rewrite`, and **fails** if any base table is RLS-enabled-with-no-policy — printing the
offending `view -> table` pairs. It ignores the deny-by-default internal tables (no invoker view reads
them), so it never forces a wrong policy. Run it anywhere:

```bash
PGURL=postgresql://user:pass@host:5432/db bash scripts/check-rls-policies.sh
```

### Checklist when adding a table or view

1. Creating a table read by clients? `ENABLE ROW LEVEL SECURITY` + add the right policy in the same
   migration (public-read or own-row). Internal/ledger table? Enable RLS, no policy.
2. Need a per-user view? Make it `security_invoker = on` and ensure every base table has an own-row (or
   public-read) policy. Need to expose aggregated/internal data safely? Use a `SECURITY DEFINER` view.
3. Numbered `> 9900` so `9900_lockdown` has already run before your grants.
4. `bash scripts/check-rls-policies.sh` locally — green before pushing.

### Self-host reuses all of it

Everything here is plain SQL migrations applied by `supabase db reset` (or `supabase db push`), so a
self-hosted Postgres gets the identical RLS posture — no hosted-only steps. The CI guard runs against any
`PGURL`. The one hosted-specific behavior (Supabase auto-enabling RLS) is precisely what the declarative
approach neutralizes, so local, CI, and hosted stay in lockstep. See [DEPLOY.md](./DEPLOY.md).

#### Recently added tables

| Table | Class | Policy |
|---|---|---|
| `candle_1m` | public market data | `select` to `anon, authenticated` using `true` |
| `reconcile_alert` | operator evidence | `select` to `authenticated` using `true` (writes are service_role only) |
| `admin_config` | operator config | `select` to `authenticated`; writes go through `admin_set_open_access()` |

---

[← Back to docs](./README.md) · [← Project README](../README.md)
