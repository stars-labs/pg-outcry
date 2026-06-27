# Launch playbook (Reddit / HN)

Internal checklist + post drafts for announcing pg-outcry. Not part of the product.

## Pre-flight checklist
- [x] README (English primary + separate `README.zh-CN.md`, language switcher), badges, diagram, disclaimer
- [x] WHY.md (+ `WHY.zh-CN.md`) — top-tier comparison, 9 diagrams
- [x] BENCH.md + `scripts/bench.sh` (reproducible numbers)
- [x] LICENSE (AGPL-3.0) + NOTICE, SECURITY.md (operator hardening checklist), CONTRIBUTING.md
- [x] CI green (build + 8 smokes on a clean `db reset`); CLI version pinned to avoid release-API rate-limit flakes; issue/PR templates
- [x] GitHub Pages workflow (static frontend) — `.github/workflows/pages.yml`; live + serving latest commit
- [x] **Hero + admin screenshots** rendered (web/docs/hero.png, admin.png via scripts/render-*.mjs); optional: a GIF still needs a browser capture
- [x] **Live demo — trading terminal** → hosted Supabase (Seoul), seeded, autoconfirm on, faucet; link in README.
      Verified end-to-end: signup→faucet→LIMIT + MARKET buy/sell fill→balances visible.
- [x] **Live demo — back-office** (read-only) → `admin.html?...&demo=1` via `demo_admin_overview()` (anon-safe; no service_role exposed). Verified: reconciliation 5/5 PASS.
- [x] **GitHub OAuth** enabled (hosted): site_url + redirect allow-list set; GitHub login round-trips. Email/password also works.
- [x] Public market data anon-readable (order book / tape); per-user RLS verified.

### Out of scope for THIS launch (it's reference/educational OSS, not a real-money venue)
These are the deployer's responsibility before custodying real funds, and are called out in README + SECURITY.md — they are NOT blockers for promoting the project:
- Independent third-party security & financial audit
- Production compliance / KYC-AML / legal & ToS
- Real payment-processor / custody integration
- Production rate-limiting / WAF / DDoS (Supabase provides baseline; app-level guidance in SECURITY.md)
- Formal load testing beyond the reproducible BENCH.md benchmark, on-call / incident-response

### Owner-only manual step (UI, can't be scripted)
- [ ] Set the repo **Social-preview image** (Settings → General, upload web/docs/hero.png)
- [ ] Optional: rotate the DB password & GitHub OAuth secret that were pasted in chat

## Capturing visuals (local)
```bash
cd web && python3 -m http.server 4173
# http://127.0.0.1:4173        → sign up (email), screenshot chart + indicators + a drawn trendline
# http://127.0.0.1:4173/admin.html → paste service_role key, screenshot approvals + reconciliation
# record a 10–15s GIF: place an order, watch tape + candle update
# put files in web/docs/ and reference them in README
```

## Post draft

**Title (pick one):**
- I built a complete crypto exchange that runs *entirely inside PostgreSQL* — matching + settlement in PL/pgSQL, no app server (AGPL, with a WASM terminal)
- Show r/PostgreSQL: the database *is* the exchange — PostgREST + Realtime + RLS, double-entry ledger, benchmarked

**Body:**
> **TL;DR** — a working central exchange where the matching engine and double-entry settlement
> are PL/pgSQL running in **one ACID transaction**. No matching microservice, no Kafka, no Redis.
> PostgREST is the API, Supabase Realtime is market data + per-user RLS feeds, Supabase Auth is login.
> Ships with a WASM trading terminal (candles + SMA/EMA/Bollinger/VWAP/RSI/MACD/KDJ/ATR + drawing tools)
> and an admin back-office (approvals, reconciliation, risk, audit).
>
> **Why** — top-tier exchanges run bespoke C++ engines + big platform teams. Small/mid exchanges
> can't. This gives them exchange-grade correctness — append-only ledger, reconciliation invariants,
> per-user RLS, wallet approvals, risk limits — at a cost/complexity one or two engineers can run.
> One PostgreSQL + Supabase instead of 10–15 services.
>
> **Benchmark** — ~200–270 *durable, double-entry settled* trades/sec/symbol at ~3.5 ms p50 on a
> single untuned Postgres, scaling with symbols (per-symbol advisory-lock isolation). Honest caveat:
> ms-scale durable, **not** µs in-memory HFT — and I say exactly when not to use it.
>
> **Stack** — PostgreSQL · PostgREST · Supabase Realtime · Supabase Auth · WebAssembly (AssemblyScript)
> + a custom C extension for a hot path. AGPL-3.0 (matching core derives from open-outcry).
> Reference/educational, not audited.
>
> Architecture + side-by-side comparison with diagrams: WHY.md. Repo: <link>. Feedback very welcome —
> especially from people who've run real matching/ledger systems.

**Where:** r/PostgreSQL (best), r/SideProject, r/selfhosted, r/programming, r/webdev (WASM angle).
HN: "Show HN: A central exchange that runs entirely inside PostgreSQL".

**Engagement tips:** reply fast in the first 2 hours; lead the comments with the honest
"when NOT to use this" (§9 of WHY.md) — it preempts the top skeptical reply and builds trust.
