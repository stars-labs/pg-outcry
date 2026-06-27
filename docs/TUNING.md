**English** · [中文](./TUNING.zh-CN.md)

<div align="center">

# Tuning ladder — from the baseline to the ceiling

How throughput climbs as you apply each optimization. Reproduce on your own hardware:
**[`scripts/bench-ladder.sh`](../scripts/bench-ladder.sh)** · [← BENCH.md](./BENCH.md) · [← README](../README.md)

</div>

> [BENCH.md](./BENCH.md) reports the **baseline** (a single, untuned PostgreSQL) — deliberately a
> *floor*. This page is the *ladder*: the levers that raise the ceiling, in priority order, each
> with what it does, how to apply it, and how to measure it. Run the ladder yourself with
> `SERVICE=<key> ./scripts/bench-ladder.sh` (do `supabase db reset` first for a clean rung 0).

## How to read these numbers

Every "trade" here is a **durable, ACID, double-entry settled** fill (≈8 inserts + 4 updates,
committed to WAL) — not an in-memory book op. That single fact explains the whole ladder: the hot
path is **bound by WAL/fsync**, not CPU arithmetic. So the levers that matter most are the ones
that change *how often and how much you sync to disk*, and the one that adds *more independent
write streams* (sharding). Micro-optimizing arithmetic barely moves the end-to-end number.

> ⚠️ **Run the ladder on a quiet machine.** Durable-settlement throughput is so WAL/fsync-bound
> that background load on a shared/dev box produces variance that swamps the levers (we have seen
> the same rung read 60/s under load and 230/s idle). Treat any single noisy run as meaningless;
> compare rungs measured back-to-back on an otherwise-idle host, ideally averaged over a few runs.

## The ladder

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

## The levers, in detail

### 1. `synchronous_commit = off` — the dominant single-box lever
By default every COMMIT waits for an fsync of the WAL. For a workload that commits one settled trade
per request, that fsync *is* the per-trade cost. Turning it off lets commits return before the WAL
hits disk — a large throughput gain and latency drop.
**Trade-off:** on a crash you can lose the last few committed transactions (a fraction of a second).
That is acceptable for many venues with replication/PITR, unacceptable for some — your call.
Apply: `./scripts/perf-tune-local.sh RISKY=1` (or `ALTER SYSTEM SET synchronous_commit=off`).

### 2. Shard by symbol — the dominant horizontal lever
Matching is serialized **per instrument** with `pg_advisory_xact_lock(instrument_id)`, so different
symbols never block each other and scale across cores on one node (the `agg` column). Because a CEX
has **no cross-symbol transactions**, you can also shard symbols across *separate* nodes with **zero
schema change** — each shard is the identical migration set owning a disjoint symbol set, behind a
stateless router, sharing the identity/wallet plane. This is near-linear and is how you go past a
single box's ceiling. See [PERFORMANCE.md](./PERFORMANCE.md) §1.

### 3. UNLOGGED in-memory order book — already in the migrations
The live book (`price_level` / `book_order`) is **UNLOGGED**: no WAL for book mutations, only the
durable ledger is logged. This is on by default (migration `9730`); it removes WAL pressure from the
highest-churn tables while keeping settlement durable.

### 4. `wal_compression = on` — IO volume, not fsync latency
Shrinks WAL volume (helps IO-bound boxes, replication bandwidth, and `max_wal_size` headroom). It
does **not** remove the per-commit fsync, so on a single box it barely moves sequential throughput —
its value shows up under IO pressure and with replicas. Applied by `perf-tune-local.sh`.

### 5. Native C `banker_round` (`ext/oc_fastmath`) — micro-op, not bottleneck
A drop-in C implementation of the rounding helper, ~2–3× faster *for that call*. But banker's
rounding is a tiny slice of a settled-trade transaction dominated by WAL/locks/inserts, so swapping
it gives little end-to-end gain on the durable path. It's here because it's a clean example of a
native hot-path extension and helps arithmetic-heavy batch jobs — not because it's a throughput
lever for settlement. Build: `./ext/oc_fastmath/build.sh`.

### 6. Memory / WAL sizing — needs a restart
`shared_buffers`, `work_mem`, `max_wal_size`, `effective_cache_size` aren't runtime-reloadable; set
them in `supabase/config.toml` `[db]` (self-host) and restart. Larger `shared_buffers` keeps the hot
book and indexes resident; larger `max_wal_size` reduces checkpoint frequency under write bursts.

## Batch order submission (group commit) — tuning the batch size

> **First, reconcile the numbers — two different measurement planes.** The headline
> **~200–270 trades/s/symbol** in [BENCH.md](./BENCH.md) is the **engine** rate, measured
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
> across 6 symbols — see [BENCH.md](./BENCH.md)) and multiplied across symbols. A two-digit
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

## Priority order (what to reach for first)

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
