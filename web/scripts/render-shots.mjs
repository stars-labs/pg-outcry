// Render REAL product screenshots (no browser): load the WASM engine, pull live
// data from Supabase, render the order book + candlestick chart + RSI exactly as
// the terminal does, and rasterize SVG→PNG with @resvg/resvg-js.
//   ANON=<anon> node scripts/render-shots.mjs
import { createClient } from "@supabase/supabase-js";
import { readFileSync, writeFileSync } from "node:fs";
import { Resvg } from "@resvg/resvg-js";

const API = process.env.API ?? "http://127.0.0.1:54321";
const ANON = process.env.ANON;
const SYM = "BTC_EUR";
const sb = createClient(API, ANON);
const { instance } = await WebAssembly.instantiate(readFileSync("public/orderbook.wasm"), { env: { abort() { throw new Error("abort"); } } });
const W = instance.exports;
const fmt = (n, d = 2) => Number(n).toLocaleString("en-US", { minimumFractionDigits: d, maximumFractionDigits: d });

// ── data ──
const { data: tape } = await sb.from("trade_history").select("price,amount,created_at").eq("instrument", SYM).order("created_at", { ascending: false }).limit(400);
const raw = tape.map((t) => ({ ts: new Date(t.created_at).getTime() / 1000, p: +t.price, a: +t.amount })).reverse();
W.candleReset(); W.candleSetInterval(60); for (const t of raw) W.addTrade(t.ts, t.p, t.a);
const { data: book } = await sb.from("order_book_l2").select("side,price,volume").eq("instrument", SYM);
const bids = book.filter((r) => r.side === "BUY").map((r) => [+r.price, +r.volume]).sort((a, b) => b[0] - a[0]);
const asks = book.filter((r) => r.side === "SELL").map((r) => [+r.price, +r.volume]).sort((a, b) => a[0] - b[0]);
W.reset(0); bids.forEach(([p, v]) => W.push(0, p, v)); W.reset(1); asks.forEach(([p, v]) => W.push(1, p, v));

// ── palette ──
const C = { bg: "#06080a", panel: "#0a0e10", line: "rgba(120,150,138,.16)", grid: "rgba(78,247,168,.06)",
  phos: "#4ef7a8", coral: "#ff5d6c", amber: "#ffb454", ink: "#cfe0d7", dim: "#6f8279", faint: "#3f4f48",
  sma: "#5ad8ff", ema: "#ffb454", boll: "#9b8cff", vwap: "#ff8fd0", rsi: "#5ad8ff" };
const FONT = "monospace";
const T = (x, y, s, fill, size = 12, anchor = "start", weight = 400) =>
  `<text x="${x}" y="${y}" fill="${fill}" font-family="${FONT}" font-size="${size}" font-weight="${weight}" text-anchor="${anchor}">${s}</text>`;
const esc = (s) => String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;");

const Wd = 1280, H = 720;
let g = `<rect width="${Wd}" height="${H}" fill="${C.bg}"/>`;
// faint grid
for (let x = 0; x < Wd; x += 44) g += `<line x1="${x}" y1="0" x2="${x}" y2="${H}" stroke="${C.grid}"/>`;
for (let y = 0; y < H; y += 44) g += `<line x1="0" y1="${y}" x2="${Wd}" y2="${y}" stroke="${C.grid}"/>`;

// header
g += `<rect x="0" y="0" width="${Wd}" height="44" fill="#0a0f11"/><line x1="0" y1="44" x2="${Wd}" y2="44" stroke="${C.line}"/>`;
g += T(16, 29, "OUTCRY", C.phos, 17, "start", 700);
g += T(120, 28, SYM, C.ink, 14);
g += T(210, 28, "last " + fmt(W.candleClose(W.candleCount() - 1)), C.phos, 14);
g += T(360, 28, "μ " + fmt(W.microprice() || W.mid()) + "   spread " + W.spreadBps().toFixed(1) + "bp", C.dim, 12);
g += T(Wd - 16, 28, "pure-PostgreSQL exchange · WASM terminal", C.dim, 12, "end");

// ── order book (x 16..300) ──
const bx = 16, bw = 286, oy0 = 60, oyH = 632;
g += `<rect x="${bx}" y="${oy0}" width="${bw}" height="${oyH}" fill="${C.panel}"/><line x1="${bx + bw}" y1="${oy0}" x2="${bx + bw}" y2="${oy0 + oyH}" stroke="${C.line}"/>`;
g += T(bx + 10, oy0 + 18, "ORDER BOOK · L2", C.dim, 11, "start", 600);
const maxc = W.maxCum() || 1, rowH = 17;
const showA = asks.slice(0, 13).reverse(), showB = bids.slice(0, 13);
let ry = oy0 + 34;
showA.forEach(([p, v], i) => {
  const idx = asks.indexOf(asks.find((a) => a[0] === p)); const c = W.cumAsk(asks.length - 1 - (showA.length - 1 - i));
  const w = Math.min(bw - 12, (W.cumAsk(asks.slice(0, 13).length - 1 - i) / maxc) * (bw - 12));
  g += `<rect x="${bx + bw - 6 - w}" y="${ry - 11}" width="${w}" height="13" fill="${C.coral}" opacity=".13"/>`;
  g += T(bx + 10, ry, fmt(p), C.coral, 12) + T(bx + bw - 8, ry, fmt(v, 3), C.dim, 11, "end"); ry += rowH;
});
g += `<line x1="${bx}" y1="${ry - 8}" x2="${bx + bw}" y2="${ry - 8}" stroke="${C.line}"/>`;
g += T(bx + 10, ry + 8, "mid " + fmt(W.mid()), C.phos, 13, "start", 600); ry += 22;
showB.forEach(([p, v], i) => {
  const w = Math.min(bw - 12, (W.cumBid(i) / maxc) * (bw - 12));
  g += `<rect x="${bx + bw - 6 - w}" y="${ry - 11}" width="${w}" height="13" fill="${C.phos}" opacity=".13"/>`;
  g += T(bx + 10, ry, fmt(p), C.phos, 12) + T(bx + bw - 8, ry, fmt(v, 3), C.dim, 11, "end"); ry += rowH;
});

// ── candlestick chart (x 320..1264) ──
const cx0 = 320, cW = Wd - cx0 - 64, cy0 = 60, cH = 392, vH = 70;
const priceH = cH - vH;
const n = W.candleCount(), N = Math.min(n, 72), st = n - N;
W.computeBoll(20, 2); W.computeSma(7); W.computeEma(25); W.computeVwap(); W.computeRsi(14);
let lo = W.candleMin(N), hi = W.candleMax(N);
for (let i = st; i < n; i++) { const u = W.bollUp(i), l = W.bollLo(i); if (!isNaN(u) && u > hi) hi = u; if (!isNaN(l) && l < lo) lo = l; }
const pad = (hi - lo) * 0.06 || 1; lo -= pad; hi += pad;
const vmax = W.candleVolMax(N) || 1;
const X = (i) => cx0 + (i / N) * cW, cw = Math.max(2, (cW / N) * 0.62);
const PY = (p) => cy0 + priceH - ((p - lo) / (hi - lo)) * priceH;
const VY = (v) => cy0 + cH - (v / vmax) * (vH - 8);
g += `<rect x="${cx0}" y="${cy0}" width="${cW + 64}" height="${cH}" fill="${C.panel}"/>`;
for (let k = 0; k <= 4; k++) { const p = lo + (hi - lo) * k / 4, y = PY(p); g += `<line x1="${cx0}" y1="${y}" x2="${cx0 + cW}" y2="${y}" stroke="${C.line}" stroke-dasharray="2 4"/>` + T(cx0 + cW + 6, y + 3, fmt(p), C.faint, 11); }
const line = (atFn, col, wdt = 1.4) => { let d = "", pen = false; for (let i = 0; i < N; i++) { const v = atFn(st + i); if (isNaN(v) || v <= 0) { pen = false; continue; } d += (pen ? "L" : "M") + (X(i) + cw / 2).toFixed(1) + " " + PY(v).toFixed(1) + " "; pen = true; } return `<path d="${d}" fill="none" stroke="${col}" stroke-width="${wdt}"/>`; };
// bollinger fill
{ const U = [], L = []; for (let i = 0; i < N; i++) { const u = W.bollUp(st + i); if (isNaN(u)) continue; U.push([X(i) + cw / 2, PY(u)]); L.push([X(i) + cw / 2, PY(W.bollLo(st + i))]); }
  if (U.length > 1) { const up = U.map((p) => `${p[0].toFixed(1)} ${p[1].toFixed(1)}`).join(" L"); const lr = L.map((p) => `${p[0].toFixed(1)} ${p[1].toFixed(1)}`).reverse().join(" L"); g += `<path d="M${up} L${lr} Z" fill="${C.boll}" opacity=".07"/>`; } }
// candles + volume
for (let i = 0; i < N; i++) { const idx = st + i, o = W.candleOpen(idx), h = W.candleHigh(idx), l = W.candleLow(idx), c = W.candleClose(idx), v = W.candleVol(idx); const up = c >= o, col = up ? C.phos : C.coral, mx = X(i) + cw / 2;
  g += `<rect x="${X(i).toFixed(1)}" y="${VY(v).toFixed(1)}" width="${cw.toFixed(1)}" height="${(cy0 + cH - VY(v)).toFixed(1)}" fill="${col}" opacity=".30"/>`;
  g += `<line x1="${mx.toFixed(1)}" y1="${PY(h).toFixed(1)}" x2="${mx.toFixed(1)}" y2="${PY(l).toFixed(1)}" stroke="${col}"/>`;
  const top = PY(Math.max(o, c)), bh = Math.max(1, Math.abs(PY(o) - PY(c))); g += `<rect x="${X(i).toFixed(1)}" y="${top.toFixed(1)}" width="${cw.toFixed(1)}" height="${bh.toFixed(1)}" fill="${col}"/>`; }
g += line((i) => W.bollUp(i), C.boll, 1) + line((i) => W.bollLo(i), C.boll, 1);
g += line((i) => W.smaAt(i), C.sma) + line((i) => W.emaAt(i), C.ema) + line((i) => W.vwapAt(i), C.vwap, 1.4);
const last = W.candleClose(n - 1), ly = PY(last);
g += `<line x1="${cx0}" y1="${ly}" x2="${cx0 + cW}" y2="${ly}" stroke="${C.amber}" stroke-dasharray="3 3"/><rect x="${cx0 + cW}" y="${ly - 8}" width="64" height="16" fill="${C.amber}"/>` + T(cx0 + cW + 5, ly + 3, fmt(last), "#1a1206", 11);
g += T(cx0 + 8, cy0 + 16, "BTC_EUR · 1m   MA7 EMA25 BOLL VWAP", C.dim, 11);
g += T(cx0 + 8, cy0 + 30, `O ${fmt(W.candleOpen(n-1))}  H ${fmt(W.candleHigh(n-1))}  L ${fmt(W.candleLow(n-1))}  C ${fmt(last)}`, last >= W.candleOpen(n-1) ? C.phos : C.coral, 11);

// ── RSI strip (y 470..700) ──
const ry0 = 470, rH = 230;
g += `<rect x="${cx0}" y="${ry0}" width="${cW + 64}" height="${rH}" fill="${C.panel}"/>`;
g += T(cx0 + 8, ry0 + 16, "RSI 14", C.rsi, 11, "start", 600);
const RY = (v) => ry0 + 24 + (1 - v / 100) * (rH - 36);
[30, 50, 70].forEach((lv) => g += `<line x1="${cx0}" y1="${RY(lv)}" x2="${cx0 + cW}" y2="${RY(lv)}" stroke="${C.line}" stroke-dasharray="3 3"/>` + T(cx0 + cW + 6, RY(lv) + 3, String(lv), C.faint, 10));
{ let d = "", pen = false; for (let i = 0; i < N; i++) { const v = W.rsiAt(st + i); if (isNaN(v)) { pen = false; continue; } d += (pen ? "L" : "M") + (X(i) + cw / 2).toFixed(1) + " " + RY(v).toFixed(1) + " "; pen = true; } g += `<path d="${d}" fill="none" stroke="${C.rsi}" stroke-width="1.4"/>`; }
g += T(cx0 + 70, ry0 + 16, "last " + W.rsiAt(n - 1).toFixed(1), C.dim, 11);

const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${Wd}" height="${H}" viewBox="0 0 ${Wd} ${H}">${g}</svg>`;
const png = new Resvg(svg, { fitTo: { mode: "width", value: 1280 }, font: { loadSystemFonts: true, defaultFontFamily: "monospace" } }).render().asPng();
writeFileSync("docs/hero.png", png);
writeFileSync("docs/hero.svg", svg);
console.log("wrote web/docs/hero.png (" + png.length + " bytes) from", n, "candles + book", bids.length + "/" + asks.length);
