<div align="center">

# Benchmark · 基准测试

Reproducible: **[`scripts/bench.sh`](./scripts/bench.sh)** · [← README](./README.md)

</div>

> **What "a match" means here.** Each match in this benchmark is a *full, durable, double-entry
> settled* trade — the taker order is matched **and** the ledger is updated on both sides
> (≈8 inserts + 4 updates + lookups, committed to WAL). This is **not** comparable to an
> in-memory HFT engine reporting "1M order-book ops/sec"; those are non-durable book mutations,
> not settled trades. pg-outcry trades raw speed for **ACID correctness on every fill**.
>
> **"一次撮合"的含义。** 本基准里的每一次撮合都是*完整、持久、双边记账已结算*的成交 —— 吃单被撮合**并且**
> 账本两边都已更新（约 8 次插入 + 4 次更新 + 查找，落 WAL 提交）。这**不能**与内存 HFT 引擎报的
> "每秒百万次盘口操作"相比 —— 那是非持久的盘口变更，不是已结算成交。pg-outcry 用原始速度换取**每一笔成交的 ACID 正确性**。

## Environment / 环境

| | |
|---|---|
| Host | 16 vCPU · 27 GiB RAM (developer machine) |
| PostgreSQL | 17.6, **default-ish config** (`shared_buffers=128MB`, `synchronous_commit=on`, `wal_compression=off`) |
| `banker_round` | PL/pgSQL (stock; the native C drop-in is *off* for these numbers) |
| Build profile | **baseline** — none of the self-host perf tunables applied |

Numbers below are **indicative on this box with an untuned config** — they are a floor, not a ceiling. Reproduce / run on your own hardware with `SERVICE=<key> ./scripts/bench.sh`.
下列数字是**该机器、未调优配置下的指示值** —— 是下限而非上限。用 `SERVICE=<key> ./scripts/bench.sh` 在你自己的硬件上复现。

## Results / 结果

| Metric / 指标 | Result / 结果 |
|---|---|
| **Sequential throughput** (1 connection, 1 symbol) / 顺序吞吐（单连接单品种） | **~200–270 matched+settled trades/sec** |
| Engine latency per match (server-side) / 单次撮合引擎延迟（服务端） | **p50 ≈ 3.5 ms · p95 ≈ 6 ms · p99 ≈ 7–11 ms** |
| End-to-end order latency over PostgREST/HTTP / 经 PostgREST/HTTP 端到端下单延迟 | **p50 ≈ 9 ms · p95 ≈ 22 ms · p99 ≈ 66 ms** |
| **Concurrency scaling** (6 symbols in parallel) / 并发扩展（6 品种并行） | **~560–730 trades/sec aggregate** (≈2.5–3.7× single-symbol) |

### Reading the results / 解读
- **Per-symbol concurrency works.** Because matching is serialized *per instrument* with an advisory lock, independent symbols run in parallel — aggregate throughput rises with the number of symbols (6 symbols ≈ 3× one). A real venue with dozens of symbols scales further until WAL/IO bound.
  **按品种并发有效。** 撮合按品种用 advisory lock 串行，不同品种并行 —— 总吞吐随品种数上升（6 品种 ≈ 单品种 3 倍）。有几十个品种的真实交易所可继续扩展，直到 WAL/IO 成为瓶颈。
- **Single-symbol latency is millisecond-scale and durable.** ~3.5 ms p50 for a fully settled trade, every fill ACID-committed. That comfortably covers retail/regional/altcoin venues; it is **not** a co-located µs HFT engine (see §9 of [WHY.md](./WHY.md)).
  **单品种延迟为毫秒级且持久。** 完全结算的成交 p50 ≈ 3.5ms，每笔 ACID 提交。足以覆盖零售/区域/山寨币所；它**不是**主机托管的微秒级 HFT 引擎。

## Headroom — what the perf profile adds / 还有多少余量

These numbers use the **baseline** config. The self-host high-performance profile and tuning move the ceiling up substantially:
下列为**基线**配置。自建高性能档与调优可显著抬升上限：

- `synchronous_commit = off` — the single biggest lever for write-heavy settlement (trades off losing the last few committed txns on crash). `scripts/perf-tune-local.sh RISKY=1`.
- Native **C `banker_round`** drop-in (~2.8× on that hot helper) — `ext/oc_fastmath`.
- Larger `shared_buffers` / `max_wal_size`, `wal_compression=on`.
- **UNLOGGED** in-memory order book (already in migrations) — no WAL for the live book.
- Horizontal: **shard by symbol** across nodes (a CEX has no cross-symbol transactions) — near-linear with shard count.

> Bottom line / 结论: a **single, untuned PostgreSQL** already serves hundreds of fully-settled trades/sec at millisecond latency, scaling with symbols — which is more than enough for the small/mid-size venues this is built for, with a clear, documented path to push further.
> 一台**未调优的单 PostgreSQL** 已能以毫秒延迟处理每秒数百笔完全结算的成交、并随品种扩展 —— 对本项目面向的中小交易所绰绰有余，且有清晰的继续提升路径。
