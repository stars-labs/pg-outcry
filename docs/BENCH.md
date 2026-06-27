**English** · [中文](./BENCH.zh-CN.md)

<div align="center">

# Benchmark

Reproducible: **[`scripts/bench.sh`](../scripts/bench.sh)** (engine) · **[`scripts/bench-batch.sh`](../scripts/bench-batch.sh)** (API) · [← README](../README.md)

</div>

## Two dimensions — define them before quoting any number

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

## ① Engine throughput (server-side) — the matching-engine ceiling

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
  and **symbol sharding across nodes** raise it well beyond — step-by-step in [TUNING.md](./TUNING.md).

Reproduce: `SERVICE=<key> ./scripts/bench.sh`.

---

## ② API throughput (client, over PostgREST/HTTP) — bounded by ①

This measures the *integration path*, not the engine. Two sub-points, kept strictly apart:

**Latency probe (NOT throughput).** A single order, one connection, one-at-a-time, is a *latency*
measurement: each call pays a network round-trip + auth. On the dev box that's **p50 ≈ 9 ms · p95 ≈
22 ms** end-to-end. **Do not read "1000 / 9 ms ≈ 110 orders/s" as the system's capacity** — that's
the latency of *one serial client*, not throughput.

**Throughput (the real question) = concurrency × per-request, capped by ①.** Real clients use many
concurrent connections; aggregate API throughput rises with concurrency until it meets the engine
ceiling (①). **Batching** (`submit_orders`) is the other lever: N orders per HTTP call amortizes the
round-trip + auth + commit, so a *single* client gets a multiple of its sequential rate. Tuning the
batch size (throughput vs per-call latency) → [TUNING.md › batch](./TUNING.md#batch-order-submission-group-commit--tuning-the-batch-size).

Reproduce: `SERVICE=<key> ./scripts/bench-batch.sh` (sweeps batch size and concurrency over HTTP).

> ⚠️ **Measure on a quiet box.** Both dimensions are sensitive to other load. On a contended machine
> (e.g. 16-core laptop already pinned by other apps) absolute numbers drop several-fold and
> concurrency stops scaling because there are no free cores — that tells you about the box, not the
> exchange. Compare runs back-to-back on an idle host.

---

## How to quote pg-outcry honestly

- **"~200–270 durable, double-entry-settled trades/sec per symbol, ~560–730/sec across 6 symbols, on
  a single untuned Postgres; scales with symbols and tuning."** ← the engine ceiling (①). This is the
  claim to make.
- **Not** "31 orders/sec" — that's a single serial HTTP client's *latency*, dimension ②'s probe, and
  was taken on a busy box. It's not a throughput figure and not the engine.
- It is **ms-scale durable**, **not** µs-scale in-memory HFT — see when *not* to use it in
  [WHY.md](./WHY.md#9-when-not-to-use-this).

> Bottom line: the engine does **hundreds of fully-settled trades/sec per symbol at millisecond
> latency**, scaling with symbols — plenty for the small/mid venues this targets, with a documented
> path ([TUNING.md](./TUNING.md)) to push further. The API path reaches that ceiling via concurrency
> and batching; a single serial connection only measures latency.
