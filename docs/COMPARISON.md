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
| On-chain deposits/withdrawals | ✅ hot/warm/cold | ✅ BTC/ETH/BNB/TRX/USDT | ✅ Blockchain Gateway | ◐ **deposits in-DB** (pg_cron+pg_net; Sepolia/Tron-Nile/Solana) + **withdrawal queue** → external signer ([CHAIN.md](./CHAIN.md)) |
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
| Server-side OHLCV/candles | ✅ | ✅ | ✅ | ◐ computed client-side in WASM |
| Admin / back-office | ✅ | ✅ | ✅ | ✅ approvals/suspend/fees/risk/recon/audit |
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
  - **Withdrawals + HD address derivation — need a signer.** `pgcrypto` has no secp256k1/keccak, so
    building & **signing** a raw transaction (and deriving per-user addresses) can't be done in stock
    SQL. Either a signing **extension** (C / `plpython3u` / `plv8` — keeps it in-DB but puts hot keys
    in the database, a real security tradeoff) or a **tiny external signer** (the DB still decides
    *what* to send; broadcasting is just `pg_net`). **Shipped:** the pure-PG deposit watcher
    (migration `9920` + opt-in Sepolia / Tron Nile / Solana pollers) **and** a DB-owned withdrawal
    send-queue (`9925`: `next_withdrawal_to_sign` with `SKIP LOCKED` claim, `mark_withdrawal_broadcast/
    confirmed`) with an example external signer. Full guide: **[CHAIN.md](./CHAIN.md)**.
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
6. **Server-side OHLCV** — a continuous aggregate / view + RPC so non-WASM clients (mobile,
   TradingView) get candles. Today candles exist only in the WASM client.
7. **Volume-based fee tiers & maker rebates** — extend the flat fee model.
8. **Documented public API** — publish an OpenAPI for the PostgREST surface + the Realtime channel
   spec, so it's a *real* API, not just "views". (FIX stays out of scope.)

## Out of scope (don't chase for a spot reference exchange)

Margin / futures (advanced, see [DERIVATIVES.md](./DERIVATIVES.md)) carry real risk and sit at the regulated end; P2P, lending, FIX protocol are different products. See
[WHY.md › when NOT to use this](./WHY.md#9-when-not-to-use-this).

## Bottom line

The defining gap is **blockchain custody**, and that is intentionally external (a gateway worker on
top of an already-correct ledger — demoable on public testnets). Within the pure-SQL philosophy, the
highest-leverage additions are **API keys, referral, and withdrawal security**, which reinforce
rather than dilute the "whole exchange in Postgres" story — and are now shipped (with CI smoke coverage).
