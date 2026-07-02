# OUTCRY — terminal web app

A modern trading terminal for the pure-PG CEX. **Phosphor-terminal** aesthetic
(near-black, phosphor-green, amber alerts, scanlines, tabular monospace).

- **K-line / candlestick chart** (center panel): trades (history + live) are aggregated into
  OHLCV candles **entirely in WASM** (`addTrade`/`candle*`), re-bucketed instantly on timeframe
  switch (1m / 5m / 15m). SVG renders candles + volume bars + last-price line + price axis.
- **WASM** (`wasm/orderbook.ts` → `public/orderbook.wasm`, AssemblyScript): the live
  L2 stream is fed into a native order-book engine that computes best bid/ask, spread
  (bps), mid, **cumulative depth** for the depth chart, **book imbalance**, **market
  VWAP**, and a **banker's-rounding cost preview that is bit-identical to the engine's
  settlement rounding** (`banker_round` / `oc_fastmath`). The book/depth/preview repaint
  every tick from wasm.
- **OAuth2 / Auth** (Supabase GoTrue): GitHub + Google social login and email/password.
- **Realtime**: public market data over **Broadcast** (`md:<symbol>`, events `l2` + `trade`);
  the private feed over **Postgres Changes** (`trade_order`, `wallet_request`) scoped to the
  logged-in user via `realtime.setAuth(jwt)` — RLS delivers only your own rows.
- **No app server**: the browser talks straight to PostgREST (`place_order`, `cancel_order`,
  `my_deposit_address`, `request_withdrawal`, and the `order_book_l2` / `open_orders` / `cash_balances` /
  `instrument_balances` / `wallet_request` / `trade_history` views).

## Run locally

```bash
# 1) backend + demo liquidity
supabase start
supabase db reset
SERVICE="$(supabase status -o json | jq -r .SERVICE_ROLE_KEY)" ./scripts/seed-demo.sh   # from repo root
# (optional) native + tunables: ./scripts/perf-tune-local.sh
# (optional) live L2 ticker:    SERVICE=... node examples/md-ticker.mjs &

# 2) build wasm + serve the app
cd web
npm install
npm run build:wasm
python3 -m http.server 4173      # then open http://127.0.0.1:4173
```

The app defaults to the local Supabase (`http://127.0.0.1:54321` + the standard local
anon key). To point at another project, set in the browser console:
`localStorage.oc_api='https://<ref>.supabase.co'; localStorage.oc_anon='<anon key>'` and reload.

## OAuth2 setup
In `supabase/config.toml` the `[auth.external.github]` / `[auth.external.google]` blocks are
present but `enabled = false`. To turn them on: set `enabled = true`, export
`GITHUB_CLIENT_ID`/`GITHUB_SECRET` (or Google), and add the app origin to
`additional_redirect_urls` (already set to `:4173`). Email/password works out of the box.

## Funding a demo account
A freshly signed-up user has no funds (RLS-scoped). Use **Wallet → Deposit** and
send testnet assets to the assigned address/memo; the SQL watcher credits detected
testnet transfers. For demo K-line history (synthetic back-dated random walk):
`./scripts/seed-candles.sh`.

For local development seeds only, service-role `process_transfer('DEPOSIT','MASTER', ...)`
still exists for synthetic makers/tests. Customer funding that is not backed by `chain_deposit`
is reported by `custody_funding_exposure` and can be reversed by `admin_reverse_unbacked_cash`.

## Back-office (admin)
Open `http://127.0.0.1:4173/admin.html` and sign in with a Supabase Auth user plus the publishable/anon key. This test build is intentionally open: every signed-in user receives admin permissions. The RBAC tables (`admin_operator_role` / `admin_role_permission`) still exist so the hosted demo can be tightened later without rewriting the console.

Keep the **service_role** key server-side only.

## Layout
`index.html` (shell) · `styles.css` (phosphor design) · `app.js` (Supabase + wasm wiring) ·
`wasm/orderbook.ts` (AssemblyScript source) · `public/orderbook.wasm` (compiled) ·
`admin.html`/`admin.css`/`admin.js` (back-office console).
