**English** · [中文](./COMPARISON.zh-CN.md)

# How pg-outcry compares — and what it's missing

A feature comparison against three established open-source exchanges, and an honest gap analysis.
[← Back to docs](./README.md) · [← README](../README.md)

The three references are full exchange **products** (real custody, KYC, fiat). pg-outcry is a
correctness-first **engine**: the database *is* the exchange. So the gaps split into two very
different buckets — (A) external integrations every exchange bolts on regardless of architecture,
and (B) things we can add **in pure SQL** while keeping the "whole exchange in Postgres" thesis.

## Feature matrix

| Capability | [peatio](https://github.com/openware/peatio) (+Barong/Finex) | [OpenCEX](https://github.com/Polygant/OpenCEX) | [OPEX](https://github.com/opexdev/core) | **pg-outcry** |
|---|---|---|---|---|
| Matching engine | ✅ Ruby/Go | ✅ Python | ✅ Kotlin | ✅ **PL/pgSQL** |
| Double-entry ledger + reconciliation | ✅ | ✅ | ✅ (Accountant svc) | ✅ **in-DB, ACID, same tx** |
| Order types | limit/market/stop | limit/market | limit/market | ✅ limit/market/stop-loss/stop-limit · GTC/IOC/FOK |
| On-chain deposits/withdrawals | ✅ hot/warm/cold | ✅ BTC/ETH/BNB/TRX/USDT | ✅ Blockchain Gateway | ✅ **fully in-DB** — HD derivation, signing and broadcast in pure PL/pgSQL (EVM/Tron/Solana; **testnet only**, see below) ([CHAIN.md](./CHAIN.md)) |
| KYC / identity | ✅ Barong | ✅ Sumsub | ✅ Keycloak | ❌ (intentionally skipped) |
| KYT (tx screening) | — | ✅ Scorechain | — | ❌ external vendor |
| 2FA / MFA | ✅ SMS+TOTP | ✅ SMS | ✅ Keycloak | ✅ **via OAuth2 IdP** (GitHub/Google 2FA) |
| Fiat on/off-ramp | ✅ | — | — | ❌ external (payment processor) |
| Per-user API keys (HMAC) | ✅ | ◐ | ✅ | ✅ **pure SQL** |
| Referral / affiliate | — | ✅ | ✅ (Referral svc) | ✅ **pure SQL** |
| Withdrawal whitelist + limits | ✅ | ✅ | ◐ | ✅ **pure SQL** |
| Notifications (email/SMS) | ✅ | ✅ | ✅ | ◐ via Supabase triggers |
| Liquidity / market-making | via vendors | ◐ | — | ❌ demo seeder only |
| Public REST/WS market-data API | ✅ v2 + WS + AMQP | ◐ | ✅ | ◐ PostgREST + Realtime (no FIX) |
| Server-side OHLCV/candles | ✅ | ✅ | ✅ | ✅ **pure-SQL `ohlcv()` RPC** (`date_bin` buckets) |
| Admin / back-office | ✅ | ✅ | ✅ | ✅ approvals/suspend/fees/risk/recon/audit · **role-based RBAC** (config-flag demo mode) |
| Continuous reconciliation monitor | ◐ | ◐ | ✅ | ✅ **pure-SQL** `pg_cron` invariant monitor → `reconcile_alert` |
| Fee tiers (volume-based) | ✅ | ◐ | ◐ | ◐ flat maker/taker |
| Staking / margin / futures | commercial (OpenDAX) | — | — | ◐ **staking ✅ · margin ✅ · perps ✅ pure SQL** ([DERIVATIVES.md](./DERIVATIVES.md)) |
| **Moving parts to run** | Rails + Barong + Finex + RabbitMQ + DB | Django + Redis + RabbitMQ + nodes | ~11 microservices + Kafka + Redis + N×PG | ✅ **1 Postgres + Supabase** |

## Bucket A — external integrations (every exchange bolts these on)

These are **not** a pure-SQL weakness: peatio runs a separate Barong service, OPEX a Blockchain
Gateway + Keycloak, OpenCEX wires Twilio/Sumsub/Scorechain keys. pg-outcry's bet is that the
**accounting is already correct and durable in-DB**, so you attach these at the edges and the
database stays the system-of-record.

- **Blockchain custody** — the one feature that separates "engine" from "product". It splits in two:
  - **Deposits — doable in pure Postgres.** `pg_cron` (1.6, sub-minute) + `pg_net` (outbound HTTP)
    can poll a chain RPC/explorer and credit deposits **inside the database**: a cron job calls
    `net.http_post` to a JSON-RPC node (e.g. Sepolia `eth_getLogs` for ERC-20 `Transfer`) or an
    explorer (Blockstream/mempool.space for BTC, Tronscan for TRON); a follow-up tick parses
    `net._http_response` as `jsonb` and, for each new tx **idempotent by txid** past **N
    confirmations**, runs the deposit-credit path. No external service — unlike peatio/OpenCEX/OPEX,
    which all run a separate gateway. **Use public testnets** (BTC signet, Ethereum **Sepolia**,
    TRON **Shasta**) for a free, no-real-funds demo.
  - **Withdrawals + HD address derivation — also pure Postgres now.** `pgcrypto` has no
    secp256k1/keccak, so we implemented them **in PL/pgSQL**: `00780_crypto_secp256k1_keccak.sql`
    ships keccak256 (Keccak-f[1600]) and deterministic RFC-6979 secp256k1 signing, validated
    against ethers/js-sha3; `pgsodium` covers ed25519 for Solana. On top of that,
    `00810_hd_custody` derives per-user addresses from a vault master seed, and
    `00830`/`00840`/`00900` build, sign and broadcast raw transactions (RLP+EIP-155 for EVM,
    TronGrid txID for Tron, wire format for Solana; native **and** ERC-20/TRC-20/SPL). Broadcast
    goes out over the `http` extension, which works from hosted Supabase. A full USDT
    deposit→withdraw cycle has been proven end-to-end on Tron Nile, signed entirely inside
    Postgres — no gateway, no external signer, unlike peatio/OpenCEX/OPEX.
  - **The security tradeoff is real, and it bounds this.** The master seed lives in the database,
    so compromising the database means compromising the funds. That is why the demo is
    **testnet-only** and customer funding is chain-backed by enforcement
    (`request_deposit` is disabled; `00910_chain_backed_funding_reconcile` reports and reverses
    any unbacked balance). For real value, keep the DB as the orchestrator but move key custody
    out — an HSM or a small external signer — which the send-queue design (`00720`) already
    accommodates.

- **KYC / KYT / SMS / fiat** — vendor API integrations. pg-outcry exposes the *hooks* (account
  status, tiers, limits) and you plug a vendor into the status field. KYC itself is deliberately
  **out of scope** — small/mid venues this targets often don't need vendor KYC to start.

## Bucket B — closable in pure SQL (the on-brand gaps)

Ordered by leverage. The first three are **shipped (pure SQL)** — see [DEVELOPMENT.md](./DEVELOPMENT.md):

1. **Per-user API keys (HMAC)** ✅ — bots/market-makers need programmatic auth, not interactive
   JWT. A `api_key` table + a key→short-lived-JWT exchange RPC (minted in SQL), scoped read/trade.
2. **Referral / affiliate** ✅ — OPEX dedicates a whole microservice; this is trivially pure SQL:
   referral codes, one-time attribution, commission accrued as real ledger entries.
3. **Withdrawal whitelist + limits** ✅ — address allow-list (with a cooling period) + per-window
   limits enforced in `request_withdrawal`. Today it's manual-approval only.
4. **2FA/MFA** ✅ — delegated to the OAuth2 provider (GitHub/Google enforce their own 2FA); mandate it by restricting login to OAuth (disable email/password signup). No separate TOTP to build.
5. **Notifications** — DB triggers → `pg_net`/Edge Function on fills, deposits, withdrawal status.
6. **Server-side OHLCV** ✅ — `ohlcv(instrument, resolution_s, from, to)` buckets `trade_history`
   with `date_bin` into O/H/L/C/V (epoch-aligned), anon-callable, so non-WASM clients (mobile,
   TradingView) get server-computed candles. The terminal chart now loads history from it.
7. **Volume-based fee tiers & maker rebates** — extend the flat fee model.
8. **Documented public API** — publish an OpenAPI for the PostgREST surface + the Realtime channel
   spec, so it's a *real* API, not just "views". (FIX stays out of scope.)

## Out of scope (don't chase for a spot reference exchange)

Margin / futures (advanced, see [DERIVATIVES.md](./DERIVATIVES.md)) carry real risk and sit at the regulated end; P2P, lending, FIX protocol are different products. See
[WHY.md › when NOT to use this](./WHY.md#9-when-not-to-use-this).

## Bottom line

Blockchain custody is no longer the defining gap: derivation, signing and broadcast all run inside
Postgres and are proven on testnets. What bounds it now is the **key-custody tradeoff** (seed in the
DB ⇒ testnet only) plus the product-level items every venue bolts on (KYC/KYT/fiat). Within the pure-SQL philosophy, the
highest-leverage additions are **API keys, referral, and withdrawal security**, which reinforce
rather than dilute the "whole exchange in Postgres" story — and are now shipped (with CI smoke coverage).
