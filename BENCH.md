<div align="center">

# Benchmark

Reproducible: **[`scripts/bench.sh`](./scripts/bench.sh)** · [← README](./README.md)

</div>

> **What "a match" means here.** Each match in this benchmark is a *full, durable, double-entry
> settled* trade — the taker order is matched **and** the ledger is updated on both sides
> (≈8 inserts + 4 updates + lookups, committed to WAL). This is **not** comparable to an
> in-memory HFT engine reporting "1M order-book ops/sec"; those are non-durable book mutations,
> not settled trades. pg-outcry trades raw speed for **ACID correctness on every fill**.

## Environment

| | |
|---|---|
| Host | 16 vCPU · 27 GiB RAM (developer machine) |
| PostgreSQL | 17.6, **default-ish config** (`shared_buffers=128MB`, `synchronous_commit=on`, `wal_compression=off`) |
| `banker_round` | PL/pgSQL (stock; the native C drop-in is *off* for these numbers) |
| Build profile | **baseline** — none of the self-host perf tunables applied |

Numbers below are **indicative on this box with an untuned config** — they are a floor, not a ceiling. Reproduce / run on your own hardware with `SERVICE=<key> ./scripts/bench.sh`.

## Results

| Metric | Result |
|---|---|
| **Sequential throughput** (1 connection, 1 symbol) | **~200–270 matched+settled trades/sec** |
| Engine latency per match (server-side) | **p50 ≈ 3.5 ms · p95 ≈ 6 ms · p99 ≈ 7–11 ms** |
| End-to-end order latency over PostgREST/HTTP | **p50 ≈ 9 ms · p95 ≈ 22 ms · p99 ≈ 66 ms** |
| **Concurrency scaling** (6 symbols in parallel) | **~560–730 trades/sec aggregate** (≈2.5–3.7× single-symbol) |

### Reading the results
- **Per-symbol concurrency works.** Because matching is serialized *per instrument* with an advisory lock, independent symbols run in parallel — aggregate throughput rises with the number of symbols (6 symbols ≈ 3× one). A real venue with dozens of symbols scales further until WAL/IO bound.
- **Single-symbol latency is millisecond-scale and durable.** ~3.5 ms p50 for a fully settled trade, every fill ACID-committed. That comfortably covers retail/regional/altcoin venues; it is **not** a co-located µs HFT engine (see §9 of [WHY.md](./WHY.md)).

## Headroom — what the perf profile adds

These numbers use the **baseline** config. The self-host high-performance profile and tuning move the ceiling up substantially:

- `synchronous_commit = off` — the single biggest lever for write-heavy settlement (trades off losing the last few committed txns on crash). `scripts/perf-tune-local.sh RISKY=1`.
- Native **C `banker_round`** drop-in (~2.8× on that hot helper) — `ext/oc_fastmath`.
- Larger `shared_buffers` / `max_wal_size`, `wal_compression=on`.
- **UNLOGGED** in-memory order book (already in migrations) — no WAL for the live book.
- Horizontal: **shard by symbol** across nodes (a CEX has no cross-symbol transactions) — near-linear with shard count.

> Bottom line: a **single, untuned PostgreSQL** already serves hundreds of fully-settled trades/sec at millisecond latency, scaling with symbols — which is more than enough for the small/mid-size venues this is built for, with a clear, documented path to push further.

## See how far it climbs

This page is the **floor**. For the step-by-step **tuning ladder** — how throughput rises as you
apply each lever (`synchronous_commit=off`, symbol sharding, native C hot-path, WAL/memory sizing),
in priority order, with a script that measures each rung on your hardware — see
**[TUNING.md](./TUNING.md)** (`SERVICE=<key> ./scripts/bench-ladder.sh`).
