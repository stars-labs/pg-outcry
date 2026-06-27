<div align="center">

# Tuning ladder — from the baseline to the ceiling

How throughput climbs as you apply each optimization. Reproduce on your own hardware:
**[`scripts/bench-ladder.sh`](./scripts/bench-ladder.sh)** · [← BENCH.md](./BENCH.md) · [← README](./README.md)

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

## Priority order (what to reach for first)

1. **`synchronous_commit=off`** (+ replication/PITR for durability) — biggest single-box win.
2. **Shard by symbol** — the way past one box; near-linear, zero schema change.
3. **Memory/WAL sizing** for your working set; UNLOGGED book is already on.
4. `wal_compression` if IO- or replication-bound.
5. Native C hot-paths last — only once you've proven the bottleneck is CPU, which for durable
   settlement it usually isn't.

> Bottom line: the baseline already serves hundreds of fully-settled trades/sec; the ceiling is
> raised mostly by **relaxing per-commit fsync** and **adding parallel write streams (symbols)** —
> reproduce the exact ladder for your hardware with `scripts/bench-ladder.sh`.
