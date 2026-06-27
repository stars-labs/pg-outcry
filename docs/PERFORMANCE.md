**English** · [中文](./PERFORMANCE.zh-CN.md)

# Performance & scaling plan

Status of the six directives. ✅ = implemented & verified, ◐ = partially done,
⬜ = designed, ready to implement on request.

| # | Directive | Status |
|---|-----------|--------|
| 1 | Shard by symbol | ◐ logical isolation done; single-DB partition of trade_order rejected (breaks private feed); multi-node routing recommended |
| 2 | Hot data in memory | ✅ `9730` book_order + price_level UNLOGGED + rebuild_book() |
| 3 | Cold data partitioning | ✅ `9640` monthly RANGE partitions on trade + both ledgers |
| 4 | Async market data | ✅ `9720` coalesced L2 + tape via `realtime.send`; 100ms ticker |
| 5 | Append-only ledger | ✅ `9630` triggers; reconciliation report |
| 6 | Reduce WAL pressure | ✅ `9710` replica identity + `9720` removes price_level/trade from Postgres Changes |

---

## 1. Shard by symbol

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

## 2. Hot data in memory — ✅ DONE `9730`

The live book (`book_order`, `price_level`) is pure derived state, rebuildable from
the durable `trade_order` rows. Both are now **UNLOGGED**: writes skip WAL (big saving
on the matching hot path) and the data lives in memory. Neither is client-facing on
Realtime anymore (L2 is broadcast from `price_level` *reads*; the private feed uses
`trade_order`), so losing logical replication on them is fine. `book_order` was first
removed from the Postgres Changes publication. `rebuild_book()` reconstructs both from
open orders after an unclean shutdown (UNLOGGED tables come back empty on crash) — run it
once on startup. Verified: settlement still passes; rebuild restores the book exactly.

## 3. Cold data partitioning — ✅ DONE `9640`

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

## 4. Async market data — ✅ DONE `9720`

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

## 5. Append-only ledger — ✅ DONE

`9630_reconciliation.sql`: `BEFORE UPDATE OR DELETE` triggers on `transfer_ledger_entry` and `instrument_account_ledger_entry` raise `append_only_ledger`. The engine only ever INSERTs entries, so this is invisible to normal operation and guarantees balances are always re-derivable. `reconcile()` audits 5 invariants (cash==ledger, double-entry balanced, reservations sane, approved-wallet-has-transfer, issuance conserved). Verified by `scripts/smoke-stage7.sh`.

## 6. Reduce WAL pressure — ✅ (first pass)

**Done `9710`:** `trade`, `trade_order`, `book_order`, `wallet_request` switched from REPLICA IDENTITY FULL → DEFAULT (PK). FULL writes the whole old row to WAL on every UPDATE/DELETE; DEFAULT writes only the PK, while Postgres Changes still delivers the NEW tuple. Realtime verified unaffected (`smoke-realtime`, `smoke-stage6`). `price_level` kept FULL so L2 DELETE events carry price/side.

**Done `9720`:** `price_level` and `trade` removed from the Postgres Changes publication
(market data is now Broadcast), eliminating their per-row logical-decode WAL on the hot path.

**Further reductions (config / available on request):**
- `wal_compression = on` (less WAL for full-page writes).
- `book_order` can now go UNLOGGED (not client-facing; rebuildable from `trade_order`).
- Tune checkpoint frequency / `max_wal_size` (Supabase-managed; may need project settings).
- Avoid redundant `price_level` UPDATEs (skip no-op volume writes).

---

# Pushing the pure-PG limit (benchmark, plugins, C extension)

## Baseline & profile
- **Throughput**: 1000 crossing match+settle pairs sequential (single connection) ≈ **4.5s → ~220 matches/s** (~440 order submits/s). Cross-instrument load scales further via the per-instrument advisory locks.
- **Profiled** with `pg_stat_statements` (`track=all`). Hot path:
  - `create_trade` ≈ **2.4ms/trade** — dominated by the 4× `process_transfer` double-entry settlement. This is the irreducible core cost.
  - **Per-trade stop-order scan** (`process_crossing_stop_orders` + the stop joins) ran a **Seq Scan over all live orders on every trade** (profiled "Rows Removed by Filter: 2602"), even with zero stops — O(n) growth.
  - Realtime WAL logical-decode also shows up as background load (already minimized by moving market data off Postgres Changes).

## Optimization: partial index (`9750`)
`trade_order_stops_idx` — a partial index over only STOPLOSS/STOPLIMIT rows — turns the
per-trade stop probe from a full Seq Scan into an instant 0-row index scan (plan verified).
Tiny (stops are rare); its payoff grows with `trade_order` size, preventing O(n) degradation
of every trade as history accumulates.

## Plugins tested (of 78 available)
- **pg_stat_statements** — profiling the matching hot path (used above).
- **pg_prewarm / pg_buffercache** — warm + inspect the cache for the hot book/order tables.
- **hypopg** — hypothetical-index what-if before committing real indexes.
- **pgstattuple** — bloat inspection on the append-only ledger partitions.
- **pg_cron** — partition rolling + market-data fallback ticker (already used).
- Also on tap: `plpgsql_check`, `pgmq`, `vector`, `pgaudit`, `pg_net`, `pg_partman`, `pg_repack`.

## Custom C extension — `oc_fastmath` (`ext/oc_fastmath/`)
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

### oc_banker_round_numeric — native drop-in for the engine's hot helper
`banker_round(numeric,int)` (round-half-to-even) is the one genuinely CPU-bound helper on
the settlement path. Reimplemented in C via the server numeric API, **bit-identical** to the
PL/pgSQL version (0 mismatches over 20,012 random + edge cases), and ~**2.8× faster in
isolation** (2M calls: 1.46s C vs 4.07s PL/pgSQL). `build.sh` swaps the engine's
`banker_round` to the C version by default (DROP+CREATE as supabase_admin; PL/pgSQL bodies
resolve it by name). Verified: settlement + all 5 reconciliation invariants still pass with
C rounding in the hot path.

### Hot-spot map & the honest limit
Profiled every hot spot and classified by nature (native code only helps CPU-bound work;
PL/pgSQL is already plan-cached for SQL-bound work):

| Hot spot | Nature | Optimization |
|----------|--------|--------------|
| `create_trade` settlement (4× `process_transfer`, ~2.4ms/trade) | **I/O** (heap inserts + WAL + index) | structural: UNLOGGED book, partitioned ledger, WAL reduction |
| `banker_round` (numeric, half-even) | **CPU** | **native C, 2.8×** (`oc_fastmath`) |
| per-trade stop-order scan | CPU+I/O (was O(n) seq scan) | partial index `9750` → O(log n) |
| `price_level` updates | I/O | UNLOGGED (`9730`) |
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

### Batched ledger writes (`9760`)
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
