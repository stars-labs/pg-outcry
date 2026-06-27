<div align="center">

**English** · [中文](./README.zh-CN.md)

# pg-outcry · OUTCRY

**A complete central exchange (CEX), running entirely inside PostgreSQL.**

Matching · Settlement · Wallet · Risk · Realtime · Auth — **no application server in the request path.**

`PostgreSQL` · `PostgREST` · `Supabase Realtime` · `Supabase Auth (GoTrue)` · `WebAssembly`

[![ci](https://github.com/xiongchenyu6/pg-outcry/actions/workflows/ci.yml/badge.svg)](https://github.com/xiongchenyu6/pg-outcry/actions/workflows/ci.yml) [![license: AGPL-3.0](https://img.shields.io/badge/license-AGPL--3.0-4ef7a8)](./LICENSE)

> ⚠️ **Reference / educational software — not independently audited.** Don't custody real funds without your own audit & compliance review. See [SECURITY.md](./SECURITY.md).

**[▶ Live demo — trading terminal](https://xiongchenyu6.github.io/pg-outcry/?api=https://axtziasfallmdgssbgsl.supabase.co&anon=sb_publishable_j1Jr-NMeKb_P29JcBRhz6Q_0ZkbVzUc&demo=1)** — real hosted backend. Sign up (instant), click **💰 Demo funds**, and trade against a live order book.

**[▶ Live demo — back-office](https://xiongchenyu6.github.io/pg-outcry/admin.html?api=https://axtziasfallmdgssbgsl.supabase.co&anon=sb_publishable_j1Jr-NMeKb_P29JcBRhz6Q_0ZkbVzUc&demo=1)** — read-only admin console: reconciliation invariants, approvals queue, accounts, and audit log on the same live data.

**[★ Why pg-outcry — comparison vs top-tier exchanges & the SMB advantage (diagrams)](./WHY.md)**

[Quickstart](#quickstart) · [Deploy](./DEPLOY.md) · [Benchmark](./BENCH.md) · [Tuning ladder](./TUNING.md) · [Performance](./PERFORMANCE.md) · [Dev](./DEVELOPMENT.md)

<img src="web/docs/hero.png" alt="OUTCRY terminal — order book, candlesticks with SMA/EMA/Bollinger/VWAP, volume, RSI (rendered from the live WASM engine)" width="100%"/>

<sub>↑ the OUTCRY terminal — order book + candlesticks (SMA/EMA/Bollinger/VWAP) + volume + RSI, rendered from the real WASM engine & live data.</sub>

<details><summary><b>Back-office console</b> (approvals · reconciliation · accounts · audit)</summary>

<img src="web/docs/admin.png" alt="OUTCRY back-office — wallet approvals, reconciliation invariants (all PASS), accounts, admin audit log" width="100%"/>

</details>

</div>

---

## What is this?

The matching engine is ~2,400 lines of **PL/pgSQL** (built on [tolyo/open-outcry](https://github.com/tolyo/open-outcry)).
Everything a trader or operator touches is a **PostgREST RPC**, a **Supabase Realtime** channel, or a **Supabase Auth** session.
There is no Go/Java/Rust order-matching service, no Kafka, no Redis, no separate ledger microservice — the database *is* the exchange.

```mermaid
flowchart LR
  subgraph Client["Browser — OUTCRY terminal (WASM)"]
    UI["Trading UI · Admin console"]
  end
  subgraph Supabase["Supabase / pure PostgreSQL"]
    PR["PostgREST<br/>RPC + views"]
    RT["Realtime<br/>broadcast + RLS feed"]
    AU["Auth / GoTrue<br/>OAuth2 + JWT"]
    PG["PostgreSQL<br/>PL/pgSQL matching · double-entry ledger · RLS"]
    PR --> PG
    RT --- PG
    AU --- PG
  end
  UI -->|"/rpc place_order"| PR
  UI -->|"md:&lt;symbol&gt; · private feed"| RT
  UI -->|"login"| AU
```

## Why this design wins

| | Conventional CEX stack | **pg-outcry** |
|---|---|---|
| Matching engine | bespoke C++/Java service | PL/pgSQL inside the DB |
| Settlement | separate ledger service, eventual consistency | **same ACID transaction** as the match |
| Market data | Kafka → fan-out service → WS gateway | Supabase Realtime (broadcast + RLS feed) |
| Per-user security | hand-rolled authz layer | **Postgres RLS** (zero custom authz code) |
| Moving parts | 5–15 services + brokers + caches | **one database + Supabase** |
| Ops team to run it | a platoon | **one or two engineers** |

```mermaid
flowchart LR
  subgraph T["Top-tier: ~10–15 systems to run"]
    direction TB
    t1[gateways] --- t2[matching C++] --- t3[Kafka] --- t4[ledger svc]
    t5[risk svc] --- t6[wallet svc] --- t7[Redis] --- t8[WS fanout] --- t9[OLTP]
  end
  subgraph O["pg-outcry: 1 DB + managed Supabase"]
    o1[(PostgreSQL)] --- o2[PostgREST] --- o3[Realtime] --- o4[Auth]
  end
```

- **Correct by construction.** Order match *and* full double-entry settlement happen in **one database transaction** — no cross-service synchronization, no "trade booked but ledger lagged" class of bugs.
- **Auditable money.** The ledger is **append-only** (triggers reject UPDATE/DELETE) and a built-in `reconcile()` continuously checks 5 invariants (cash == ledger, double-entry balanced, reservations sane, every approved wallet op has a settlement transfer, issuance conserved). Every admin action is written to an audit log.
- **Realtime included.** Public market data streams over Broadcast (`md:<symbol>`: coalesced L2 + trade tape); each user's order/fill/wallet stream rides Postgres Changes **scoped by RLS** — a user receives only their own rows, with no relay server and no per-user topic wiring.
- **Secure by default.** Identity is Supabase Auth (OAuth2 + email); data isolation is Postgres RLS. Engine internals are locked down (`deny-by-default`, only a whitelist of RPCs is callable).
- **Deploys two ways from one codebase.** Push to **hosted Supabase** for a demo, or **self-host** for a high-performance build (UNLOGGED hot book, native C hot-path, WAL tuning). Privileged migration steps self-skip on hosted.
- **Batteries included.** A polished **WASM trading terminal** (candles + volume + SMA/EMA/Bollinger/VWAP/VMA + RSI/MACD/KDJ/ATR + drawing tools, all computed in WebAssembly) **and** a **back-office console** (approvals, suspensions, fees, risk, reconciliation, audit) ship in this repo.

## Why it's a perfect fit for small & mid-size exchanges

Big exchanges can afford a bespoke C++ matching engine and a 50-person platform team. **Small and mid-size exchanges cannot — and that's exactly who this is for.**

1. **Tiny operational footprint = tiny cost.** One PostgreSQL plus Supabase's managed services. No brokers, no caches, no service mesh. It can run on a modest managed Supabase project or a single VM. A 1–2 person team can operate the whole exchange.
2. **Launch in days, not quarters.** `supabase db reset` applies the schema; open the included terminal and admin console. You start with a *working* exchange, not a pile of microservices to integrate.
3. **Exchange-grade correctness you didn't have to build.** Double-entry ledger, fund reservations/freezes, idempotent deposits/withdrawals, reconciliation invariants, append-only audit trail, per-user RLS — the financial-integrity work that sinks small teams is already done and tested.
4. **Compliance & trust scaffolding out of the box.** Append-only ledger + reconciliation + admin audit log + account suspension + per-instrument risk limits (price bands, max order size/notional) give you the controls auditors and partners ask about.
5. **Cost scales with you.** Start on hosted Supabase; when volume grows, self-host and turn on the performance profile, or shard by symbol across nodes (documented, zero schema change — a CEX has no cross-symbol transactions).
6. **No lock-in, fully inspectable.** The matching and settlement logic is plain SQL you can read, fork, and audit. No black-box engine binary.

> In short: **the correctness, realtime, and compliance of a serious exchange — at the operational complexity and cost a small team can actually carry.**

> 📊 **Deep dive with diagrams:** see **[WHY.md](./WHY.md)** for the side-by-side architecture, order-lifecycle and consistency comparisons against a top-tier-exchange stack, the moving-parts/cost analysis, and the full scaling path.

## Feature set

- **Engine:** limit / market / stop-loss / stop-limit orders; GTC / IOC / FOK; self-trade prevention; maker/taker fees; price-time priority.
- **Settlement:** double-entry ledger, fund reservation/freeze, multi-currency + FX instruments, banker's rounding.
- **Wallet:** deposit/withdrawal requests with admin approval, idempotency keys, reservation on withdrawal.
- **Risk:** per-instrument max order amount / notional / price-band (fat-finger) checks.
- **Realtime:** public L2 + trade broadcast; private RLS-scoped order/fill/wallet feed.
- **Auth & security:** OAuth2 (GitHub/Google) + email; full RLS; deny-by-default function surface.
- **Back-office:** approvals queue, suspend/unsuspend, fee & risk config, reconciliation dashboard, audit log.
- **Frontend:** "phosphor terminal" WASM trading UI + admin console.
- **Performance:** per-symbol advisory-lock concurrency, monthly partitioning of trade/ledger, UNLOGGED in-memory book, WAL reduction, coalesced async market data, optional native C extension.

## Verified

The repo ships smoke tests covering **11 end-to-end flows** — matching, settlement & reservations, realtime tape + L2 broadcast, Auth+RLS isolation, wallet (idempotency + reconciliation), order types, stop-order activation, and the private feed — all green against a clean `supabase db reset`. See [`scripts/`](./scripts) and [`DEVELOPMENT.md`](./DEVELOPMENT.md).

## Benchmark

On a single, **untuned** PostgreSQL (16 vCPU dev box, `synchronous_commit=on`): **~200–270 fully-settled
double-entry trades/sec** per symbol at **~3.5 ms p50** engine latency, scaling to **~560–730/sec**
across 6 symbols in parallel (per-symbol advisory-lock isolation). Each "match" is a *durable, ACID,
double-entry settled* trade — not an in-memory book op. The self-host perf profile
(`synchronous_commit=off`, native C `banker_round`, UNLOGGED book) and symbol sharding raise the
ceiling well beyond. Reproduce: `SERVICE=<key> ./scripts/bench.sh`. Full methodology → [BENCH.md](./BENCH.md);
step-by-step tuning ladder to the ceiling → [TUNING.md](./TUNING.md).

## Quickstart

```bash
# 0) prerequisites: Docker + Supabase CLI + Node
supabase start          # Postgres + PostgREST + Realtime + Auth (local)
supabase db reset       # apply all migrations

export ANON="$(supabase status -o json | jq -r .ANON_KEY)"
export SERVICE="$(supabase status -o json | jq -r .SERVICE_ROLE_KEY)"

# seed a lively market + candle history (demo)
./scripts/seed-demo.sh
./scripts/seed-candles.sh

# build the WASM engine + serve the terminal
cd web && npm install && npm run build:wasm && python3 -m http.server 4173
#  trader terminal → http://127.0.0.1:4173
#  back-office      → http://127.0.0.1:4173/admin.html   (paste the service_role key)

# optional: native C hot-path + DB tunables (self-host)
./scripts/perf-tune-local.sh
```

Run the verification suite (from repo root, with `ANON`/`SERVICE` exported): the `scripts/smoke-*.sh` and `scripts/smoke-*.mjs` flows.

## Project layout

| Path | What |
|---|---|
| `web/` | **OUTCRY** terminal (WASM indicators + drawing tools) and **admin** console |
| `engine/` | Vendored open-outcry PL/pgSQL (matching core), ordered by `manifest.txt` |
| `supabase/migrations/` | Generated engine schema + the `9xxx` platform layers (API, RLS, wallet, risk, realtime, partitioning, lockdown) |
| `ext/oc_fastmath/` | Custom **C extension** (native banker's rounding) + build script |
| `scripts/` | Smoke tests, seeds, benchmark, perf tuning |
| `DEPLOY.md` · `BENCH.md` · `PERFORMANCE.md` · `DEVELOPMENT.md` · `WHY.md` | Deploy profiles · benchmark · scaling plan · dev reference · architecture comparison |

## Roles & security model

- **anon** — public market data only (order book, tape, instruments). No RPCs.
- **authenticated** (user JWT) — self-scoped API: `place_order`, `cancel_order`, `request_deposit`, `request_withdrawal`. RLS limits all reads to the caller's own entity.
- **service_role** (back-office) — full engine + admin RPCs; bypasses RLS.
- `9900_lockdown.sql` revokes EXECUTE on every engine function from public/anon/authenticated and re-grants only the whitelist, so internal helpers (`create_trade`, `update_price_level`, …) are unreachable by clients.

## Realtime feeds

- **Public market data** (no auth): subscribe to **Broadcast** on channel `md:<symbol>` — events `l2` (coalesced order book) and `trade` (tape).
- **Private per-user feed** (auth): call `supabase.realtime.setAuth(jwt)`, then subscribe to `trade_order` (order lifecycle + fills) and `wallet_request` (deposit/withdrawal status). Realtime evaluates each table's RLS per subscriber, so a client receives **only its own rows** — no topic/userId wiring, no server relay. See `examples/private-feed.mjs`.

## License

**AGPL-3.0.** The matching/settlement core under `engine/` derives from
[tolyo/open-outcry](https://github.com/tolyo/open-outcry) (AGPL-3.0); as a derivative
work the entire project is distributed under [AGPL-3.0](./LICENSE) (see [`NOTICE`](./NOTICE)).
If you run a modified version as a network service, AGPL-3.0 requires you to offer users
its source.

## Credits

Matching core based on [**tolyo/open-outcry**](https://github.com/tolyo/open-outcry) (multi-asset matching engine in Go + PL/pgSQL). This project keeps the PL/pgSQL engine, drops the Go layer, and rebuilds the exchange on PostgREST + Supabase Realtime + Supabase Auth, adding the wallet, risk, realtime, back-office, performance work, and the WASM terminal.
