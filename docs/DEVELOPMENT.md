**English** · [中文](./DEVELOPMENT.zh-CN.md)

# pg-outcry

A pure-PostgreSQL central exchange (CEX) backend built on the Supabase stack:
**PostgREST** (API) + **Supabase Realtime** (market data / event push) +
**Supabase Auth / GoTrue** (identity). The matching engine is the PL/pgSQL core
of [tolyo/open-outcry](https://github.com/tolyo/open-outcry) — no Go service in
the request path.

## Goal (staged)

1. **Migrate the SQL matching engine** onto Supabase, driven by PostgREST + Realtime. ✅ *done — Stage 1*
2. Account balances / reservations / settlement / risk / market-data push.
3. Back-office / admin system.
4. Wallet (deposits & withdrawals).

See [`PERFORMANCE.md`](./PERFORMANCE.md) for the scaling plan (sharding, partitioning, async market data, WAL) and feature status.

## Layout

| Path | What |
|------|------|
| `web/` | OUTCRY terminal web app — WASM order book + OAuth2 + realtime (see `web/README.md`) |
| `engine/` | Vendored open-outcry SQL (goose format), `manifest.txt` = dependency order |
| `ext/oc_fastmath/` | Custom C extension (native banker's rounding, ~5.2× PL/pgSQL); `build.sh` builds+loads it |
| `scripts/gen-migrations.sh` | Regenerates `supabase/migrations/0*_engine_*.sql` from `engine/` |
| `supabase/migrations/0*_engine_*` | Generated engine schema + functions |
| `supabase/migrations/9000_grants_security_definer.sql` | Make engine fns `SECURITY DEFINER` + grant EXECUTE to API roles |
| `supabase/migrations/9001_realtime.sql` | Publish `trade` / `trade_order` / `book_order` to Realtime |
| `supabase/migrations/9002_seed_dev.sql` | Currencies, MASTER funding entity, instruments |
| `supabase/migrations/9003_api_helpers.sql` | Read grants + `find_instrument_account()` |
| `supabase/migrations/9100_stage2_concurrency_and_reads.sql` | Stage 2: `submit_order`/`submit_cancel` (per-instrument advisory lock) + read views |
| `supabase/migrations/9101_realtime_marketdata.sql` | Stage 2: publish L2 `price_level` to Realtime |
| `supabase/migrations/9200_auth_rls.sql` | Stage 3: GoTrue→`app_entity` trigger, `place_order`/`cancel_order`, RLS, view `security_invoker` |
| `supabase/migrations/9300_wallet.sql` | Stage 4: internal-ledger wallet (request/approve/reject deposit & withdrawal) |
| `supabase/migrations/9500_risk_controls.sql` | Per-instrument risk (max amount/notional/price-band) enforced in `place_order` |
| `supabase/migrations/9600_backoffice.sql` | Account status, admin RPCs (suspend/fee/risk), `admin_audit_log` |
| `supabase/migrations/9310_realtime_wallet.sql` | Publish `wallet_request` for the private feed |
| `supabase/migrations/9320_wallet_idempotency.sql` | Wallet idempotency keys |
| `supabase/migrations/9330_reconciliation.sql` | Append-only ledger + `reconcile()` report |
| `supabase/migrations/9700_platform.sql` | `statement_timeout` per role |
| `supabase/migrations/9710_wal_reduction.sql` | Replica identity DEFAULT on hot tables (less WAL) |
| `supabase/migrations/9640_cold_partitioning.sql` | Monthly RANGE partitions for trade + ledgers (+ pg_cron roll) |
| `supabase/migrations/9720_async_marketdata.sql` | Coalesced L2 + trade tape via realtime broadcast |
| `supabase/migrations/9750_perf_indexes.sql` | Partial index killing the per-trade stop-order seq scan |
| `supabase/migrations/9760_batch_settlement.sql` | Batched DEBIT+CREDIT ledger INSERT |
| `supabase/migrations/9730_hot_data.sql` | UNLOGGED book_order + price_level (in-memory) + `rebuild_book()` |
| `supabase/migrations/9900_lockdown.sql` | Deny-by-default on all engine functions; re-grant only the API whitelist (runs last) |
| `scripts/smoke-postgrest.sh` | Stage 1 engine test over HTTP `/rpc` (needs `SERVICE` key after lockdown) |
| `scripts/smoke-realtime.mjs` | Asserts a trade is broadcast over websocket |
| `scripts/smoke-stage2.sh` | Advisory-locked submit + read API (partial fill, settlement, reservation); needs `SERVICE` |
| `scripts/smoke-marketdata.mjs` | Asserts L2 `price_level` updates push over realtime |
| `scripts/smoke-stage3.sh` | GoTrue signup → auto account, JWT trading, RLS isolation, admin-only enforcement |
| `scripts/smoke-stage4.sh` | Wallet deposit/withdraw/reject ledger + reservations + admin-only |
| `scripts/smoke-stage5.sh` | Risk controls (band/limits) + back-office (suspend/fee/risk/audit) |
| `scripts/smoke-stage6.mjs` | Authenticated private realtime feed (own orders/fills/wallet, no leak) |
| `examples/private-feed.mjs` | Copy-paste frontend client for the private feed |
| `examples/md-ticker.mjs` | 100ms market-data ticker (flushes coalesced L2 broadcasts) |
| `scripts/smoke-stage7.sh` | Wallet idempotency + reconciliation report + append-only ledger |
| `scripts/smoke-stage8.sh` | Order types: MARKET / IOC / FOK execution + terminal status |
| `scripts/smoke-stage9.sh` | Stop orders: STOPLOSS→MARKET / STOPLIMIT→LIMIT trigger activation |

> The `9xxx_` grants/realtime/seed migrations are **Stage-1 convenience**: RLS is
> off and engine functions run as definer with no per-user scoping. Stage 3
> replaces this with Auth-backed RLS.

## Run it

```bash
supabase start                 # Postgres + PostgREST + Realtime + Auth (docker)
supabase db reset              # apply all migrations from scratch

export ANON="$(supabase status -o json | jq -r .ANON_KEY)"
export SERVICE="$(supabase status -o json | jq -r .SERVICE_ROLE_KEY)"

# Stage 1/2 — engine at the admin plane (service_role, since engine RPCs are locked down)
./scripts/smoke-postgrest.sh
./scripts/smoke-stage2.sh

# Realtime
npm i @supabase/supabase-js
node scripts/smoke-realtime.mjs
node scripts/smoke-marketdata.mjs

# Stage 3/4 — real GoTrue signup, JWT trading, RLS, wallet
./scripts/smoke-stage3.sh
./scripts/smoke-stage4.sh

# Risk controls + back-office admin (suspend / fees / risk / audit)
./scripts/smoke-stage5.sh
```

## Roles & security model

- **anon** — public market data only (`price_level`, `trade`, `instrument`, `currency` via table SELECT). No RPCs.
- **authenticated** (user JWT) — self-scoped API: `place_order`, `cancel_order`, `request_deposit`, `request_withdrawal`, `current_app_entity_*`. RLS limits all reads to the caller's own entity.
- **service_role** (back-office) — full engine + admin RPCs (`process_transfer`, `approve_wallet_request`, …); bypasses RLS.
- `9900_lockdown.sql` revokes EXECUTE on every engine function from public/anon/authenticated and re-grants only the whitelist, so internal helpers (`create_trade`, `update_price_level`, …) are unreachable by clients. It runs last so it also covers functions added by later migrations.

## Realtime feeds

- **Public market data** (no auth): subscribe to **Broadcast** on channel `md:<symbol>` — events `l2` (coalesced order book, flushed by `examples/md-ticker.mjs` every 100ms) and `trade` (tape, pushed per trade). `price_level`/`trade` are partitioned and no longer on Postgres Changes.
- **Private per-user feed** (auth): call `supabase.realtime.setAuth(jwt)`, then subscribe to `trade_order` (order lifecycle + fills) and `wallet_request` (deposit/withdrawal status). Realtime evaluates each table's RLS per subscriber, so a client receives **only its own rows** — no topic/userId wiring, no server relay. See `examples/private-feed.mjs`. Both maker and taker receive their own `FILLED` updates; cross-user leakage is impossible because the `own_orders` / `own_wallet_requests` policies filter delivery.

## Engine API notes (learned the hard way)

- `create_client(external_id)` returns the **app_entity `pub_id` (UUID)**, not the
  external id. Every other function keys off `pub_id`. `MASTER` is the one entity
  with a literal pub_id (`'MASTER'`).
- `create_client` only opens an **EUR** currency account; open others with
  `create_currency_account(pub_id, currency)`.
- Fund via `process_transfer('DEPOSIT','MASTER', amount, currency, to_pub_id, ref, details, fee_type)`.
  Pass `fee_type=null` to skip fees (no fee rows are seeded).
- `process_trade_order`: `amount_param` is the **base quantity for both sides**;
  a BUY reserves `amount * price` in the quote currency. (The Go doc comment
  saying "BUY amount is in quote currency" is misleading.)
- **MARKET orders** use `price = 0` as a sentinel (NOT null — `trade_order.price` is
  NOT NULL; the engine itself sets `price=0` when converting a stop to market). Supported
  order types: `LIMIT / MARKET / STOPLOSS / STOPLIMIT`; TIF: `GTC / IOC / FOK / GTD / GTT`.
- MARKET fills report terminal status `PARTIALLY_FILLED` even when fully executed, due to
  the engine's base/quote `open_amount` accounting — they still produce correct trades.
