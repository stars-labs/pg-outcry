**English** · [中文](./DERIVATIVES.zh-CN.md)

# Derivatives & staking in pure Postgres — feasibility + plan

Can margin / futures / staking be done in pure PG, and what extensions help?
[← docs](./README.md) · [← Comparison](./COMPARISON.md)

> **First, the honest finding:** none of [peatio](https://github.com/openware/peatio),
> [OpenCEX](https://github.com/Polygant/OpenCEX), or [OPEX](https://github.com/opexdev/core) implement
> these in **open source** — they're spot exchanges. peatio's margin/perps/P2P live only in Openware's
> *commercial* OpenDAX; OpenCEX/OPEX don't ship them. So there's no OSS reference to copy — the design
> below is the standard exchange architecture mapped onto pure PG.

## Verdict

All three are achievable in pure PostgreSQL with **only `pg_cron` + `pg_net`** (already in use) — **no
new bespoke extension required**. Effort: **staking (small) < spot margin (moderate) < perpetual
futures (large)**. The only inherently-external dependency is a **price oracle** (index/mark for
liquidation & funding), fetched the same way as on-chain deposits. The real cost is the **risk
surface** (liquidations, funding, insurance fund), not the database.

## Extension map (grounded in the Supabase image)

| Extension | Helps with | Status here |
|---|---|---|
| **pg_cron** | accrual / funding / liquidation / unbonding timers | ✅ installed |
| **pg_net** / **http** | external index/oracle price feeds | ✅ installed |
| **pgmq** | durable queues: unbonding, liquidation, funding, withdrawals (vs hand-rolled `SKIP LOCKED`) | ✅ available — **now used for staking unbonding** |
| **pg_partman** | auto-partition time-series (funding payments, mark-price history) | ✅ available |
| **pgsodium** | ed25519 signing in-DB → **Solana/Sui** withdrawals/stake txs natively | ✅ available |
| **supabase_vault** | encrypt the hot signer key at rest if signing in-DB | ✅ installed |
| **wrappers** (FDW) | model an external price API / exchange as a foreign table (oracle) | ✅ available |
| **plpgsql_check** · **pgtap** | static-check + unit-test the large risk engine | ✅ available |
| **pgaudit** | compliance-grade audit logging for the regulated surface | ✅ available |
| _TimescaleDB / toolkit_ | hypertables + continuous aggregates → server-side OHLCV, mark/funding series | ❌ **not in the image** (self-host only) |
| _plv8 / plpython3u_ | in-DB JS/Python (e.g. a secp256k1 lib) | ❌ not available |

**Signing nuance:** **ed25519 chains (Solana, Sui)** can be signed *in-DB* with `pgsodium` (+ key in
`supabase_vault`). **secp256k1 chains (BTC, all EVM, Tron)** have no stock extension → external signer
(current design) or a **custom C extension** compiling `libsecp256k1` (same pattern as `oc_fastmath`).

## 1. Staking — ✅ shipped (migration `9930`)

Stake a currency, earn rewards (APR) via a reward-per-token accumulator (MasterChef pattern, settled
lazily on each interaction — no accrual cron), unstake with an unbonding period.

- Money movement reuses `process_transfer`, so reconciliation holds: **stake** = `WITHDRAWAL` user→MASTER
  (locks principal), **reward** = `DEPOSIT` MASTER→user (issuance, like a faucet), **unbond** =
  `DEPOSIT` MASTER→user after the delay.
- **pgmq** holds the unbonding queue (`pgmq.send(..., delay)`); a **pg_cron** job `process_unbonding()`
  drains matured messages and returns principal.
- RPCs: `stake` / `unstake` / `claim_stake_rewards` (authenticated); views `my_stakes` (live pending
  reward) + `stake_pools`. Verified in `scripts/smoke-features.mjs` (stake → ~10 reward at 10% APR →
  unstake → unbond release → **reconcile() all PASS**).

## 2. Spot margin — ✅ shipped (migration `9940`)

Cross-margin, valued in the EUR quote via last trade prices. `borrow` against collateral (the house
lends from MASTER) with a **max-leverage cap** (total debt ≤ equity·(L−1)); interest accrues lazily;
`repay`; and a `pg_cron` **liquidation monitor** (`check_margin_liquidations`) that marks each account
to the current price and **liquidates** when equity ≤ debt·maintenance_ratio. All money moves via
`process_transfer` (borrow = DEPOSIT MASTER→user, repay/liquidation = user→MASTER), so reconciliation
holds. RPCs `borrow` / `repay` / `my_margin_health` (authenticated); views `my_margin` + `margin_terms`.
Verified in `scripts/smoke-features.mjs` (borrow 2x → over-leverage rejected → repay → interest-driven
liquidation seizes collateral → **reconcile() all PASS**).

**Simplified vs production:** liquidation is a forced settlement at the mark (seize collateral, clear
debt, shortfall borne by the house) rather than routing a market order through the book; no partial
liquidation / insurance fund / ADL. No new extension needed.

## 3. Perpetual futures — ✅ shipped (migration `9950`)

Position-based linear perp (`BTC-PERP`, EUR-margined):
- **Mark price** set by an oracle (`update_perp_mark`, `pg_cron`) from the spot last trade — or
  overridable / fed externally via `pg_net` for a real index.
- **`open_perp` / `close_perp`** — post margin, take a signed position with a **max-leverage cap**;
  close realizes uPnL = size·(mark−entry); payout = margin+PnL (clamped ≥0), all via `process_transfer`.
- **Funding** (`apply_perp_funding`, `pg_cron`) — longs pay shorts when the rate is positive (adjusts
  the margin claim).
- **Liquidation** (`check_perp_liquidations`, `pg_cron`) — seizes margin when equity ≤
  size·mark·maintenance_ratio.
- Views `my_perp` (live uPnL/equity) + `perp_markets`. Verified in `scripts/smoke-features.mjs`
  (open 5x long → mark→130 uPnL 30 → close +30 → liquidation on a drop → funding charge →
  **reconcile() all PASS**).

**Simplified vs production:** one netted position per market, open-from-flat only; the house (MASTER)
is the counterparty/insurance (PnL not netted long-vs-short); liquidation seizes margin at the mark
(no partial close / book routing / ADL). `pg_partman` for funding/mark-price history at scale.

## Roadmap

`staking ✅ → spot margin ✅ → perpetual futures ✅`. Each is opt-in and carries real financial risk — these
sit at the regulated end ([WHY.md §9](./WHY.md#9-when-not-to-use-this)); pg-outcry's core remains a
correctness-first **spot** exchange.
