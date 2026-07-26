**English** · [中文](./PERFORMANCE.zh-CN.md)

# Performance & scaling plan

Status of the six directives. ✅ = implemented & verified, ◐ = partially done,
⬜ = designed, ready to implement on request.

| # | Directive | Status |
|---|-----------|--------|
| 1 | Shard by symbol | ◐ logical isolation done; single-DB partition of trade_order rejected (breaks private feed); multi-node routing recommended |
| 2 | Hot data in memory | ✅ `00040_ledger_perf_lockdown` book_order + price_level UNLOGGED + rebuild_book() |
| 3 | Cold data partitioning | ✅ `00040_ledger_perf_lockdown` monthly RANGE partitions on trade + both ledgers |
| 4 | Async market data | ✅ `00040_ledger_perf_lockdown` coalesced L2 + tape via `realtime.send`; 100ms ticker |
| 5 | Append-only ledger | ✅ `9630` triggers; reconciliation report |
| 6 | Reduce WAL pressure | ✅ `9710` replica identity + `00040_ledger_perf_lockdown` removes price_level/trade from Postgres Changes |

---

### 1. Shard by symbol

**Done:** matching is already serialized *per instrument* via `pg_advisory_xact_lock(instrument_id)` (`9100`/`9500`). Different symbols never block each other — they run fully concurrently on one DB. This is logical sharding of the *critical section*.

**Single-DB partition of `trade_order` by instrument — REJECTED (would regress the system).**
Investigated in depth; three hard problems make it a net negative:
1. **Breaks the private feed.** `trade_order` is consumed via Realtime Postgres Changes
   (RLS-per-subscriber) for the per-user order/fill stream. Postgres Changes does NOT
   deliver from partitioned tables, so partitioning would force re-architecting the
   private feed onto Broadcast + `realtime.messages` RLS — losing the automatic RLS we rely on.
2. **Forks the engine + composite FKs.** PK → `(instrument_id, id)`; the 5 incoming FKs
   (`book_order`, `stop_order`, `trade`×3) become composite, needing `instrument_id` on
   `book_order`/`stop_order` and changes to engine INSERTs.
3. **Regresses point lookups.** The engine looks up orders by `id`/`pub_id` without an
   instrument filter (e.g. `cancel_trade_order`), which would scan every partition.

Per-symbol concurrency is already provided by the advisory locks, so the throughput upside
is small. **Recommended path for real horizontal scale: multi-node symbol routing** — each
shard is its own Supabase project running this identical migration set and owning a disjoint
symbol set; a stateless router maps `symbol → shard`. No cross-symbol transactions exist in a
CEX, so this shards cleanly without touching the schema, and a shared identity/wallet plane
holds the system-of-record. (`price_level` *is* trivially partitionable by `instrument_id`
but it's now a tiny UNLOGGED table, so there's no point.)

**Next (multi-node): route symbols to separate Supabase projects.**
Each project is a self-contained pure-PG engine owning a disjoint symbol set. A thin stateless router (or PostgREST in front of `pg_cat`/foreign tables) maps `symbol → project`. No cross-symbol transactions exist in a CEX (an order touches one book), so this shards cleanly. Cross-project: a shared identity/wallet project, or replicate balances per shard with the wallet as system-of-record.

### 2. Hot data in memory — ✅ DONE `00040_ledger_perf_lockdown`

The live book (`book_order`, `price_level`) is pure derived state, rebuildable from
the durable `trade_order` rows. Both are now **UNLOGGED**: writes skip WAL (big saving
on the matching hot path) and the data lives in memory. Neither is client-facing on
Realtime anymore (L2 is broadcast from `price_level` *reads*; the private feed uses
`trade_order`), so losing logical replication on them is fine. `book_order` was first
removed from the Postgres Changes publication. `rebuild_book()` reconstructs both from
open orders after an unclean shutdown (UNLOGGED tables come back empty on crash) — run it
once on startup. Verified: settlement still passes; rebuild restores the book exactly.

### 3. Cold data partitioning — ✅ DONE `00040_ledger_perf_lockdown`

`trade`, `transfer_ledger_entry`, `instrument_account_ledger_entry` (0 incoming FKs,
append-only, unbounded) recreated as **monthly RANGE partitions on `created_at`**, PK
`(id, created_at)`, with prev-month..+14-month partitions + a DEFAULT catch-all so
inserts never fail. `create_monthly_partitions()` helper + `roll_partitions()` scheduled
via `pg_cron` (monthly) to roll future months. Engine `INSERT`s route transparently.
Verified: settlement (`smoke-stage2`) + reconciliation (`smoke-stage7`) pass over the
partitioned tables. Old partitions can be `DETACH`ed for compression/export.

**Realtime caveat (important):** Postgres Changes does **not** deliver from partitioned
tables (even with `publish_via_partition_root`). So `trade` was removed from Postgres
Changes and its tape moved to Broadcast — see #4.

### 4. Async market data — ✅ DONE `00040_ledger_perf_lockdown`

Both public feeds moved off Postgres Changes to **Broadcast** on topic `md:<symbol>`:
- **L2 book** (`event:'l2'`, coalesced): an AFTER trigger on `price_level` marks the
  instrument in `md_dirty` (cheap, in matching tx). `broadcast_md()` builds one top-50
  L2 snapshot per dirty book and `realtime.send()`s it, then clears the flag
  (`FOR UPDATE SKIP LOCKED` so overlapping ticks never double-send). Called every
  **100ms** by `examples/md-ticker.mjs` (pure-PG logic; only the timer is external
  because pg_cron can't go sub-second — a 1s pg_cron fallback can be registered).
- **Trade tape** (`event:'trade'`): AFTER INSERT trigger on `trade` broadcasts each
  trade. No ticker needed.

`price_level` and `trade` are removed from the Postgres Changes publication, so the
matching critical path no longer pays per-row logical-decode + FULL replica identity for
market data — message rate is now bounded by the tick interval. Clients subscribe to the
`md:<symbol>` channel (`private:false`, no auth). Verified by `smoke-realtime`/`smoke-marketdata`.

> Realtime warm-up: after a `supabase db reset`, the realtime container needs a few
> seconds before broadcast subscriptions deliver; scripts settle ~3.5s.

### 5. Append-only ledger — ✅ DONE

`00040_ledger_perf_lockdown.sql`: `BEFORE UPDATE OR DELETE` triggers on `transfer_ledger_entry` and `instrument_account_ledger_entry` raise `append_only_ledger`. The engine only ever INSERTs entries, so this is invisible to normal operation and guarantees balances are always re-derivable. `reconcile()` audits 5 core ledger invariants (cash==ledger, double-entry balanced, reservations sane, approved-wallet-has-transfer, issuance conserved). `custody_reconcile()` separately checks that customer funding is chain-backed and that wallet deposit requests are disabled. Verified by `scripts/smoke-stage7.sh`.

### 6. Reduce WAL pressure — ✅ (first pass)

**Done `9710`:** `trade`, `trade_order`, `book_order`, `wallet_request` switched from REPLICA IDENTITY FULL → DEFAULT (PK). FULL writes the whole old row to WAL on every UPDATE/DELETE; DEFAULT writes only the PK, while Postgres Changes still delivers the NEW tuple. Realtime verified unaffected (`smoke-realtime`, `smoke-stage6`). `price_level` kept FULL so L2 DELETE events carry price/side.

**Done `00040_ledger_perf_lockdown`:** `price_level` and `trade` removed from the Postgres Changes publication
(market data is now Broadcast), eliminating their per-row logical-decode WAL on the hot path.

**Further reductions (config / available on request):**
- `wal_compression = on` (less WAL for full-page writes).
- `book_order` can now go UNLOGGED (not client-facing; rebuildable from `trade_order`).
- Tune checkpoint frequency / `max_wal_size` (Supabase-managed; may need project settings).
- Avoid redundant `price_level` UPDATEs (skip no-op volume writes).

---

## Pushing the pure-PG limit (benchmark, plugins, C extension)

### Baseline & profile
- **Throughput**: 1000 crossing match+settle pairs sequential (single connection) ≈ **4.5s → ~220 matches/s** (~440 order submits/s). Cross-instrument load scales further via the per-instrument advisory locks.
- **Profiled** with `pg_stat_statements` (`track=all`). Hot path:
  - `create_trade` ≈ **2.4ms/trade** — dominated by the 4× `process_transfer` double-entry settlement. This is the irreducible core cost.
  - **Per-trade stop-order scan** (`process_crossing_stop_orders` + the stop joins) ran a **Seq Scan over all live orders on every trade** (profiled "Rows Removed by Filter: 2602"), even with zero stops — O(n) growth.
  - Realtime WAL logical-decode also shows up as background load (already minimized by moving market data off Postgres Changes).

### Optimization: partial index (`00040_ledger_perf_lockdown`)
`trade_order_stops_idx` — a partial index over only STOPLOSS/STOPLIMIT rows — turns the
per-trade stop probe from a full Seq Scan into an instant 0-row index scan (plan verified).
Tiny (stops are rare); its payoff grows with `trade_order` size, preventing O(n) degradation
of every trade as history accumulates.

### Plugins tested (of 78 available)
- **pg_stat_statements** — profiling the matching hot path (used above).
- **pg_prewarm / pg_buffercache** — warm + inspect the cache for the hot book/order tables.
- **hypopg** — hypothetical-index what-if before committing real indexes.
- **pgstattuple** — bloat inspection on the append-only ledger partitions.
- **pg_cron** — partition rolling + market-data fallback ticker (already used).
- Also on tap: `plpgsql_check`, `pgmq`, `vector`, `pgaudit`, `pg_net`, `pg_partman`, `pg_repack`.

### Custom C extension — `oc_fastmath` (`ext/oc_fastmath/`)
Native C beats PL/pgSQL for hot scalar math. `oc_banker_round(float8,int)` (round-half-to-even):
- **2,000,000 calls: 0.87s (C) vs 4.54s (PL/pgSQL) ≈ 5.2× faster.**

Building here is non-trivial because the DB is a **nix-built PG 17.6 on Alpine**:
- server headers live in the nix store (`pg_config`'s path is stripped) — compile against
  `/nix/store/*-postgresql-17.6/include/server`;
- `pkglibdir` is the **read-only** nix store → install the `.so` into **PGDATA** (persistent,
  writable) and load by absolute path;
- the container's own **`nix`** provides an ABI-matching `gcc` on demand;
- the `postgres` role is **not** superuser → create C functions as **`supabase_admin`**.

`ext/oc_fastmath/build.sh` does all of this idempotently; run after `supabase start`
(re-run the SQL part after `supabase db reset` — the `.so` persists in PGDATA).

#### oc_banker_round_numeric — native drop-in for the engine's hot helper
`banker_round(numeric,int)` (round-half-to-even) is the one genuinely CPU-bound helper on
the settlement path. Reimplemented in C via the server numeric API, **bit-identical** to the
PL/pgSQL version (0 mismatches over 20,012 random + edge cases), and ~**2.8× faster in
isolation** (2M calls: 1.46s C vs 4.07s PL/pgSQL). `build.sh` swaps the engine's
`banker_round` to the C version by default (DROP+CREATE as supabase_admin; PL/pgSQL bodies
resolve it by name). Verified: settlement + all 5 reconciliation invariants still pass with
C rounding in the hot path.

#### Hot-spot map & the honest limit
Profiled every hot spot and classified by nature (native code only helps CPU-bound work;
PL/pgSQL is already plan-cached for SQL-bound work):

| Hot spot | Nature | Optimization |
|----------|--------|--------------|
| `create_trade` settlement (4× `process_transfer`, ~2.4ms/trade) | **I/O** (heap inserts + WAL + index) | structural: UNLOGGED book, partitioned ledger, WAL reduction |
| `banker_round` (numeric, half-even) | **CPU** | **native C, 2.8×** (`oc_fastmath`) |
| per-trade stop-order scan | CPU+I/O (was O(n) seq scan) | partial index `00040_ledger_perf_lockdown` → O(log n) |
| `price_level` updates | I/O | UNLOGGED (`00040_ledger_perf_lockdown`) |
| `uuid_generate_v4` ×~8/trade | CPU (tiny) | ~1.3µs each ≈ 0.2% of a trade — **not worth changing** |
| market-data fan-out | I/O (logical decode) | moved off Postgres Changes → Broadcast |

**Conclusion / the limit:** end-to-end match throughput is **I/O-bound** — dominated by the
heap inserts, index maintenance and WAL of double-entry settlement (~8 inserts + 4 updates +
lookups per trade). Native (C/Rust) plugins give large *isolated* speedups on CPU-bound
helpers (banker_round 2.8×) but cannot move end-to-end throughput, because the cost is in the
storage executor, not the PL/pgSQL interpreter. Going past this floor requires **structural**
change (fewer rows per trade, batching) or **horizontal** scale (multi-node symbol routing) —
not more native scalar code. The CPU-bound hot spots are now native; the I/O-bound ones are
addressed structurally; that is the pure-PG limit on a single node.

#### Batched ledger writes (`9760`)
`create_transfer` now writes its DEBIT+CREDIT ledger rows in a single 2-row INSERT instead
of two single-row INSERTs (per FX trade: 8→4 ledger-insert statements). Same rows, identical
semantics — verified by settlement + all 5 reconciliation invariants and the full 11-flow suite.

**Honest ceiling:** batching cuts per-*statement* executor overhead, **not** per-*row* I/O —
the same 8 ledger rows are still heap-inserted, indexed and WAL-logged, which is the dominant
cost. So the gain is bounded by statement overhead (single-digit %), and was within the
benchmark noise on this machine. The only way to cut the row I/O itself is to emit **fewer
rows per trade** — i.e. eliminate the MASTER pass-through legs so each asset moves buyer↔seller
directly (4 transfers/8 ledger rows → 2 transfers/4 ledger rows, ~halving settlement WAL).
That changes the settlement model (MASTER stops being the clearing counterparty for asset legs;
fees would become explicit CHARGE transfers), so it's deferred as a deliberate design decision
rather than applied silently to money-handling code.

---

## Tuning ladder — from the baseline to the ceiling

How throughput climbs as you apply each optimization. Reproduce on your own hardware:
**[`scripts/bench-ladder.sh`](../scripts/bench-ladder.sh)** · [← BENCH.md](./PERFORMANCE.md) · [← README](../README.md)

</div>

> [BENCH.md](./PERFORMANCE.md) reports the **baseline** (a single, untuned PostgreSQL) — deliberately a
> *floor*. This page is the *ladder*: the levers that raise the ceiling, in priority order, each
> with what it does, how to apply it, and how to measure it. Run the ladder yourself with
> `SERVICE=<key> ./scripts/bench-ladder.sh` (do `supabase db reset` first for a clean rung 0).

### How to read these numbers

Every "trade" here is a **durable, ACID, double-entry settled** fill (≈8 inserts + 4 updates,
committed to WAL) — not an in-memory book op. That single fact explains the whole ladder: the hot
path is **bound by WAL/fsync**, not CPU arithmetic. So the levers that matter most are the ones
that change *how often and how much you sync to disk*, and the one that adds *more independent
write streams* (sharding). Micro-optimizing arithmetic barely moves the end-to-end number.

> ⚠️ **Run the ladder on a quiet machine.** Durable-settlement throughput is so WAL/fsync-bound
> that background load on a shared/dev box produces variance that swamps the levers (we have seen
> the same rung read 60/s under load and 230/s idle). Treat any single noisy run as meaningless;
> compare rungs measured back-to-back on an otherwise-idle host, ideally averaged over a few runs.

### The ladder

Rungs are **additive** (each builds on the previous). The `agg` column is the
**N-symbol aggregate** — the horizontal/sharding ceiling at that config (a CEX has no
cross-symbol transactions, so symbols run fully in parallel behind a per-instrument advisory lock).

| rung | what changes | seq trades/s | p50 ms | direction of the lever |
|---|---|---|---|---|
| **0** | baseline — `synchronous_commit=on`, `wal_compression=off`, PL/pgSQL `banker_round` | **~230** | **~4.5** | reference floor |
| **1** | `+ wal_compression=on` | ~same seq | ~same | less WAL **volume** → helps IO-bound / replication, not single-box fsync latency |
| **2** | `+ synchronous_commit=off` | **big jump** | **big drop** | **the dominant lever** — stops fsync-on-commit (trades durability of the last few txns on crash) |
| **3** | `+ native C banker_round` (`ext/oc_fastmath`) | ~same as rung 2 | ~same | speeds the *micro-op* ~2–3×, but arithmetic isn't the bottleneck → little end-to-end gain |
| **horizontal** | **shard by symbol** (the `agg` column) | n/a | n/a | near-linear with symbol count until WAL/IO bound — the real way to scale a CEX |

**Measured rung-0 baseline** (16 vCPU · 27 GiB · PostgreSQL 17.6, idle):
**228 seq trades/s · p50 4.5 ms · p95 6.9 ms · p99 8.9 ms**, and **1,066 trades/s aggregate across
6 symbols in parallel** (≈4.7× the single-symbol rate — the sharding lever, already visible at the
baseline config). The other rungs are intentionally left for you to fill in with
`scripts/bench-ladder.sh` on your hardware, because the deltas are hardware- and load-dependent and
publishing fabricated tidy increments would be dishonest. The **shape** is what's robust:
`synchronous_commit=off` is the big single-box win; sharding is the big horizontal win; the C
hot-path and `wal_compression` are minor for single-box durable throughput.

### The levers, in detail

#### 1. `synchronous_commit = off` — the dominant single-box lever
By default every COMMIT waits for an fsync of the WAL. For a workload that commits one settled trade
per request, that fsync *is* the per-trade cost. Turning it off lets commits return before the WAL
hits disk — a large throughput gain and latency drop.
**Trade-off:** on a crash you can lose the last few committed transactions (a fraction of a second).
That is acceptable for many venues with replication/PITR, unacceptable for some — your call.
Apply: `./scripts/perf-tune-local.sh RISKY=1` (or `ALTER SYSTEM SET synchronous_commit=off`).

#### 2. Shard by symbol — the dominant horizontal lever
Matching is serialized **per instrument** with `pg_advisory_xact_lock(instrument_id)`, so different
symbols never block each other and scale across cores on one node (the `agg` column). Because a CEX
has **no cross-symbol transactions**, you can also shard symbols across *separate* nodes with **zero
schema change** — each shard is the identical migration set owning a disjoint symbol set, behind a
stateless router, sharing the identity/wallet plane. This is near-linear and is how you go past a
single box's ceiling. See [PERFORMANCE.md](./PERFORMANCE.md) §1.

#### 3. UNLOGGED in-memory order book — already in the migrations
The live book (`price_level` / `book_order`) is **UNLOGGED**: no WAL for book mutations, only the
durable ledger is logged. This is on by default (migration `00040_ledger_perf_lockdown`); it removes WAL pressure from the
highest-churn tables while keeping settlement durable.

#### 4. `wal_compression = on` — IO volume, not fsync latency
Shrinks WAL volume (helps IO-bound boxes, replication bandwidth, and `max_wal_size` headroom). It
does **not** remove the per-commit fsync, so on a single box it barely moves sequential throughput —
its value shows up under IO pressure and with replicas. Applied by `perf-tune-local.sh`.

#### 5. Native C `banker_round` (`ext/oc_fastmath`) — micro-op, not bottleneck
A drop-in C implementation of the rounding helper, ~2–3× faster *for that call*. But banker's
rounding is a tiny slice of a settled-trade transaction dominated by WAL/locks/inserts, so swapping
it gives little end-to-end gain on the durable path. It's here because it's a clean example of a
native hot-path extension and helps arithmetic-heavy batch jobs — not because it's a throughput
lever for settlement. Build: `./ext/oc_fastmath/build.sh`.

#### 6. Memory / WAL sizing — needs a restart
`shared_buffers`, `work_mem`, `max_wal_size`, `effective_cache_size` aren't runtime-reloadable; set
them in `supabase/config.toml` `[db]` (self-host) and restart. Larger `shared_buffers` keeps the hot
book and indexes resident; larger `max_wal_size` reduces checkpoint frequency under write bursts.

### Batch order submission (group commit) — tuning the batch size

> **First, reconcile the numbers — two different measurement planes.** The headline
> **~200–270 trades/s/symbol** in [BENCH.md](./PERFORMANCE.md) is the **engine** rate, measured
> **server-side in a psql loop with no network** — the true ceiling of the matching+settlement hot
> path. The batch table below is the **client** rate, measured **over PostgREST/HTTP**, where every
> call also pays a network round-trip + auth. A single order per HTTP call is *round-trip-bound*, so
> it sits far **below** the engine ceiling — that gap is the HTTP overhead, not the engine being slow.
>
> **Batching does not slow the engine down.** It submits N orders in one HTTP call / one transaction,
> so it lifts the **client** rate *up from the per-call-round-trip floor toward the engine ceiling*.
> It can never exceed the engine ceiling, and it never makes a single order settle slower. If a table
> ever shows batching *below* singles, that's the longer transaction's own cost (see the knee) or a
> contended box — not "tuning made the exchange slower."
>
> **And don't read single-connection sequential HTTP as capacity.** One request at a time measures
> *latency* (~one round-trip each), not throughput. Real throughput comes from **many concurrent
> clients**, bounded by the engine ceiling (~200–270 durable settled trades/s/symbol, ~560–730/s
> across 6 symbols — see [BENCH.md](./PERFORMANCE.md)) and multiplied across symbols. A two-digit
> orders/s number means the measurement was sequential and/or the box was busy — not the system's limit.

`submit_orders(account, instrument, jsonb[])` (migration `9765`) processes N orders for one
instrument in **one transaction**: one HTTP round-trip, one auth, one advisory-lock acquisition, one
commit. Durable-safe (`synchronous_commit` stays on) — for market makers / liquidity bots placing
many orders at once.

**Where the win comes from (and where it doesn't):**
- **HTTP round-trip amortization — the main, always-present win.** 100 orders in 1 call instead of
  100 calls removes ~99 network round-trips + auths. This is why the client rate climbs with batch
  size.
- **fsync amortization — only on slow-fsync storage.** With `synchronous_commit=on`, one commit per
  batch = one fsync for N orders. On cloud network disks (expensive fsync) this is a big extra win;
  on a local SSD/dev box (cheap fsync) it's negligible.
- **Not an engine-throughput multiplier.** Server-side (no HTTP), batching this same-account workload
  is roughly neutral-to-slightly-negative, because the one transaction re-updates the submitter's own
  account rows N times under one snapshot. So batching is about **client throughput / round-trips /
  atomic multi-order submit**, *not* about making the engine itself faster than its ~270/s ceiling.

**There is a knee.** Client throughput rises with batch size as round-trips are amortized, then
plateaus/falls (the long transaction holds the per-instrument lock longer and churns the submitter's
rows), while per-call **latency grows ~linearly**. So tune for *max throughput at a latency you can
accept*. Measure with **`SERVICE=<key> ./scripts/bench-batch.sh`**.

⚠️ **The absolute numbers below were taken on a heavily contended dev box (load > cores), so they are
depressed several-fold and must NOT be compared to BENCH.md's server-side figures.** Only the
**relative shape** (the ×-speedup column and where the knee sits) is meaningful; reproduce real
numbers on a quiet box with the script.

| batch | HTTP calls for 600 orders | orders/s (HTTP, contended box) | per-call latency | vs singles |
|---|---|---|---|---|
| 1 (singles) | 600 | low (round-trip-bound) | ~30 ms | 1.0× |
| **10** | 60 | — | ~130–220 ms | ~1.2–2.4× |
| 25 | 24 | — | ~300–620 ms | ~1.1–2.5× |
| 50 | 12 | — | ~600–710 ms | ~1.9–2.7× (peak) |
| 100 | 6 | — | ~1.2 s | plateau |
| 200 | 3 | — | ~3.5 s | falls off |

**Recommendation (client/HTTP path):**
- **Interactive / low-latency:** batch **10–25** — most of the round-trip win at ~130–300 ms/call.
- **Throughput-first (bulk requoting), latency ≲1 s OK:** batch **~50** — near the knee.
- **Avoid ≥100** unless latency is irrelevant — throughput plateaus while latency runs into seconds.
- The knee shifts with network RTT, storage fsync cost, and load — **run `bench-batch.sh` on your
  box** and pick the smallest batch whose `orders/s` is near the max with acceptable `per-call ms`.

### Priority order (what to reach for first)

1. **`synchronous_commit=off`** (+ replication/PITR for durability) — biggest single-box win.
2. **Shard by symbol** — the way past one box; near-linear, zero schema change.
3. **Batch order submission** (`submit_orders`, batch ~10–25) — biggest *client-side* win for
   multi-order submitters; amortizes round-trip/auth/lock/commit. Tune with `bench-batch.sh`.
4. **Memory/WAL sizing** for your working set; UNLOGGED book is already on.
5. `wal_compression` if IO- or replication-bound.
6. Native C hot-paths last — only once you've proven the bottleneck is CPU, which for durable
   settlement it usually isn't.

> Bottom line: the baseline already serves hundreds of fully-settled trades/sec; the ceiling is
> raised mostly by **relaxing per-commit fsync** and **adding parallel write streams (symbols)** —
> reproduce the exact ladder for your hardware with `scripts/bench-ladder.sh`.

---

## Benchmark

Reproducible: **[`scripts/bench.sh`](../scripts/bench.sh)** (engine) · **[`scripts/bench-batch.sh`](../scripts/bench-batch.sh)** (API) · [← README](../README.md)

</div>

### Two dimensions — define them before quoting any number

Mixing these two is the #1 way to publish a misleading benchmark. They answer different questions:

| | **① Engine throughput** | **② API throughput** |
|---|---|---|
| Question | *How fast can the matching+settlement engine go?* | *What does a client get end-to-end through the API?* |
| Measured | **server-side, in-DB** (psql loop, no network) | **over PostgREST/HTTP** (network + auth per call) |
| Bounded by | PostgreSQL / WAL / CPU — **this is the ceiling** | dimension ① (can approach it, never exceed it) |
| Knobs | `synchronous_commit`, sharding, WAL, indexes | **concurrency** + **batching** + round-trip latency |
| The number readers care about | **✅ this one** | integration concern, depends on your client |

> **What "a trade" means.** Every trade here is a *full, durable, double-entry settled* fill — the
> taker is matched **and** the ledger is written on both sides (≈8 inserts + 4 updates, committed to
> WAL). This is **not** comparable to an in-memory HFT engine reporting "1M book ops/sec"; those are
> non-durable book mutations. pg-outcry trades raw speed for **ACID correctness on every fill**.

---

### ① Engine throughput (server-side) — the matching-engine ceiling

Measured in a psql loop, **no network**, so it isolates the engine itself. This is the headline.

**Environment:** 16 vCPU · 27 GiB · PostgreSQL 17.6, **untuned** (`shared_buffers=128MB`,
`synchronous_commit=on`, `wal_compression=off`), PL/pgSQL `banker_round`. A **floor**, not a ceiling.

| Metric | Result |
|---|---|
| **Sequential throughput** (1 connection, 1 symbol) | **~200–270 settled trades/sec** |
| Engine latency per settled trade | **p50 ≈ 3.5 ms · p95 ≈ 6 ms · p99 ≈ 7–11 ms** |
| **Concurrency scaling** (6 symbols in parallel) | **~560–730 trades/sec aggregate** (≈2.5–3.7×) |

- **Per-symbol concurrency is real.** Matching is serialized *per instrument* with an advisory lock,
  so independent symbols run fully in parallel — aggregate throughput rises with symbol count. A
  venue with dozens of symbols scales further until WAL/IO-bound.
- **Every fill is durable and millisecond-scale.** ~3.5 ms p50 for a fully-settled, ACID-committed
  trade. This is the ceiling dimension ② approaches.
- **Headroom:** `synchronous_commit=off`, native C `banker_round`, larger `shared_buffers`/`max_wal_size`,
  and **symbol sharding across nodes** raise it well beyond — step-by-step in [TUNING.md](./PERFORMANCE.md).

Reproduce: `SERVICE=<key> ./scripts/bench.sh`.

---

### ② API throughput (client, over PostgREST/HTTP) — bounded by ①

This measures the *integration path*, not the engine. Two sub-points, kept strictly apart:

**Latency probe (NOT throughput).** A single order, one connection, one-at-a-time, is a *latency*
measurement: each call pays a network round-trip + auth. On the dev box that's **p50 ≈ 9 ms · p95 ≈
22 ms** end-to-end. **Do not read "1000 / 9 ms ≈ 110 orders/s" as the system's capacity** — that's
the latency of *one serial client*, not throughput.

**Throughput (the real question) = concurrency × per-request, capped by ①.** Real clients use many
concurrent connections; aggregate API throughput rises with concurrency until it meets the engine
ceiling (①). **Batching** (`submit_orders`) is the other lever: N orders per HTTP call amortizes the
round-trip + auth + commit, so a *single* client gets a multiple of its sequential rate. Tuning the
batch size (throughput vs per-call latency) → [TUNING.md › batch](./PERFORMANCE.md#batch-order-submission-group-commit--tuning-the-batch-size).

Reproduce: `SERVICE=<key> ./scripts/bench-batch.sh` (sweeps batch size and concurrency over HTTP).

> ⚠️ **Measure on a quiet box.** Both dimensions are sensitive to other load. On a contended machine
> (e.g. 16-core laptop already pinned by other apps) absolute numbers drop several-fold and
> concurrency stops scaling because there are no free cores — that tells you about the box, not the
> exchange. Compare runs back-to-back on an idle host.

---

### How to quote pg-outcry honestly

- **"~200–270 durable, double-entry-settled trades/sec per symbol, ~560–730/sec across 6 symbols, on
  a single untuned Postgres; scales with symbols and tuning."** ← the engine ceiling (①). This is the
  claim to make.
- **Not** "31 orders/sec" — that's a single serial HTTP client's *latency*, dimension ②'s probe, and
  was taken on a busy box. It's not a throughput figure and not the engine.
- It is **ms-scale durable**, **not** µs-scale in-memory HFT — see when *not* to use it in
  [WHY.md](./WHY.md#9-when-not-to-use-this).

> Bottom line: the engine does **hundreds of fully-settled trades/sec per symbol at millisecond
> latency**, scaling with symbols — plenty for the small/mid venues this targets, with a documented
> path ([TUNING.md](./PERFORMANCE.md)) to push further. The API path reaches that ceiling via concurrency
> and batching; a single serial connection only measures latency.

---

[← Back to docs](./README.md) · [← Project README](../README.md)
