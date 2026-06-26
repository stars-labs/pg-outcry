# Launch playbook (Reddit / HN) / 发布预案

Internal checklist + post drafts for announcing pg-outcry. Not part of the product.

## Pre-flight checklist
- [x] README (bilingual, badges, diagram, disclaimer)
- [x] WHY.md (top-tier comparison, 9 diagrams)
- [x] BENCH.md + `scripts/bench.sh` (reproducible numbers)
- [x] LICENSE (AGPL-3.0) + NOTICE, SECURITY.md, CONTRIBUTING.md
- [x] CI green; issue/PR templates
- [x] GitHub Pages workflow (static frontend) — `.github/workflows/pages.yml`
- [x] **Hero screenshot** (web/docs/hero.png — real render via scripts/render-shots.mjs); optional: a GIF still needs a browser capture
- [x] **Live demo** deployed → hosted Supabase (Seoul), seeded, autoconfirm on, faucet; link in README
      `https://xiongchenyu6.github.io/pg-outcry/?api=https://<ref>.supabase.co&anon=<anon key>`
      (the app reads `?api=&anon=` and persists them). Seed it: `scripts/seed-demo.sh` + `scripts/seed-candles.sh`.
- [x] Hero + admin screenshots rendered (web/docs/hero.png, admin.png). TODO(you): set repo Social-preview image (Settings, UI-only) using hero.png

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
