// OUTCRY terminal — pure-PG CEX client.
// Supabase: PostgREST (RPC + views) · Realtime (broadcast md + private postgres_changes) · Auth (OAuth2/email).
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// Backend config resolution order: URL params (?api=&anon=, e.g. for a shareable Pages demo)
// → localStorage → local-supabase default. URL params are persisted so reloads keep them.
const _q = new URLSearchParams(location.search);
if (_q.get("api"))  localStorage.setItem("oc_api",  _q.get("api"));
if (_q.get("anon")) localStorage.setItem("oc_anon", _q.get("anon"));
const CONFIG = {
  API:  localStorage.getItem("oc_api")  || "http://127.0.0.1:54321",
  ANON: localStorage.getItem("oc_anon") ||
    "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9.CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0",
};

const sb = createClient(CONFIG.API, CONFIG.ANON, { auth: { persistSession: true, detectSessionInUrl: true } });
const $ = (s) => document.querySelector(s);
const el = (s) => document.getElementById(s);

// ---------- WASM order-book engine ----------
let W = null;
async function loadWasm() {
  const res = await fetch("public/orderbook.wasm");
  const { instance } = await WebAssembly.instantiate(await res.arrayBuffer(), {
    env: { abort() { throw new Error("wasm abort"); } },
  });
  W = instance.exports;
}

// ---------- state ----------
let SYM = "BTC_EUR";
let SYMBOLS = ["BTC_EUR"];
let side = "BUY", otype = "LIMIT";
let book = { bids: [], asks: [] };     // raw L2 from PostgREST/broadcast
let mdChan = null, privChan = null, pollTimer = null;
let lastTradePx = null;
let rawTrades = [];      // {ts(sec), price, amount} chronological — replayed into wasm candle engine
let tf = 60;             // candle interval (s)
const MA = { sma: { on: true, p: 7 }, ema: { on: true, p: 25 },
             boll: { on: true, p: 20, k: 2 }, vma: { on: true, p: 14 },
             vwap: { on: true } };  // overlays (computed in wasm)
let osc = "rsi";         // oscillator sub-pane: 'rsi' | 'macd' | 'kdj' | 'atr' | 'off'
let chartView = null;    // {lo,hi,priceH,plotW,cw,N,t0,t1} — transform for the drawing layer
let tool = "cursor";     // drawing tool
let drawings = [];       // committed drawings (anchored in price+time), persisted per symbol
let drag = null, lastMouse = null;

const PREC = 2; // quote decimals for BTC_EUR (EUR)
const fmt = (n, d = 2) => (n == null || isNaN(n)) ? "—" : Number(n).toLocaleString(undefined, { minimumFractionDigits: d, maximumFractionDigits: d });

// ---------- toasts ----------
function toast(msg, kind = "") {
  const t = document.createElement("div");
  t.className = "toast " + kind; t.textContent = msg;
  el("toasts").appendChild(t);
  setTimeout(() => t.remove(), 4200);
}

// ============================================================ AUTH
let registerMode = false;
el("swapMode").onclick = () => {
  registerMode = !registerMode;
  el("emailGo").textContent = registerMode ? "Create account →" : "Access terminal →";
  el("swapMode").textContent = registerMode ? "Have an account? Sign in →" : "No account? Register →";
  el("authMsg").textContent = "";
};
document.querySelectorAll("[data-oauth]").forEach((b) => {
  b.onclick = async () => {
    const provider = b.dataset.oauth;
    const { error } = await sb.auth.signInWithOAuth({ provider, options: { redirectTo: location.href } });
    if (error) el("authMsg").textContent = `OAuth (${provider}): ${error.message} — configure provider in supabase/config.toml`;
  };
});
el("emailGo").onclick = async () => {
  const email = el("email").value.trim(), password = el("password").value;
  if (!email || !password) { el("authMsg").textContent = "email + password required"; return; }
  el("authMsg").textContent = "…";
  const fn = registerMode ? sb.auth.signUp : sb.auth.signInWithPassword;
  const { error } = await fn.call(sb.auth, { email, password });
  if (error) el("authMsg").textContent = error.message;
  else if (registerMode) el("authMsg").textContent = "Registered. Signing in…";
};
el("logout").onclick = async () => { await sb.auth.signOut(); location.reload(); };

sb.auth.onAuthStateChange((_e, session) => {
  if (session) enterTerminal(session);
});

// ============================================================ TERMINAL
async function enterTerminal(session) {
  el("gate").style.display = "none";
  el("app").classList.add("live");
  el("whoami").textContent = session.user.email || session.user.id.slice(0, 8);
  await sb.realtime.setAuth(session.access_token);  // scope private feed to this user

  await loadSymbols();
  buildSymbolPicker();
  await selectSymbol(SYM);
  subscribePrivate();
  await refreshBlotter();
  if (_q.get("demo") === "1" && !el("faucetBtn")) {   // public demo: let visitors self-fund to trade
    const b = document.createElement("button");
    b.id = "faucetBtn"; b.className = "swap"; b.textContent = "💰 Demo funds";
    b.onclick = async () => { const { error } = await sb.rpc("demo_faucet"); if (error) toast(error.message, "err"); else { toast("Demo funds added — you can trade now"); refreshBlotter(); } };
    el("logout").parentNode.insertBefore(b, el("logout"));
  }
  if (_q.get("demo") === "1" && !el("adminLink")) {   // jump to the read-only back-office demo
    const a = document.createElement("a");
    a.id = "adminLink"; a.className = "swap"; a.textContent = "⚙ Back-office";
    a.href = "admin.html" + location.search; a.target = "_blank"; a.rel = "noopener";
    el("logout").parentNode.insertBefore(a, el("logout"));
  }
}

async function loadSymbols() {
  const { data } = await sb.from("instrument").select("name").order("name");
  if (data?.length) SYMBOLS = data.map((r) => r.name);
}
function buildSymbolPicker() {
  el("symPick").innerHTML = "";
  SYMBOLS.forEach((s) => {
    const b = document.createElement("button");
    b.textContent = s; b.className = s === SYM ? "on" : "";
    b.onclick = () => selectSymbol(s);
    el("symPick").appendChild(b);
  });
}

async function selectSymbol(s) {
  SYM = s;
  buildSymbolPicker();
  el("bookSym").textContent = s; el("ticketSym").textContent = s;
  const al = el("amtLabel"); if (al) al.textContent = `Amount (${s.split("_")[0]})`;
  const cs = el("chartSym"); if (cs) cs.textContent = s;
  rawTrades = []; loadDrawings(); if (W) { W.candleReset(); renderChart(); }
  if (mdChan) { sb.removeChannel(mdChan); mdChan = null; }
  if (pollTimer) clearInterval(pollTimer);
  await pollBook(); await pollTape(); await loadCandles();
  subscribeMarketData();
  pollTimer = setInterval(() => { pollBook(); }, 1500); // fallback if no ticker running
}

// ---------- market data ----------
async function pollBook() {
  const { data } = await sb.from("order_book_l2").select("side,price,volume").eq("instrument", SYM);
  if (!data) return;
  book.bids = data.filter((r) => r.side === "BUY").map((r) => [+r.price, +r.volume]).sort((a, b) => b[0] - a[0]);
  book.asks = data.filter((r) => r.side === "SELL").map((r) => [+r.price, +r.volume]).sort((a, b) => a[0] - b[0]);
  renderBook();
}
async function pollTape() {
  const { data } = await sb.from("trade_history").select("price,amount,created_at").eq("instrument", SYM).order("created_at", { ascending: false }).limit(300);
  if (!data) return;
  el("tape").innerHTML = "";
  data.slice(0, 40).forEach((t) => addTape(+t.price, +t.amount, t.created_at, false));
  // chronological feed for the wasm candle engine
  rawTrades = data.map((t) => ({ ts: new Date(t.created_at).getTime() / 1000, price: +t.price, amount: +t.amount })).reverse();
}

// ---------- candles (server-side OHLCV → WASM candle engine) ----------
// History comes from the pure-SQL `ohlcv` RPC (complete, multi-resolution) instead
// of aggregating the last N raw trades client-side. Each server candle is rebuilt
// exactly by replaying 4 synthetic trades into the same WASM bucket — open (carrying
// the full volume), then high, low, close — so every WASM indicator keeps working.
const MAX_BARS = 500;   // cap history so 1m over 7 days doesn't draw 10k candles
async function loadCandles() {
  if (!W) return;
  const to = new Date(), from = new Date(to.getTime() - tf * MAX_BARS * 1000);
  const { data, error } = await sb.rpc("ohlcv",
    { p_instrument: SYM, p_resolution: tf, p_from: from.toISOString(), p_to: to.toISOString() });
  W.candleReset(); W.candleSetInterval(tf);
  if (error) { console.warn("ohlcv load failed:", error.message); }
  else if (Array.isArray(data)) {
    for (const k of data) {
      const t = +k.t, v = +k.v;
      W.addTrade(t, +k.o, v); W.addTrade(t, +k.h, 0);
      W.addTrade(t, +k.l, 0); W.addTrade(t, +k.c, 0);
    }
  }
  renderChart();
}
// Coalesce chart repaints to one per animation frame: a burst of live trades
// updates the WASM candle each time but only repaints the SVG once per frame.
let chartDirty = false;
function scheduleChartRender() {
  if (chartDirty) return;
  chartDirty = true;
  requestAnimationFrame(() => { chartDirty = false; renderChart(); });
}
function onLiveTrade(px, am, tsIso) {
  const ts = new Date(tsIso || Date.now()).getTime() / 1000;
  rawTrades.push({ ts, price: px, amount: am });
  if (rawTrades.length > 8000) rawTrades = rawTrades.slice(-6000);
  if (W) { W.addTrade(ts, px, am); scheduleChartRender(); }
}
function renderChart() {
  if (!W) return;
  const svg = el("kline"); const Wd = 1000, H = 460;
  const n = W.candleCount();
  if (n === 0) { svg.innerHTML = `<text x="500" y="230" text-anchor="middle" class="k-axis">awaiting trades…</text>`; el("ohlc").innerHTML = ""; return; }
  const N = Math.min(n, 90);                    // last 90 candles
  const start = n - N;
  const padR = 64, padB = 60;                   // axis gutters
  const plotW = Wd - padR, priceH = H - padB;
  let lo = W.candleMin(N), hi = W.candleMax(N);
  if (MA.boll.on) {                       // expand scale so bands fit
    W.computeBoll(MA.boll.p, MA.boll.k);
    for (let i = start; i < n; i++) { const u = W.bollUp(i), l = W.bollLo(i);
      if (!isNaN(u) && u > hi) hi = u; if (!isNaN(l) && l < lo) lo = l; }
  }
  const pad = (hi - lo) * 0.06 || hi * 0.01 || 1; lo -= pad; hi += pad;
  const vmax = W.candleVolMax(N) || 1;
  const x = (i) => (i / N) * plotW;
  const cw = Math.max(2, plotW / N * 0.62);
  const py = (p) => priceH - ((p - lo) / (hi - lo)) * priceH;
  const vy = (v) => H - (v / vmax) * (padB - 14);

  let g = "";
  // horizontal price grid + axis labels (5 lines)
  for (let k = 0; k <= 4; k++) {
    const p = lo + (hi - lo) * (k / 4), yy = py(p);
    g += `<line class="k-grid" x1="0" y1="${yy}" x2="${plotW}" y2="${yy}"/>`;
    g += `<text class="k-axis" x="${plotW + 6}" y="${yy + 3}">${fmt(p)}</text>`;
  }
  // candles + volume
  for (let i = 0; i < N; i++) {
    const idx = start + i;
    const o = W.candleOpen(idx), h = W.candleHigh(idx), l = W.candleLow(idx), c = W.candleClose(idx), v = W.candleVol(idx);
    const up = c >= o, cls = up ? "up" : "down", cx = x(i) + cw / 2;
    g += `<rect class="vol-${cls}" x="${x(i)}" y="${vy(v)}" width="${cw}" height="${H - vy(v)}"/>`;
    g += `<line class="k-wick-${cls}" x1="${cx}" y1="${py(h)}" x2="${cx}" y2="${py(l)}"/>`;
    const top = py(Math.max(o, c)), bh = Math.max(1, Math.abs(py(o) - py(c)));
    g += `<rect class="k-${cls}" x="${x(i)}" y="${top}" width="${cw}" height="${bh}"/>`;
  }
  // moving-average overlays (computed in wasm, drawn as gap-aware paths)
  const maPath = (atFn) => {
    let d = "", penDown = false;
    for (let i = 0; i < N; i++) {
      const v = atFn(start + i);
      if (isNaN(v) || v <= 0) { penDown = false; continue; }
      const X = (x(i) + cw / 2).toFixed(1), Y = py(v).toFixed(1);
      d += (penDown ? "L" : "M") + X + " " + Y + " "; penDown = true;
    }
    return d;
  };
  let maLegend = "";
  if (MA.boll.on) {                         // Bollinger band fill + bounds + mid (computeBoll already run for scaling)
    const U = [], L = [];
    for (let i = 0; i < N; i++) { const idx = start + i, u = W.bollUp(idx); if (isNaN(u)) continue;
      const cx = x(i) + cw / 2; U.push([cx, py(u)]); L.push([cx, py(W.bollLo(idx))]); }
    if (U.length > 1) {
      const upD = U.map((p) => `${p[0].toFixed(1)} ${p[1].toFixed(1)}`).join(" L");
      const loRev = L.map((p) => `${p[0].toFixed(1)} ${p[1].toFixed(1)}`).reverse().join(" L");
      g += `<path class="k-boll-fill" d="M${upD} L${loRev} Z"/>`;
      g += `<path class="k-boll-line" d="M${upD}"/>`;
      g += `<path class="k-boll-line" d="M${L.map((p) => p[0].toFixed(1) + " " + p[1].toFixed(1)).join(" L")}"/>`;
      g += `<path class="k-boll-mid" d="${maPath((i) => W.bollMid(i))}"/>`;
    }
    const u = W.bollUp(n - 1), l = W.bollLo(n - 1);
    maLegend += `<span class="ma-boll">BB${MA.boll.p} <b>${isNaN(l) ? "—" : fmt(l)}</b>·<b>${isNaN(u) ? "—" : fmt(u)}</b></span>`;
  }
  if (MA.sma.on) { W.computeSma(MA.sma.p); g += `<path class="k-sma" d="${maPath((i) => W.smaAt(i))}"/>`;
    const v = W.smaAt(n - 1); maLegend += `<span class="ma-sma">MA${MA.sma.p} <b>${isNaN(v) ? "—" : fmt(v)}</b></span>`; }
  if (MA.ema.on) { W.computeEma(MA.ema.p); g += `<path class="k-ema" d="${maPath((i) => W.emaAt(i))}"/>`;
    const v = W.emaAt(n - 1); maLegend += `<span class="ma-ema">EMA${MA.ema.p} <b>${isNaN(v) ? "—" : fmt(v)}</b></span>`; }
  if (MA.vwap.on) {                         // anchored VWAP overlay (computed in wasm)
    W.computeVwap();
    g += `<path class="k-vwap" d="${maPath((i) => W.vwapAt(i))}"/>`;
    const v = W.vwapAt(n - 1); maLegend += `<span class="ma-vwap">VWAP <b>${isNaN(v) ? "—" : fmt(v)}</b></span>`;
  }
  if (MA.vma.on) {                          // volume MA line over the volume bars
    W.computeVolSma(MA.vma.p);
    let d = "", pen = false;
    for (let i = 0; i < N; i++) { const v = W.volSmaAt(start + i); if (isNaN(v)) { pen = false; continue; }
      d += (pen ? "L" : "M") + (x(i) + cw / 2).toFixed(1) + " " + vy(v).toFixed(1) + " "; pen = true; }
    g += `<path class="k-vma" d="${d}"/>`;
    const v = W.volSmaAt(n - 1); maLegend += `<span class="ma-vma">VMA${MA.vma.p} <b>${isNaN(v) ? "—" : fmt(v, 3)}</b></span>`;
  }

  // last price line
  const last = W.candleClose(n - 1), ly = py(last);
  g += `<line class="k-last" x1="0" y1="${ly}" x2="${plotW}" y2="${ly}"/>`;
  g += `<rect x="${plotW}" y="${ly - 8}" width="${padR}" height="16" fill="var(--amber)"/><text class="k-lastlbl" x="${plotW + 5}" y="${ly + 3}" style="font-size:11px;font-family:var(--mono)">${fmt(last)}</text>`;
  svg.innerHTML = g;

  const li = n - 1;
  const o = W.candleOpen(li), h = W.candleHigh(li), l = W.candleLow(li), c = W.candleClose(li);
  const cl = c >= o ? "up" : "down";
  el("ohlc").innerHTML = `<span>O <b class="${cl}">${fmt(o)}</b></span><span>H <b class="${cl}">${fmt(h)}</b></span><span>L <b class="${cl}">${fmt(l)}</b></span><span>C <b class="${cl}">${fmt(c)}</b></span>` + maLegend;
  chartView = { lo, hi, priceH, plotW, cw, N, t0: W.candleTime(start), t1: W.candleTime(n - 1) };
  drawOverlay();
  renderOsc();
}

// ───────────────────────── chart drawing tools ─────────────────────────
const VB = 460;  // #draw viewBox height matches #kline
function p2y(p) { const v = chartView; return v.priceH - ((p - v.lo) / (v.hi - v.lo)) * v.priceH; }
function y2p(y) { const v = chartView; return v.lo + (v.priceH - y) / v.priceH * (v.hi - v.lo); }
function firstX() { return chartView.cw / 2; }
function lastX() { const v = chartView; return ((v.N - 1) / v.N) * v.plotW + v.cw / 2; }
function t2x(t) { const v = chartView; return v.t1 === v.t0 ? firstX() : firstX() + (t - v.t0) / (v.t1 - v.t0) * (lastX() - firstX()); }
function x2t(x) { const v = chartView; return v.t1 === v.t0 ? v.t0 : v.t0 + (x - firstX()) / (lastX() - firstX()) * (v.t1 - v.t0); }
function evToSvg(e) { const r = el("draw").getBoundingClientRect(); return { x: (e.clientX - r.left) / r.width * 1000, y: (e.clientY - r.top) / r.height * VB }; }
function loadDrawings() { try { drawings = JSON.parse(localStorage.getItem("oc_draw_" + SYM) || "[]"); } catch { drawings = []; } }
function saveDrawings() { localStorage.setItem("oc_draw_" + SYM, JSON.stringify(drawings)); }

function segSvg(d, cls) {
  if (d.type === "rect") {
    const x1 = t2x(d.t1), y1 = p2y(d.p1), x2 = t2x(d.t2), y2 = p2y(d.p2);
    return `<rect class="d-rect ${cls}" x="${Math.min(x1,x2).toFixed(1)}" y="${Math.min(y1,y2).toFixed(1)}" width="${Math.abs(x2-x1).toFixed(1)}" height="${Math.abs(y2-y1).toFixed(1)}"/>`;
  }
  let x1 = t2x(d.t1), y1 = p2y(d.p1), x2 = t2x(d.t2), y2 = p2y(d.p2);
  if (d.type === "ray") { const dx = x2 - x1, dy = y2 - y1; if (dx > 0) { const f = (1000 - x1) / dx; x2 = 1000; y2 = y1 + dy * f; } }
  const handles = cls === "prev" ? "" : `<circle class="d-handle" cx="${t2x(d.t1).toFixed(1)}" cy="${p2y(d.p1).toFixed(1)}" r="2.5"/><circle class="d-handle" cx="${t2x(d.t2).toFixed(1)}" cy="${p2y(d.p2).toFixed(1)}" r="2.5"/>`;
  return `<line class="d-line ${cls}" x1="${x1.toFixed(1)}" y1="${y1.toFixed(1)}" x2="${x2.toFixed(1)}" y2="${y2.toFixed(1)}"/>${handles}`;
}
function drawOverlay() {
  const svg = el("draw"); if (!chartView) { svg.innerHTML = ""; return; }
  let g = "";
  for (const d of drawings) {
    if (d.type === "hline") { const y = p2y(d.p).toFixed(1); g += `<line class="d-hline" x1="0" y1="${y}" x2="1000" y2="${y}"/><text x="4" y="${(+y-3)}" style="fill:var(--ma-sma);font-size:10px;font-family:var(--mono)">${fmt(d.p)}</text>`; }
    else g += segSvg(d, "");
  }
  if (drag) g += segSvg(drag, "prev");
  if (lastMouse) {
    const m = lastMouse;
    g += `<line class="xhair" x1="${m.x.toFixed(1)}" y1="0" x2="${m.x.toFixed(1)}" y2="${VB}"/><line class="xhair" x1="0" y1="${m.y.toFixed(1)}" x2="1000" y2="${m.y.toFixed(1)}"/>`;
    g += `<rect x="936" y="${(m.y-7).toFixed(1)}" width="64" height="14" fill="var(--amber)"/><text x="940" y="${(m.y+3).toFixed(1)}" style="fill:#1a1206;font-size:10px;font-family:var(--mono)">${fmt(y2p(m.y))}</text>`;
    const ts = x2t(m.x); if (isFinite(ts)) g += `<text x="${m.x.toFixed(1)}" y="455" text-anchor="middle" style="fill:var(--amber);font-size:10px;font-family:var(--mono)">${new Date(ts*1000).toLocaleTimeString([], {hour:"2-digit",minute:"2-digit"})}</text>`;
  }
  svg.innerHTML = g;
}

(function wireDrawing() {
  const dz = el("draw");
  document.querySelectorAll("#drawTools button").forEach((b) => b.onclick = () => {
    const t = b.dataset.tool;
    if (t === "clear") { drawings = []; saveDrawings(); drawOverlay(); return; }
    tool = t;
    document.querySelectorAll("#drawTools button").forEach((x) => x.classList.toggle("on", x === b));
  });
  dz.addEventListener("mousedown", (e) => {
    if (!chartView || tool === "cursor") return;
    const s = evToSvg(e), t = x2t(s.x), p = y2p(s.y);
    if (tool === "hline") { drawings.push({ type: "hline", p }); saveDrawings(); drawOverlay(); return; }
    drag = { type: tool, t1: t, p1: p, t2: t, p2: p };
  });
  dz.addEventListener("mousemove", (e) => { if (!chartView) return; lastMouse = evToSvg(e); if (drag) { lastMouse && (drag.t2 = x2t(lastMouse.x), drag.p2 = y2p(lastMouse.y)); } drawOverlay(); });
  dz.addEventListener("mouseleave", () => { lastMouse = null; drawOverlay(); });
  window.addEventListener("mouseup", () => { if (drag) { drawings.push(drag); drag = null; saveDrawings(); drawOverlay(); } });
})();

// RSI / MACD oscillator sub-pane (all computed in wasm)
function renderOsc() {
  if (!W) return;
  const wrap = el("oscWrap"), svg = el("osc");
  if (osc === "off") { wrap.classList.add("off"); el("oscVal").innerHTML = ""; return; }
  wrap.classList.remove("off");
  const H = 130, Wd = 1000, n = W.candleCount();
  if (n === 0) { svg.innerHTML = ""; el("oscVal").innerHTML = ""; return; }
  const N = Math.min(n, 90), start = n - N, padR = 64, plotW = Wd - padR;
  const x = (i) => (i / N) * plotW, cw = Math.max(2, plotW / N * 0.62);
  const gapLine = (atFn, yFn, cls) => {
    let d = "", pen = false;
    for (let i = 0; i < N; i++) { const v = atFn(start + i); if (isNaN(v)) { pen = false; continue; }
      d += (pen ? "L" : "M") + (x(i) + cw / 2).toFixed(1) + " " + yFn(v).toFixed(1) + " "; pen = true; }
    return `<path class="${cls}" d="${d}"/>`;
  };
  let g = "", val = "";
  if (osc === "rsi") {
    W.computeRsi(14);
    const ry = (v) => H - (v / 100) * H;
    g += `<rect class="o-zone" x="0" y="0" width="${plotW}" height="${ry(70).toFixed(1)}"/>`;
    g += `<rect class="o-zone" x="0" y="${ry(30).toFixed(1)}" width="${plotW}" height="${(H - ry(30)).toFixed(1)}"/>`;
    [30, 50, 70].forEach((lv) => { g += `<line class="o-guide" x1="0" y1="${ry(lv)}" x2="${plotW}" y2="${ry(lv)}"/><text class="o-axis" x="${plotW + 5}" y="${ry(lv) + 3}">${lv}</text>`; });
    g += gapLine((i) => W.rsiAt(i), ry, "o-rsi");
    const last = W.rsiAt(n - 1); val = `<span class="v-rsi">RSI14 <b>${isNaN(last) ? "—" : last.toFixed(1)}</b></span>`;
  } else if (osc === "kdj") {
    W.computeKdj(9);
    let lo = W.kdjMin(N), hi = W.kdjMax(N); if (hi - lo < 1) { lo -= 5; hi += 5; } const pad = (hi - lo) * 0.05; lo -= pad; hi += pad;
    const ky = (v) => H - ((v - lo) / (hi - lo)) * H;
    [20, 50, 80].forEach((lv) => { if (lv > lo && lv < hi) g += `<line class="o-guide" x1="0" y1="${ky(lv)}" x2="${plotW}" y2="${ky(lv)}"/><text class="o-axis" x="${plotW + 5}" y="${ky(lv) + 3}">${lv}</text>`; });
    g += gapLine((i) => W.kdjJ(i), ky, "o-j") + gapLine((i) => W.kdjK(i), ky, "o-k") + gapLine((i) => W.kdjD(i), ky, "o-d");
    val = `<span class="v-k">K <b>${W.kdjK(n - 1).toFixed(1)}</b></span><span class="v-d">D <b>${W.kdjD(n - 1).toFixed(1)}</b></span><span class="v-j">J <b>${W.kdjJ(n - 1).toFixed(1)}</b></span>`;
  } else if (osc === "atr") {
    W.computeAtr(14);
    const amax = W.atrMax(N) * 1.1 || 1, ay = (v) => H - (v / amax) * H;
    // area fill under ATR
    let pts = "", first = null, last = null;
    for (let i = 0; i < N; i++) { const v = W.atrAt(start + i); if (isNaN(v)) continue; const X = x(i) + cw / 2; if (first === null) first = X; last = X; pts += `${X.toFixed(1)} ${ay(v).toFixed(1)} L`; }
    if (first !== null) g += `<path class="o-atr-fill" d="M${first} ${H} L${pts}${last} ${H} Z"/>`;
    g += gapLine((i) => W.atrAt(i), ay, "o-atr");
    [0.25, 0.5, 0.75].forEach((f) => { g += `<line class="o-guide" x1="0" y1="${ay(amax * f)}" x2="${plotW}" y2="${ay(amax * f)}"/><text class="o-axis" x="${plotW + 5}" y="${ay(amax * f) + 3}">${fmt(amax * f)}</text>`; });
    const v = W.atrAt(n - 1); val = `<span class="v-atr">ATR14 <b>${isNaN(v) ? "—" : fmt(v)}</b></span>`;
  } else {
    W.computeMacd(12, 26, 9);
    const m = W.macdAbsMax(N) || 1, my = (v) => H / 2 - (v / m) * (H / 2 - 6);
    g += `<line class="o-guide" x1="0" y1="${(H / 2).toFixed(1)}" x2="${plotW}" y2="${(H / 2).toFixed(1)}"/>`;
    for (let i = 0; i < N; i++) { const h = W.macdHistAt(start + i); if (isNaN(h)) continue;
      const y0 = my(0), y1 = my(h), top = Math.min(y0, y1), hh = Math.max(1, Math.abs(y1 - y0));
      g += `<rect class="o-hist-${h >= 0 ? "up" : "down"}" x="${x(i).toFixed(1)}" y="${top.toFixed(1)}" width="${cw.toFixed(1)}" height="${hh.toFixed(1)}"/>`; }
    g += gapLine((i) => W.macdAt(i), my, "o-macd") + gapLine((i) => W.macdSigAt(i), my, "o-sig");
    const mv = W.macdAt(n - 1), sv = W.macdSigAt(n - 1), hv = W.macdHistAt(n - 1);
    val = `<span class="v-macd">MACD <b>${isNaN(mv) ? "—" : mv.toFixed(3)}</b></span><span class="v-sig">SIG <b>${isNaN(sv) ? "—" : sv.toFixed(3)}</b></span><span>HIST <b>${isNaN(hv) ? "—" : hv.toFixed(3)}</b></span>`;
  }
  svg.innerHTML = g; el("oscVal").innerHTML = val;
}
function subscribeMarketData() {
  mdChan = sb.channel("md:" + SYM)
    .on("broadcast", { event: "l2" }, ({ payload }) => {
      book.bids = (payload.bids || []).map((x) => [+x.price, +x.volume]);
      book.asks = (payload.asks || []).map((x) => [+x.price, +x.volume]);
      renderBook();
      setConn(true);
    })
    .on("broadcast", { event: "trade" }, ({ payload }) => {
      addTape(+payload.price, +payload.amount, payload.ts, true);
      setLast(+payload.price);
      onLiveTrade(+payload.price, +payload.amount, payload.ts);
    })
    .subscribe((st) => setConn(st === "SUBSCRIBED"));
}

// ---------- render: book + depth (WASM) ----------
function feedWasm() {
  W.reset(0); book.bids.forEach(([p, v]) => W.push(0, p, v));
  W.reset(1); book.asks.forEach(([p, v]) => W.push(1, p, v));
}
function renderBook() {
  if (!W) return;
  feedWasm();
  const maxc = W.maxCum() || 1;
  const rowsHtml = (arr, kind, cum) => arr.slice(0, 12).map(([p, v], i) => {
    const c = cum(i);
    return `<div class="row ${kind}" data-px="${p}">
      <span class="px mono-num">${fmt(p)}</span><span class="sz mono-num">${fmt(v, 4)}</span>
      <span class="bar" style="width:${Math.min(100, (c / maxc) * 100)}%"></span></div>`;
  }).join("");
  // asks shown ascending but visually nearest-mid at bottom -> reverse for display
  el("asks").innerHTML = rowsHtml(book.asks, "ask", (i) => W.cumAsk(i));
  el("bids").innerHTML = rowsHtml(book.bids, "bid", (i) => W.cumBid(i));
  el("asks").querySelectorAll(".row").forEach((r) => r.onclick = () => { el("oPrice").value = r.dataset.px; updatePreview(); });
  el("bids").querySelectorAll(".row").forEach((r) => r.onclick = () => { el("oPrice").value = r.dataset.px; updatePreview(); });

  const mid = W.mid(), spr = W.spread(), bps = W.spreadBps(), imb = W.imbalance();
  el("midPx").textContent = mid ? fmt(mid) : "—";
  const mu = W.microprice();
  el("spreadTxt").innerHTML = spr ? `<span class="mu">μ ${fmt(mu)}</span> · spr ${fmt(spr)} · ${bps.toFixed(1)}bp` : "—";
  el("tickMeta").textContent = mid ? `mid ${fmt(mid)} · spr ${bps.toFixed(1)}bp` : "spread —";
  el("imbBar").style.width = `${((imb + 1) / 2 * 100).toFixed(1)}%`;
  drawDepth();
  updatePreview();
}
function drawDepth() {
  const svg = el("depth"); const H = 120;
  const maxc = W.maxCum() || 1;
  const nb = Math.min(W.bidCount(), 30), na = Math.min(W.askCount(), 30);
  // Step-area polygon: each level fills its own x-slice at the cumulative height,
  // so a shallow book renders as clean steps (a single level = a rectangle) rather
  // than an ugly diagonal triangle. An empty side draws nothing.
  const stepPts = (n, cum, dir) => {          // dir: -1 bids (left), +1 asks (right)
    if (!n) return "";
    let pts = `150,${H} `;
    for (let i = 0; i < n; i++) {
      const x0 = 150 + dir * (i / n) * 150, x1 = 150 + dir * ((i + 1) / n) * 150;
      const y = H - (cum(i) / maxc) * H;
      pts += `${x0},${y} ${x1},${y} `;
    }
    return pts + `${150 + dir * 150},${H}`;
  };
  svg.innerHTML =
    `<polygon points="${stepPts(nb, (i) => W.cumBid(i), -1)}" fill="var(--up)" fill-opacity=".12" stroke="var(--up)" stroke-width="1"/>` +
    `<polygon points="${stepPts(na, (i) => W.cumAsk(i), 1)}" fill="var(--down)" fill-opacity=".12" stroke="var(--down)" stroke-width="1"/>` +
    `<line x1="150" y1="0" x2="150" y2="${H}" stroke="var(--ink)" stroke-opacity=".4" stroke-dasharray="2 3"/>`;
}

// ---------- tape ----------
function addTape(px, am, ts, flash) {
  const dir = lastTradePx != null && px < lastTradePx ? "down" : "up";
  const d = new Date(ts || Date.now());
  const line = document.createElement("div");
  line.className = "tline" + (flash ? (dir === "up" ? " flash-up" : " flash-down") : "");
  line.innerHTML = `<span class="px ${dir}">${fmt(px)}</span><span class="am mono-num">${fmt(am, 4)}</span><span class="tm">${d.toLocaleTimeString()}</span>`;
  el("tape").prepend(line);
  while (el("tape").children.length > 60) el("tape").lastChild.remove();
}
function setLast(px) { lastTradePx = px; el("lastPx").textContent = fmt(px); el("lastPx").className = "px mono-num glow"; }
function setConn(ok) { el("connDot").classList.toggle("off", !ok); el("connTxt").textContent = ok ? "live · realtime" : "polling"; }

// timeframe picker -> reload candles from server-side OHLCV at the new resolution
document.querySelectorAll("#tf button[data-sec]").forEach((b) => b.onclick = () => {
  tf = +b.dataset.sec;
  document.querySelectorAll("#tf button[data-sec]").forEach((x) => x.classList.toggle("on", x === b));
  loadCandles();
});
// MA overlay toggles (wasm SMA/EMA/BOLL/VMA)
document.querySelectorAll(".ma-t").forEach((b) => b.onclick = () => {
  const k = b.dataset.ma; MA[k].on = !MA[k].on; b.classList.toggle("on", MA[k].on); renderChart();
});
// oscillator picker (RSI / MACD / off)
document.querySelectorAll("#oscPick button[data-osc]").forEach((b) => b.onclick = () => {
  osc = b.dataset.osc;
  document.querySelectorAll("#oscPick button[data-osc]").forEach((x) => x.classList.toggle("on", x === b));
  renderOsc();
});

// ============================================================ ORDER ENTRY
document.querySelectorAll(".seg button[data-side]").forEach((b) => b.onclick = () => {
  side = b.dataset.side;
  document.querySelectorAll(".seg button[data-side]").forEach((x) => x.classList.toggle("on", x === b));
  const buy = side === "BUY";
  el("place").className = "submit " + (buy ? "buy" : "sell");
  el("place").textContent = `Place ${buy ? "Buy" : "Sell"} Order`;
  updatePreview();
});
document.querySelectorAll("#otype button").forEach((b) => b.onclick = () => {
  otype = b.dataset.ot;
  document.querySelectorAll("#otype button").forEach((x) => x.classList.toggle("on", x === b));
  el("priceWrap").style.display = otype === "MARKET" ? "none" : "grid";
  updatePreview();
});
["oPrice", "oAmount"].forEach((id) => el(id).addEventListener("input", updatePreview));

function updatePreview() {
  if (!W) return;
  const amt = +el("oAmount").value || 0;
  const px = +el("oPrice").value || 0;
  if (otype === "MARKET") {
    const vwap = W.marketBuyVwap(amt); // ask-side walk (demo: buy estimate)
    el("pvVwap").textContent = vwap ? fmt(vwap) : "—";
    el("pvCost").textContent = vwap ? fmt(W.bankerRound(amt * vwap, PREC)) + " EUR" : "—";
  } else {
    el("pvVwap").textContent = "—";
    el("pvCost").textContent = fmt(W.quoteCost(amt, px, PREC)) + " EUR";
  }
}

el("place").onclick = async () => {
  const baseAmt = +el("oAmount").value;
  let amountParam = baseAmt, px = 0;
  if (otype === "MARKET") {
    // The engine's BUY MARKET model spends `amount` as a QUOTE budget, so convert
    // the base amount the user entered into an estimated budget (ask-side VWAP).
    // SELL MARKET `amount` is base, so it's sent as-is. price stays 0 (not null;
    // the column is NOT NULL and price-band risk is skipped for market orders).
    if (side === "BUY") {
      const vwap = W.marketBuyVwap(baseAmt) || 0;
      if (!vwap) { toast("no asks to estimate market buy", "err"); return; }
      amountParam = W.bankerRound(baseAmt * vwap, PREC);
    }
  } else {
    px = +el("oPrice").value;
  }
  // Market orders never rest on the book — force IOC so any unfilled remainder
  // (e.g. rounding dust on a buy budget) is released instead of booked.
  const tif = otype === "MARKET" ? "IOC" : el("oTif").value;
  el("place").disabled = true;
  const { error } = await sb.rpc("place_order", {
    instrument_name_param: SYM, side_param: side, order_type_param: otype,
    price_param: px, amount_param: amountParam, time_in_force_param: tif,
  });
  el("place").disabled = false;
  if (error) toast(error.message.replace(/_/g, " "), "err");
  else { toast(`${side} ${baseAmt} ${SYM} ${otype.toLowerCase()} placed`); pollBook(); refreshBlotter(); }
};

// ============================================================ PRIVATE FEED
function subscribePrivate() {
  if (privChan) sb.removeChannel(privChan);
  privChan = sb.channel("me:" + Math.random().toString(36).slice(2))
    .on("postgres_changes", { event: "*", schema: "public", table: "trade_order" }, (p) => {
      const r = p.new || p.old;
      if (r?.status === "FILLED") toast(`Order ${r.pub_id?.slice(0, 8)} FILLED`);
      refreshBlotter();
    })
    .on("postgres_changes", { event: "*", schema: "public", table: "wallet_request" }, (p) => {
      const r = p.new || p.old;
      if (r?.status === "APPROVED") toast(`Wallet ${r.direction} approved: ${r.amount} ${r.currency}`);
      refreshBlotter();
    })
    .subscribe();
}

// ============================================================ BLOTTER
let blotTab = "orders";
document.querySelectorAll("#blotTabs button").forEach((b) => b.onclick = () => {
  blotTab = b.dataset.tab;
  document.querySelectorAll("#blotTabs button").forEach((x) => x.classList.toggle("on", x === b));
  refreshBlotter();
});
// Always-visible available-balance bar (independent of the blotter sub-tab).
async function updateBalances() {
  const rows = el("balRows"); if (!rows) return;
  const { data: cash } = await sb.from("cash_balances")
    .select("currency,amount,amount_reserved,available").order("currency");
  const cells = (cash || []).filter((c) => +c.amount || +c.amount_reserved).map((c) =>
    `<div class="bal-cell"><span class="ccy">${c.currency}</span><span class="amt">${fmt(c.available, 4)}</span>${
      +c.amount_reserved ? `<span class="resv">+${fmt(c.amount_reserved, 4)} rsv</span>` : ""}</div>`);
  rows.innerHTML = cells.length ? cells.join("") : `<span class="empty">no funds yet — click 💰 Demo funds</span>`;
}

async function refreshBlotter() {
  updateBalances();
  const body = el("blotBody");
  if (blotTab === "orders") {
    const { data } = await sb.from("open_orders").select("pub_id,instrument,side,order_type,price,amount,open_amount,status").order("created_at", { ascending: false });
    el("blotCount").textContent = `${data?.length || 0} working`;
    if (!data?.length) { body.innerHTML = `<div class="empty">No working orders</div>`; return; }
    body.innerHTML = `<table><thead><tr><th>Instrument</th><th>Side</th><th>Type</th><th>Price</th><th>Amount</th><th>Open</th><th>Status</th><th></th></tr></thead><tbody>${
      data.map((o) => `<tr><td>${o.instrument}</td><td class="${o.side === "BUY" ? "up" : "down"}">${o.side}</td><td>${o.order_type}</td>
        <td class="mono-num">${fmt(o.price)}</td><td class="mono-num">${fmt(o.amount, 4)}</td><td class="mono-num">${fmt(o.open_amount, 4)}</td>
        <td><span class="pill ${o.status}">${o.status}</span></td><td class="x" data-cancel="${o.pub_id}">✕</td></tr>`).join("")}</tbody></table>`;
    body.querySelectorAll("[data-cancel]").forEach((x) => x.onclick = async () => {
      const { error } = await sb.rpc("cancel_order", { trade_order_id_param: x.dataset.cancel });
      if (error) toast(error.message, "err"); else { toast("Order cancelled"); refreshBlotter(); pollBook(); }
    });
  } else if (blotTab === "balances") {
    const [{ data: cash }, { data: inst }] = await Promise.all([
      sb.from("cash_balances").select("currency,amount,amount_reserved,available").order("currency"),
      sb.from("instrument_balances").select("instrument,amount,available"),
    ]);
    el("blotCount").textContent = `${(cash?.length || 0)} currencies`;
    body.innerHTML = `<table><thead><tr><th>Asset</th><th>Total</th><th>Reserved</th><th>Available</th></tr></thead><tbody>${
      (cash || []).map((c) => `<tr><td>${c.currency}</td><td class="mono-num">${fmt(c.amount, 4)}</td><td class="mono-num amber">${fmt(c.amount_reserved, 4)}</td><td class="mono-num up">${fmt(c.available, 4)}</td></tr>`).join("")
      || `<tr><td colspan="4" class="empty">No balances — request a deposit (admin approves)</td></tr>`}</tbody></table>`;
  } else {
    const { data } = await sb.from("wallet_request").select("direction,currency,amount,status,created_at").order("created_at", { ascending: false }).limit(30);
    el("blotCount").textContent = `${data?.length || 0} requests`;
    body.innerHTML = data?.length ? `<table><thead><tr><th>Direction</th><th>Currency</th><th>Amount</th><th>Status</th></tr></thead><tbody>${
      data.map((w) => `<tr><td>${w.direction}</td><td>${w.currency}</td><td class="mono-num">${fmt(w.amount, 2)}</td><td><span class="pill ${w.status}">${w.status}</span></td></tr>`).join("")}</tbody></table>`
      : `<div class="empty">No wallet requests</div>`;
  }
}

// ============================================================ PRODUCT / WALLET / ACCOUNT WORKSPACES
const escH = (s) => String(s ?? "").replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
let productTab = "perp", walletTab = "dep", lastKeySecret = null;
function setProductNav(tab) {
  document.querySelectorAll("#productNav button").forEach((b) => b.classList.toggle("on", b.dataset.product === tab));
}
function openProduct(tab = productTab) {
  productTab = tab;
  setProductNav(tab);
  el("productModal").hidden = false;
  document.querySelectorAll("#productTabs button").forEach((b) => b.classList.toggle("on", b.dataset.ptab === productTab));
  renderProduct();
}
function openWallet(tab = walletTab) {
  walletTab = tab;
  el("walletModal").hidden = false;
  document.querySelectorAll("#walletTabs button").forEach((b) => b.classList.toggle("on", b.dataset.wtab === walletTab));
  renderWallet();
}
function openDeveloper() {
  el("devModal").hidden = false;
  renderDeveloper();
}
function openAccount() {
  el("acctModal").hidden = false;
  renderAccount();
}
function closeModal(id) { el(id).hidden = true; }

document.querySelectorAll("#productNav button").forEach((b) => b.onclick = () => {
  if (b.dataset.product === "spot") { setProductNav("spot"); closeModal("productModal"); return; }
  openProduct(b.dataset.product);
});
document.querySelectorAll("#productTabs button").forEach((b) => b.onclick = () => openProduct(b.dataset.ptab));
document.querySelectorAll("[data-product-jump]").forEach((b) => b.onclick = () => openProduct(b.dataset.productJump));
document.querySelectorAll("#walletTabs button").forEach((b) => b.onclick = () => openWallet(b.dataset.wtab));
document.querySelectorAll("[data-open-wallet]").forEach((b) => b.onclick = () => openWallet(b.dataset.openWallet));

el("walletBtn").onclick = () => openWallet();
el("devBtn").onclick = () => openDeveloper();
el("acctBtn").onclick = () => openAccount();
el("productClose").onclick = () => { closeModal("productModal"); setProductNav("spot"); };
el("walletClose").onclick = () => closeModal("walletModal");
el("devClose").onclick = () => closeModal("devModal");
el("acctClose").onclick = () => { el("acctModal").hidden = true; };
["productModal", "walletModal", "devModal", "acctModal"].forEach((id) => {
  el(id).addEventListener("click", (e) => { if (e.target === el(id)) closeModal(id); });
});

async function renderProduct() {
  const body = el("productBody");
  body.innerHTML = `<div class="acct"><div class="empty">Loading…</div></div>`;
  try {
    if (productTab === "perp") return await renderPerp(body);
    if (productTab === "margin") return await renderMargin(body);
    if (productTab === "stake") return await renderStake(body);
  } catch (e) { body.innerHTML = `<div class="acct"><div class="empty">${escH(e.message || e)}</div></div>`; }
}
async function renderWallet() {
  const body = el("walletBody");
  body.innerHTML = `<div class="acct"><div class="empty">Loading…</div></div>`;
  try {
    if (walletTab === "dep") return await renderDeposits(body);
    if (walletTab === "wd") return await renderWithdraw(body);
  } catch (e) { body.innerHTML = `<div class="acct"><div class="empty">${escH(e.message || e)}</div></div>`; }
}
async function renderDeveloper() {
  const body = el("devBody");
  body.innerHTML = `<div class="acct"><div class="empty">Loading…</div></div>`;
  try { return await renderKeys(body); }
  catch (e) { body.innerHTML = `<div class="acct"><div class="empty">${escH(e.message || e)}</div></div>`; }
}
async function renderAccount() {
  const body = el("acctBody");
  body.innerHTML = `<div class="acct"><div class="empty">Loading…</div></div>`;
  try { return await renderReferral(body); }
  catch (e) { body.innerHTML = `<div class="acct"><div class="empty">${escH(e.message || e)}</div></div>`; }
}

async function renderKeys(body) {
  const { data } = await sb.from("api_keys")
    .select("key_id,label,scopes,last_used_at,revoked_at,created_at").order("created_at", { ascending: false });
  const secret = lastKeySecret; lastKeySecret = null;
  body.innerHTML = `<div class="acct">
    <div class="acct-sec"><h4>Create API key</h4>
      <div class="acct-row"><input id="kLabel" class="grow" placeholder="label (e.g. market-maker bot)"/><button class="btn" id="kCreate">Create</button></div>
      ${secret ? `<div class="secret-box">key_id: ${escH(secret.key_id)}<br/>secret: ${escH(secret.secret)}<br/><b>⚠ Copy the secret now — it is never shown again.</b></div>` : ""}</div>
    <div class="acct-sec"><h4>Your keys</h4>
      ${(data && data.length) ? `<table><thead><tr><th>Key ID</th><th>Label</th><th>Scopes</th><th>Last used</th><th></th></tr></thead><tbody>${
        data.map((k) => `<tr><td class="mono-num">${escH(k.key_id)}</td><td>${escH(k.label || "—")}</td><td>${escH((k.scopes || []).join(", "))}</td>
          <td>${k.last_used_at ? new Date(k.last_used_at).toLocaleString() : "—"}</td>
          <td>${k.revoked_at ? '<span class="down">revoked</span>' : `<button class="x-btn" data-revoke="${escH(k.key_id)}">revoke</button>`}</td></tr>`).join("")}</tbody></table>`
        : `<div class="empty">No keys yet.</div>`}</div>
    <div class="acct-sec"><h4>Use a key (bot)</h4>
      <div class="empty">Exchange it for a JWT: <code>POST /rest/v1/rpc/api_key_login {key_id_param, secret_param}</code> → use the returned <code>access_token</code> as a Bearer token (every RPC + RLS works unchanged).</div></div>
  </div>`;
  el("kCreate").onclick = async () => {
    const { data: r, error } = await sb.rpc("create_api_key", { label_param: el("kLabel").value || null, scopes_param: ["trade"] });
    if (error) return toast(error.message, "err");
    lastKeySecret = r; renderKeys(body);
  };
  body.querySelectorAll("[data-revoke]").forEach((b) => b.onclick = async () => {
    const { error } = await sb.rpc("revoke_api_key", { key_id_param: b.dataset.revoke });
    if (error) toast(error.message, "err"); else { toast("Key revoked"); renderDeveloper(); }
  });
}

async function renderReferral(body) {
  const code = (await sb.rpc("my_referral_code")).data;
  const { data: sum } = await sb.from("referral_summary").select("referred_count,total_earned,unpaid_earned").maybeSingle();
  const link = `${location.origin}${location.pathname}${location.search ? location.search + "&" : "?"}ref=${code || ""}`;
  body.innerHTML = `<div class="acct">
    <div class="acct-sec"><h4>Your referral code</h4>
      <div class="acct-row"><input class="grow" id="refCode" readonly value="${escH(code || "")}"/><button class="btn" id="refCopy">Copy invite link</button></div></div>
    <div class="acct-sec"><h4>Earnings</h4>
      <div class="stat-chip"><b>${sum?.referred_count ?? 0}</b><span>referred</span></div>
      <div class="stat-chip"><b>${fmt(sum?.total_earned || 0, 2)}</b><span>total earned</span></div>
      <div class="stat-chip"><b>${fmt(sum?.unpaid_earned || 0, 2)}</b><span>unpaid</span></div></div>
    <div class="acct-sec"><h4>Set your referrer <span style="color:var(--ink-faint)">(one-time)</span></h4>
      <div class="acct-row"><input id="refSet" class="grow" placeholder="referrer code" value="${escH(_q.get("ref") || "")}"/><button class="btn" id="refSetBtn">Apply</button></div></div>
  </div>`;
  el("refCopy").onclick = () => { navigator.clipboard?.writeText(link); toast("Invite link copied"); };
  el("refSetBtn").onclick = async () => {
    const { error } = await sb.rpc("set_my_referrer", { code_param: el("refSet").value.trim() });
    if (error) toast(error.message.replace(/_/g, " "), "err"); else { toast("Referrer set"); renderAccount(); }
  };
}

// Withdraw: coin → network → destination + amount. Coin maps to the debited currency
// (native ETH/TRX/SOL pay out of the EUR balance; USDT/USDC are their own currency).
const COIN_NAMES = { USDT: "Tether", USDC: "USD Coin", ETH: "Ethereum", TRX: "TRON", SOL: "Solana" };
const coinLabel = (sym) =>
  `<b>${sym}</b>${COIN_NAMES[sym] ? `<span class="coin-nm">${COIN_NAMES[sym]}</span>` : ""}`;

const WITHDRAW_ASSETS = [
  { coin: "USDT", currency: "USDT", chains: [{ chain: "tron-nile", net: "TRC-20 · Nile" }] },
  { coin: "USDC", currency: "USDC", chains: [{ chain: "solana-testnet", net: "SPL · devnet" }, { chain: "ethereum-sepolia", net: "ERC-20 · Sepolia" }] },
  { coin: "ETH",  currency: "EUR",  chains: [{ chain: "ethereum-sepolia", net: "Sepolia" }] },
  { coin: "TRX",  currency: "EUR",  chains: [{ chain: "tron-nile", net: "Nile" }] },
  { coin: "SOL",  currency: "EUR",  chains: [{ chain: "solana-testnet", net: "devnet" }] },
];
let wdCoin = null, wdNet = null;

async function renderWithdraw(body) {
  const asset = WITHDRAW_ASSETS.find((a) => a.coin === wdCoin);
  const opt = asset?.chains.find((c) => c.chain === wdNet) || (asset && asset.chains.length === 1 ? asset.chains[0] : null);
  if (asset && opt) wdNet = opt.chain;
  const [{ data: addrs }, { data: cash }] = await Promise.all([
    sb.from("withdrawal_addresses").select("id,currency,address,label,usable").order("currency"),
    sb.from("cash_balances").select("currency,available"),
  ]);
  const cur = asset?.currency;
  const bal = cur ? Number((cash || []).find((c) => c.currency === cur)?.available || 0) : 0;
  const mine = cur ? (addrs || []).filter((a) => a.currency === cur) : [];
  const usable = mine.filter((a) => a.usable);

  const detail = (asset && opt) ? `<div class="acct-sec"><h4>3 · Withdraw ${wdCoin} · ${opt.net}</h4>
      <div class="empty">Debits your <b>${cur}</b> balance · available <b>${fmt(bal, 6)}</b></div>
      <div class="acct-row">
        <select id="wdAddr" class="grow">${usable.map((a) => `<option value="${escH(a.address)}">${escH(a.address)}${a.label ? " · " + escH(a.label) : ""}</option>`).join("") || '<option value="">— whitelist an address below —</option>'}</select>
        <input id="wdAmt" type="number" step="0.0001" placeholder="amount" style="max-width:130px"/>
        <button class="btn" id="wdGo">Withdraw</button></div>
      <div class="empty">Sends ${wdCoin} on ${opt.net} from the in-DB signer (testnet). Subject to rolling limits + admin approval.</div>
      <div class="acct-row" style="margin-top:10px"><input id="waAddr" class="grow mono-num" placeholder="destination ${wdCoin} address"/><input id="waLabel" placeholder="label"/><button class="btn" id="waAdd">Whitelist</button></div>
      ${mine.length ? `<table><thead><tr><th>Address</th><th>Status</th><th></th></tr></thead><tbody>${
        mine.map((a) => `<tr><td class="mono-num">${escH(a.address)}</td><td>${a.usable ? '<span class="up">usable</span>' : '<span class="amber">cooling…</span>'}</td><td><button class="x-btn" data-rmaddr="${a.id}">remove</button></td></tr>`).join("")}</tbody></table>`
        : `<div class="empty">No whitelisted ${cur} addresses yet — add one.</div>`}</div>` : "";

  body.innerHTML = `<div class="acct">
    <div class="acct-sec"><h4>1 · Select coin</h4>
      <div class="pick">${WITHDRAW_ASSETS.map((a) => `<button class="pick-b ${a.coin === wdCoin ? "on" : ""}" data-wcoin="${a.coin}">${coinLabel(a.coin)}</button>`).join("")}</div></div>
    ${asset ? `<div class="acct-sec"><h4>2 · Select network</h4>
      <div class="pick">${asset.chains.map((c) => `<button class="pick-b ${c.chain === wdNet ? "on" : ""}" data-wnet="${c.chain}">${c.net}</button>`).join("")}</div></div>` : `<div class="empty">Pick a coin to begin.</div>`}
    ${detail}
  </div>`;

  body.querySelectorAll("[data-wcoin]").forEach((b) => b.onclick = () => { wdCoin = b.dataset.wcoin; wdNet = null; renderWithdraw(body); });
  body.querySelectorAll("[data-wnet]").forEach((b) => b.onclick = () => { wdNet = b.dataset.wnet; renderWithdraw(body); });
  body.querySelectorAll("[data-rmaddr]").forEach((b) => b.onclick = async () => {
    const { error } = await sb.rpc("remove_withdrawal_address", { address_id_param: +b.dataset.rmaddr });
    if (error) toast(error.message, "err"); else { toast("Address removed"); renderWithdraw(body); }
  });
  const wa = el("waAdd");
  if (wa) wa.onclick = async () => {
    const { error } = await sb.rpc("add_withdrawal_address", { currency_param: cur, address_param: el("waAddr").value.trim(), label_param: el("waLabel").value || null });
    if (error) toast(error.message, "err"); else { toast("Address whitelisted — usable now", "warn"); renderWithdraw(body); }
  };
  const wg = el("wdGo");
  if (wg) wg.onclick = async () => {
    const addr = el("wdAddr").value;
    if (!addr) return toast("whitelist an address first", "err");
    const { error } = await sb.rpc("request_withdrawal_to", { currency_param: cur, amount_param: +el("wdAmt").value, to_address_param: addr });
    if (error) toast(error.message.replace(/_/g, " "), "err");
    else { toast("Withdrawal requested (pending approval)", "warn"); refreshBlotter(); }
  };
}

// ---- Deposits: coin → network → in-DB-derived address/memo (CEX style: send from any wallet) ----
// Only combos the in-DB watcher actually credits are offered.
const DEPOSIT_ASSETS = [
  { coin: "USDT", chains: [{ chain: "tron-nile", net: "TRC-20 · Nile" }] },
  { coin: "USDC", chains: [{ chain: "solana-testnet", net: "SPL · devnet" }] },
  { coin: "ETH",  chains: [{ chain: "ethereum-sepolia", net: "Sepolia" }] },
  { coin: "TRX",  chains: [{ chain: "tron-nile", net: "Nile" }] },
  { coin: "SOL",  chains: [{ chain: "solana-testnet", net: "devnet" }] },
];
let depCoin = null, depNet = null, depInfo = null;   // selection + resolved {address,memo,mode}

async function renderDeposits(body) {
  const asset = DEPOSIT_ASSETS.find((a) => a.coin === depCoin);
  const opt = asset?.chains.find((c) => c.chain === depNet) || (asset && asset.chains.length === 1 ? asset.chains[0] : null);
  if (asset && opt) depNet = opt.chain;
  const { data: deps } = await sb.from("my_chain_deposits")
    .select("chain,txid,currency,amount,credited_at,created_at").order("created_at", { ascending: false }).limit(30);

  const detail = (asset && opt && depInfo) ? `<div class="acct-sec"><h4>3 · Your ${depCoin} deposit address · ${opt.net}</h4>
      <div class="acct-row"><span class="label">ADDRESS</span><input class="grow mono-num" readonly value="${escH(depInfo.address)}"/><button class="btn" data-copy="${escH(depInfo.address)}">Copy</button></div>
      ${depInfo.memo ? `<div class="acct-row"><span class="label">MEMO / TAG</span><input class="grow mono-num" readonly value="${escH(depInfo.memo)}"/><button class="btn" data-copy="${escH(depInfo.memo)}">Copy</button></div>
        <div class="empty">⚠ You <b>must</b> include this memo when sending, or the deposit can't be credited to you.</div>` : ""}
      <div class="empty">Send <b>${depCoin}</b> on <b>${opt.net}</b> only to this address, from any wallet or exchange. A pure-SQL watcher credits it to your balance within ~30s. Sending a different coin or network will be lost. Testnet only.</div></div>` : "";

  body.innerHTML = `<div class="acct">
    <div class="acct-sec"><h4>1 · Select coin</h4>
      <div class="pick">${DEPOSIT_ASSETS.map((a) => `<button class="pick-b ${a.coin === depCoin ? "on" : ""}" data-coin="${a.coin}">${coinLabel(a.coin)}</button>`).join("")}</div></div>
    ${asset ? `<div class="acct-sec"><h4>2 · Select network</h4>
      <div class="pick">${asset.chains.map((c) => `<button class="pick-b ${c.chain === depNet ? "on" : ""}" data-net="${c.chain}">${c.net}</button>`).join("")}</div></div>` : `<div class="empty">Pick a coin to begin.</div>`}
    ${detail}
    <div class="acct-sec"><h4>Detected deposits</h4>
      ${(deps && deps.length) ? `<table><thead><tr><th>Chain</th><th>Tx</th><th>Cur</th><th>Amount</th><th>Status</th></tr></thead><tbody>${
        deps.map((d) => `<tr><td>${escH(d.chain)}</td><td class="mono-num" title="${escH(d.txid)}">${escH((d.txid || "").slice(0, 10))}…</td>
          <td>${escH(d.currency)}</td><td class="mono-num">${fmt(d.amount, 6)}</td>
          <td>${d.credited_at ? '<span class="up">credited</span>' : '<span class="amber">pending…</span>'}</td></tr>`).join("")}</tbody></table>`
        : `<div class="empty">No deposits detected yet.</div>`}</div>
  </div>`;

  body.querySelectorAll("[data-coin]").forEach((b) => b.onclick = () => { depCoin = b.dataset.coin; depNet = null; depInfo = null; renderDeposits(body); });
  body.querySelectorAll("[data-net]").forEach((b) => b.onclick = () => { depNet = b.dataset.net; depInfo = null; renderDeposits(body); });
  // resolve the deposit address once a coin+network are chosen
  if (asset && opt && !depInfo) {
    const { data, error } = await sb.rpc("my_deposit_address", { chain_param: opt.chain });
    if (!error) { depInfo = data; renderDeposits(body); return; }
  }
  body.querySelectorAll("[data-copy]").forEach((b) => b.onclick = () => { navigator.clipboard?.writeText(b.dataset.copy); toast("Copied"); });
}

// ---- Staking (reward-per-token, pgmq unbonding) ----
async function renderStake(body) {
  const [{ data: pools }, { data: mine }] = await Promise.all([
    sb.from("stake_pools").select("currency,apr,total_staked").order("currency"),
    sb.from("my_stakes").select("currency,amount,pending_reward,apr").order("currency"),
  ]);
  const curs = (pools || []).map((p) => p.currency);
  body.innerHTML = `<div class="acct">
    <div class="acct-sec"><h4>Pools</h4>
      ${(pools && pools.length) ? `<table><thead><tr><th>Currency</th><th>APR</th><th>Total staked</th></tr></thead><tbody>${
        pools.map((p) => `<tr><td>${escH(p.currency)}</td><td class="up">${fmt(p.apr * 100, 2)}%</td><td class="mono-num">${fmt(p.total_staked, 4)}</td></tr>`).join("")}</tbody></table>`
        : `<div class="empty">No staking pools configured.</div>`}</div>
    <div class="acct-sec"><h4>Your positions</h4>
      ${(mine && mine.length) ? `<table><thead><tr><th>Currency</th><th>Staked</th><th>Pending reward</th><th></th></tr></thead><tbody>${
        mine.map((s) => `<tr><td>${escH(s.currency)}</td><td class="mono-num">${fmt(s.amount, 4)}</td><td class="mono-num up">${fmt(s.pending_reward, 6)}</td>
          <td><button class="x-btn" data-claim="${escH(s.currency)}">claim</button> <button class="x-btn" data-unstake="${escH(s.currency)}">unstake all</button></td></tr>`).join("")}</tbody></table>`
        : `<div class="empty">No active stakes.</div>`}</div>
    <div class="acct-sec"><h4>Stake</h4>
      <div class="acct-row"><select id="stCur">${curs.map((c) => `<option>${escH(c)}</option>`).join("") || "<option>EUR</option>"}</select>
        <input id="stAmt" type="number" step="0.0001" placeholder="amount"/><button class="btn" id="stGo">Stake</button></div>
      <div class="empty">Rewards accrue continuously (lazy reward-per-token); unstaking has an unbonding delay, then principal returns automatically (pgmq).</div></div>
  </div>`;
  el("stGo").onclick = async () => {
    const { error } = await sb.rpc("stake", { currency_param: el("stCur").value, amount_param: +el("stAmt").value });
    if (error) toast(error.message.replace(/_/g, " "), "err"); else { toast("Staked"); renderProduct(); refreshBlotter(); }
  };
  body.querySelectorAll("[data-claim]").forEach((b) => b.onclick = async () => {
    const { error } = await sb.rpc("claim_stake_rewards", { currency_param: b.dataset.claim });
    if (error) toast(error.message.replace(/_/g, " "), "err"); else { toast("Rewards claimed"); renderProduct(); refreshBlotter(); }
  });
  body.querySelectorAll("[data-unstake]").forEach((b) => b.onclick = async () => {
    const cur = b.dataset.unstake;
    const row = (mine || []).find((s) => s.currency === cur);
    const { error } = await sb.rpc("unstake", { currency_param: cur, amount_param: row ? +row.amount : 0 });
    if (error) toast(error.message.replace(/_/g, " "), "err"); else { toast("Unstaking — principal returns after unbonding", "warn"); renderProduct(); }
  });
}

// ---- Spot margin (cross-margin, EUR-valued; pg_cron liquidation) ----
async function renderMargin(body) {
  const [{ data: terms }, { data: health }, { data: loans }, { data: cash }] = await Promise.all([
    sb.from("margin_terms").select("max_leverage,maintenance_ratio,borrow_apr").maybeSingle(),
    sb.rpc("my_margin_health"),
    sb.from("my_margin").select("currency,principal,accrued,debt").order("currency"),
    sb.from("cash_balances").select("currency").order("currency"),
  ]);
  const h = Array.isArray(health) ? health[0] : health;
  const curs = (cash || []).map((c) => c.currency);
  body.innerHTML = `<div class="acct">
    <div class="acct-sec"><h4>Account health <span style="color:var(--ink-faint)">(valued in EUR)</span></h4>
      <div class="stat-chip"><b>${fmt(h?.collateral || 0, 2)}</b><span>collateral</span></div>
      <div class="stat-chip"><b>${fmt(h?.debt || 0, 2)}</b><span>debt</span></div>
      <div class="stat-chip"><b>${fmt(h?.equity || 0, 2)}</b><span>equity</span></div>
      ${terms ? `<div class="empty">Max leverage <b>${fmt(terms.max_leverage, 0)}×</b> · maintenance <b>${fmt(terms.maintenance_ratio * 100, 1)}%</b> · borrow APR <b>${fmt(terms.borrow_apr * 100, 1)}%</b></div>` : ""}</div>
    <div class="acct-sec"><h4>Outstanding loans</h4>
      ${(loans && loans.length) ? `<table><thead><tr><th>Currency</th><th>Principal</th><th>Accrued</th><th>Debt</th><th></th></tr></thead><tbody>${
        loans.map((l) => `<tr><td>${escH(l.currency)}</td><td class="mono-num">${fmt(l.principal, 4)}</td><td class="mono-num amber">${fmt(l.accrued, 6)}</td><td class="mono-num down">${fmt(l.debt, 4)}</td>
          <td><button class="x-btn" data-repay="${escH(l.currency)}" data-debt="${l.debt}">repay all</button></td></tr>`).join("")}</tbody></table>`
        : `<div class="empty">No outstanding loans.</div>`}</div>
    <div class="acct-sec"><h4>Borrow</h4>
      <div class="acct-row"><select id="mgCur">${curs.map((c) => `<option>${escH(c)}</option>`).join("") || "<option>EUR</option>"}</select>
        <input id="mgAmt" type="number" step="0.0001" placeholder="amount"/><button class="btn" id="mgGo">Borrow</button></div>
      <div class="empty">Total debt is capped at equity·(leverage−1). A pg_cron monitor liquidates when equity ≤ debt·maintenance.</div></div>
  </div>`;
  el("mgGo").onclick = async () => {
    const { error } = await sb.rpc("borrow", { currency_param: el("mgCur").value, amount_param: +el("mgAmt").value });
    if (error) toast(error.message.replace(/_/g, " "), "err"); else { toast("Borrowed"); renderProduct(); refreshBlotter(); }
  };
  body.querySelectorAll("[data-repay]").forEach((b) => b.onclick = async () => {
    const { error } = await sb.rpc("repay", { currency_param: b.dataset.repay, amount_param: +b.dataset.debt });
    if (error) toast(error.message.replace(/_/g, " "), "err"); else { toast("Repaid"); renderProduct(); refreshBlotter(); }
  });
}

// ---- Perpetual futures (position-based linear perp) ----
async function renderPerp(body) {
  const [{ data: mkts }, { data: mine }] = await Promise.all([
    sb.from("perp_markets").select("symbol,index_symbol,margin_currency,mark_price,funding_rate,max_leverage,maintenance_ratio").order("symbol"),
    sb.from("my_perp").select("symbol,size,entry_price,mark_price,upnl,margin,equity").order("symbol"),
  ]);
  const syms = (mkts || []).map((m) => m.symbol);
  const open = new Set((mine || []).map((p) => p.symbol));
  body.innerHTML = `<div class="acct">
    <div class="acct-sec"><h4>Markets</h4>
      ${(mkts && mkts.length) ? `<table><thead><tr><th>Symbol</th><th>Mark</th><th>Funding</th><th>Max lev</th><th>Maint</th></tr></thead><tbody>${
        mkts.map((m) => `<tr><td>${escH(m.symbol)}</td><td class="mono-num">${fmt(m.mark_price, 2)}</td><td class="mono-num">${fmt(m.funding_rate * 100, 4)}%</td>
          <td class="mono-num">${fmt(m.max_leverage, 0)}×</td><td class="mono-num">${fmt(m.maintenance_ratio * 100, 1)}%</td></tr>`).join("")}</tbody></table>`
        : `<div class="empty">No perp markets.</div>`}</div>
    <div class="acct-sec"><h4>Your positions</h4>
      ${(mine && mine.length) ? `<table><thead><tr><th>Symbol</th><th>Size</th><th>Entry</th><th>Mark</th><th>uPnL</th><th>Margin</th><th>Equity</th><th></th></tr></thead><tbody>${
        mine.map((p) => `<tr><td>${escH(p.symbol)}</td><td class="mono-num ${p.size >= 0 ? "up" : "down"}">${fmt(p.size, 4)}</td>
          <td class="mono-num">${fmt(p.entry_price, 2)}</td><td class="mono-num">${fmt(p.mark_price, 2)}</td>
          <td class="mono-num ${p.upnl >= 0 ? "up" : "down"}">${fmt(p.upnl, 2)}</td><td class="mono-num">${fmt(p.margin, 2)}</td><td class="mono-num">${fmt(p.equity, 2)}</td>
          <td><button class="x-btn" data-closeperp="${escH(p.symbol)}">close</button></td></tr>`).join("")}</tbody></table>`
        : `<div class="empty">No open positions.</div>`}</div>
    <div class="acct-sec"><h4>Open position</h4>
      <div class="acct-row"><select id="ppSym">${syms.filter((s) => !open.has(s)).map((s) => `<option>${escH(s)}</option>`).join("") || "<option value=''>— all positions open —</option>"}</select>
        <select id="ppSide"><option value="1">Long</option><option value="-1">Short</option></select>
        <input id="ppSize" type="number" step="0.0001" placeholder="size (base)"/>
        <input id="ppMargin" type="number" step="0.01" placeholder="margin"/><button class="btn" id="ppGo">Open</button></div>
      <div class="empty">Margin is posted in the market's quote currency; size·mark/leverage is the minimum. Longs pay shorts when funding is positive (pg_cron).</div></div>
  </div>`;
  el("ppGo").onclick = async () => {
    const sym = el("ppSym").value; if (!sym) return toast("no flat market to open", "err");
    const size = (+el("ppSide").value) * Math.abs(+el("ppSize").value);
    const { error } = await sb.rpc("open_perp", { symbol_param: sym, size_param: size, margin_param: +el("ppMargin").value });
    if (error) toast(error.message.replace(/_/g, " "), "err"); else { toast("Position opened"); renderProduct(); refreshBlotter(); }
  };
  body.querySelectorAll("[data-closeperp]").forEach((b) => b.onclick = async () => {
    const { data: r, error } = await sb.rpc("close_perp", { symbol_param: b.dataset.closeperp });
    if (error) toast(error.message.replace(/_/g, " "), "err"); else { toast(`Closed · PnL ${fmt(r?.pnl, 2)} · payout ${fmt(r?.payout, 2)}`); renderProduct(); refreshBlotter(); }
  });
}

// ============================================================ BOOT
(async () => {
  await loadWasm();
  // connectivity hint (e.g. the hosted Pages demo with no backend configured yet)
  let reachable = false;
  // hosted GoTrue returns 401 on /health without an apikey, so send it (a 401
  // still means the backend is up — only a network failure means unreachable).
  try {
    const r = await fetch(CONFIG.API + "/auth/v1/health", { headers: { apikey: CONFIG.ANON } });
    reachable = r.ok || r.status === 401;
  } catch {}
  if (!reachable) {
    el("authMsg").innerHTML = `No backend reachable at <code>${CONFIG.API}</code>. This is the live UI — point it at a Supabase by adding <code>?api=&lt;url&gt;&amp;anon=&lt;key&gt;</code> to the URL, or run the stack locally (see the README).`;
  }
  const { data: { session } } = await sb.auth.getSession();
  if (session) enterTerminal(session);
})();
