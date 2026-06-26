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
  await pollBook(); await pollTape();
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
  aggregateCandles();
}

// ---------- candles (WASM) ----------
function aggregateCandles() {
  if (!W) return;
  W.candleReset(); W.candleSetInterval(tf);
  for (const t of rawTrades) W.addTrade(t.ts, t.price, t.amount);
  renderChart();
}
function onLiveTrade(px, am, tsIso) {
  const ts = new Date(tsIso || Date.now()).getTime() / 1000;
  rawTrades.push({ ts, price: px, amount: am });
  if (rawTrades.length > 8000) rawTrades = rawTrades.slice(-6000);
  if (W) { W.addTrade(ts, px, am); renderChart(); }
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
  const svg = el("depth"); const Wd = 300, H = 120;
  const maxc = W.maxCum() || 1;
  const nb = Math.min(W.bidCount(), 30), na = Math.min(W.askCount(), 30);
  let bid = "", ask = "";
  for (let i = 0; i < nb; i++) { const x = 150 - (i + 1) / nb * 150; const y = H - (W.cumBid(i) / maxc) * H; bid += `${x},${y} `; }
  for (let i = 0; i < na; i++) { const x = 150 + (i + 1) / na * 150; const y = H - (W.cumAsk(i) / maxc) * H; ask += `${x},${y} `; }
  svg.innerHTML =
    `<polygon points="150,${H} ${bid} ${nb? (150-150)+','+H : ''}" fill="rgba(78,247,168,.12)" stroke="#4ef7a8" stroke-width="1"/>` +
    `<polygon points="150,${H} ${ask} ${na? '300,'+H : ''}" fill="rgba(255,93,108,.10)" stroke="#ff5d6c" stroke-width="1"/>` +
    `<line x1="150" y1="0" x2="150" y2="${H}" stroke="rgba(120,150,138,.2)" stroke-dasharray="2 3"/>`;
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

// timeframe picker -> re-aggregate in wasm
document.querySelectorAll("#tf button[data-sec]").forEach((b) => b.onclick = () => {
  tf = +b.dataset.sec;
  document.querySelectorAll("#tf button[data-sec]").forEach((x) => x.classList.toggle("on", x === b));
  aggregateCandles();
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
  else { toast(`${side} ${amt} ${SYM} placed`); pollBook(); refreshBlotter(); }
};

// ---------- wallet ----------
el("wGo").onclick = async () => {
  const dir = el("wDir").value, cur = el("wCur").value, amt = +el("wAmt").value;
  const fn = dir === "DEPOSIT" ? "request_deposit" : "request_withdrawal";
  const { error } = await sb.rpc(fn, { currency_param: cur, amount_param: amt });
  if (error) toast(error.message.replace(/_/g, " "), "err");
  else { toast(`${dir} request: ${amt} ${cur} (pending admin)`, "warn"); refreshBlotter(); }
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
async function refreshBlotter() {
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

// ============================================================ BOOT
(async () => {
  await loadWasm();
  // connectivity hint (e.g. the hosted Pages demo with no backend configured yet)
  let reachable = false;
  try { reachable = (await fetch(CONFIG.API + "/auth/v1/health")).ok; } catch {}
  if (!reachable) {
    el("authMsg").innerHTML = `No backend reachable at <code>${CONFIG.API}</code>. This is the live UI — point it at a Supabase by adding <code>?api=&lt;url&gt;&amp;anon=&lt;key&gt;</code> to the URL, or run the stack locally (see the README).`;
  }
  const { data: { session } } = await sb.auth.getSession();
  if (session) enterTerminal(session);
})();
