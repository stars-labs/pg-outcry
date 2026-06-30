# Plan: TradingView Lightweight Charts + pure-PG OHLCV datafeed

Goal: replace the hand-drawn SVG candlestick chart with TradingView **Lightweight
Charts** (Apache-2.0, open source, self-hosted), fed by a **pure-PostgreSQL**
server-side OHLCV endpoint. No Advanced-Charts licensing, no UDF datafeed needed —
Lightweight Charts takes plain arrays via `setData()`/`update()`.

## Stage 1: pure-PG server-side OHLCV
**Goal**: an anon-callable `ohlcv(instrument, resolution_s, from, to)` RPC that buckets
`trade_history` with `date_bin` into O/H/L/C/V, epoch-second timestamps.
**Success**: `sb.rpc('ohlcv', …)` returns candles on hosted; CI smoke asserts shape.
**Tests**: smoke-features.mjs — after a trade, ohlcv(60s) returns ≥1 bar with o/h/l/c/v.
**Status**: Not Started

## Stage 2: front-end migration to Lightweight Charts
**Goal**: vendor `lightweight-charts` standalone into `web/public/`, swap `#kline` SVG
for a Lightweight chart; load history from `ohlcv`, stream the live bar from the
existing Realtime trade feed; keep timeframe + symbol switching.
**Success**: chart renders real candles on the Pages demo, updates live on new trades.
**Tests**: manual via chrome-devtools on the live demo (candles draw, TF switch works).
**Status**: Not Started

## Stage 3: cleanup + docs
**Goal**: remove the dead SVG chart code (renderChart/chartView/drawOverlay/WASM candle
calls no longer used); update COMPARISON (server-side OHLCV ◐→✅), README, memory.
**Success**: no dead refs; `node --check`; COMPARISON reflects new state; CI green.
**Status**: Not Started

Notes:
- Lightweight Charts has no built-in drawing tools (that's Advanced Charts). The
  existing localStorage trend-line tool is dropped in Stage 2 (accepted when choosing
  Lightweight); can be re-added later as a custom overlay if wanted.
- Hosted deploy is via `psql` (project convention), not `db push`.
