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
| `supabase/migrations/00430_grants_security_definer.sql` | Make engine fns `SECURITY DEFINER` + grant EXECUTE to API roles |
| `supabase/migrations/00440_realtime.sql` | Publish `trade` / `trade_order` / `book_order` to Realtime |
| `supabase/migrations/00450_seed_dev.sql` | Currencies, MASTER funding entity, instruments |
| `supabase/migrations/00460_api_helpers.sql` | Read grants + `find_instrument_account()` |
| `supabase/migrations/00470_stage2_concurrency_and_reads.sql` | Stage 2: `submit_order`/`submit_cancel` (per-instrument advisory lock) + read views |
| `supabase/migrations/00480_realtime_marketdata.sql` | Stage 2: publish L2 `price_level` to Realtime |
| `supabase/migrations/00490_auth_rls.sql` | Stage 3: GoTrue→`app_entity` trigger, `place_order`/`cancel_order`, RLS, view `security_invoker` |
| `supabase/migrations/00500_wallet.sql` | Stage 4: internal-ledger wallet (request/approve/reject deposit & withdrawal) |
| `supabase/migrations/00520_risk_controls.sql` | Per-instrument risk (max amount/notional/price-band) enforced in `place_order` |
| `supabase/migrations/00550_backoffice.sql` | Account status, admin RPCs (suspend/fee/risk), `admin_audit_log` |
| `supabase/migrations/00510_realtime_wallet.sql` | Publish `wallet_request` for the private feed |
| `supabase/migrations/00560_wallet_idempotency.sql` | Wallet idempotency keys |
| `supabase/migrations/00570_reconciliation.sql` | Append-only ledger + `reconcile()` report |
| `supabase/migrations/00590_platform.sql` | `statement_timeout` per role |
| `supabase/migrations/00600_wal_reduction.sql` | Replica identity DEFAULT on hot tables (less WAL) |
| `supabase/migrations/00580_cold_partitioning.sql` | Monthly RANGE partitions for trade + ledgers (+ pg_cron roll) |
| `supabase/migrations/00610_async_marketdata.sql` | Coalesced L2 + trade tape via realtime broadcast |
| `supabase/migrations/00630_perf_indexes.sql` | Partial index killing the per-trade stop-order seq scan |
| `supabase/migrations/00640_batch_settlement.sql` | Batched DEBIT+CREDIT ledger INSERT |
| `supabase/migrations/00620_hot_data.sql` | UNLOGGED book_order + price_level (in-memory) + `rebuild_book()` |
| `supabase/migrations/00670_lockdown.sql` | Deny-by-default on all engine functions; re-grant only the API whitelist (later migrations grant their own RPCs) |
| `supabase/migrations/00680_api_keys.sql` | Per-user API keys + in-DB JWT minting (`api_key_login`) |
| `supabase/migrations/00690_referral.sql` | Referral codes, one-time attribution, taker-commission accrual |
| `supabase/migrations/00700_withdrawal_whitelist.sql` | Withdrawal address allow-list + rolling per-window limits |
| `supabase/migrations/00710_chain_deposits.sql` | Chain/asset/watched-address tables + idempotent `credit_chain_deposit` |
| `supabase/migrations/00720_withdrawal_queue.sql` | DB-owned send queue (`SKIP LOCKED` claim → broadcast → confirm) |
| `supabase/migrations/00730_staking.sql` | Staking pools, lazy reward accrual, pgmq-backed unbonding |
| `supabase/migrations/00740_margin.sql` | Cross-margin borrow/repay + `pg_cron` liquidation checks |
| `supabase/migrations/00750_perp.sql` | Linear perpetuals: mark price, funding, liquidation |
| `supabase/migrations/00760_grant_banker_round.sql` | Grant `banker_round` + RLS policies on `stake_pool`/`perp_market` |
| `supabase/migrations/00770_ohlcv.sql` | Server-side OHLCV candles RPC (`date_bin` buckets, guardrailed) |
| `supabase/migrations/00780_crypto_secp256k1_keccak.sql` | Pure-PL/pgSQL keccak256 + secp256k1 (RFC6979) + `evm_address` |
| `supabase/migrations/00790_admin_derivatives_controls.sql` | Admin RPCs for stake pools / margin terms / perp markets |
| `supabase/migrations/00800_admin_wallet_chain_api_ops.sql` | Admin RPCs for chain config, chain assets, API-key revocation |
| `supabase/migrations/00810_hd_custody.sql` | Vault master seed → per-user EVM/Tron/Solana deposit addresses |
| `supabase/migrations/00820_chain_balance_poller.sql` | In-DB balance-delta deposit pollers (`http` + `pg_cron`) |
| `supabase/migrations/00830_evm_withdrawal_signer.sql` | In-DB RLP/EIP-155 build + sign + broadcast for EVM |
| `supabase/migrations/00840_solana_tron_withdrawal.sql` | In-DB Solana wire + Tron txID signing/broadcast |
| `supabase/migrations/00850_token_assets_tron_trc20.sql` | USDT/USDC currencies + TRC-20 transfer signing |
| `supabase/migrations/00860_hybrid_memo_deposits.sql` | Hybrid addressing: derived (EVM) vs shared-address+memo (Tron/Solana) |
| `supabase/migrations/00870_reconcile_monitor.sql` | `run_reconcile_monitor()` records invariant breaks → `reconcile_alert` (cron 5min) |
| `supabase/migrations/00880_candle_cache.sql` | Persistent `candle_1m` + incremental `refresh_candle_1m()` (cron 1min) |
| `supabase/migrations/00890_admin_rbac.sql` | Back-office RBAC tables, audited admin RPCs, chain-backed funding enforcement |
| `supabase/migrations/00900_stablecoin_tokens.sql` | ERC-20/SPL signing, token deposit detection, explicit RLS policies |
| `supabase/migrations/00910_chain_backed_funding_reconcile.sql` | Custody reconciliation + reversal of unbacked customer funding |
| `supabase/migrations/00920_ohlcv_from_cache.sql` | `ohlcv()` serves from `candle_1m` (cached history + live tail) |
| `supabase/migrations/00930_admin_rbac_switch.sql` | `admin_config.open_access` — flip the demo-open console to real RBAC |
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
- **authenticated** (user JWT) — self-scoped API: `place_order`, `cancel_order`, `my_deposit_address`, `request_withdrawal`, `current_app_entity_*`. RLS limits all reads to the caller's own entity.
- **authenticated operator** (user JWT) — the current hosted test build grants every signed-in user full back-office permissions. `admin_operator_role` / `admin_role_permission` remain available for later tightening across approvals, accounts, market/risk, derivatives, security, and audit.
- **service_role** — server-side root for CI, trusted jobs, bootstrap, and raw engine operations; never required by the browser back-office.
- `00670_lockdown.sql` revokes EXECUTE on every engine function from public/anon/authenticated and re-grants only the whitelist, so internal helpers (`create_trade`, `update_price_level`, …) are unreachable by clients. Later migrations explicitly revoke/grant their own new RPCs.

## Realtime feeds

- **Public market data** (no auth): subscribe to **Broadcast** on channel `md:<symbol>` — events `l2` (coalesced order book, flushed by `examples/md-ticker.mjs` every 100ms) and `trade` (tape, pushed per trade). `price_level`/`trade` are partitioned and no longer on Postgres Changes.
- **Private per-user feed** (auth): call `supabase.realtime.setAuth(jwt)`, then subscribe to `trade_order` (order lifecycle + fills) and `wallet_request` (deposit/withdrawal status). Realtime evaluates each table's RLS per subscriber, so a client receives **only its own rows** — no topic/userId wiring, no server relay. See `examples/private-feed.mjs`. Both maker and taker receive their own `FILLED` updates; cross-user leakage is impossible because the `own_orders` / `own_wallet_requests` policies filter delivery.

## Engine API notes (learned the hard way)

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
