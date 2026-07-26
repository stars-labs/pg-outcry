// Demo market maker — keeps the public demo from looking like a dead exchange.
//
// SYNTHETIC LIQUIDITY. Two house accounts (DEMO_MM_A / DEMO_MM_B, provisioned by
// migration 00090) quote a two-sided book around a random-walk mid and cross each
// other occasionally so the book, depth chart, tape and candles all have data.
// It is not real market activity and must not be run on a venue holding real
// customer funds.
//
// Both makers are type='MASTER': house liquidity is not customer funding, so this
// does not create the unbacked-funding exposure that chain-backed enforcement
// reverses. Two accounts are needed because the engine refuses self-trades.
//
//   SERVICE=<service_role key> [API=…] node scripts/demo-market-maker.mjs
import { createClient } from "@supabase/supabase-js";

const API = process.env.API ?? "http://127.0.0.1:54321";
const sb = createClient(API, process.env.SERVICE ?? "");
if (!process.env.SERVICE) { console.error("set SERVICE=<service_role key>"); process.exit(2); }

const SYMBOL   = process.env.SYMBOL   ?? "BTC_USDT";
const QUOTE_MS = Number(process.env.QUOTE_MS ?? 5000);   // requote interval
const LEVELS   = Number(process.env.LEVELS   ?? 5);      // levels per side
const SPREAD   = Number(process.env.SPREAD   ?? 0.0008); // half-spread, fraction of mid
const STEP     = Number(process.env.STEP     ?? 0.0006); // gap between levels
const SIZE     = Number(process.env.SIZE     ?? 0.05);   // base size per level
const CROSS_P  = Number(process.env.CROSS_P  ?? 0.35);   // chance a tick generates a trade
const DRIFT    = Number(process.env.DRIFT    ?? 0.0012); // random-walk step

let mid = Number(process.env.START_PRICE ?? 0);
const round = (x, d) => Number(x.toFixed(d));

async function rpc(fn, args) {
  const { data, error } = await sb.rpc(fn, args);
  if (error) throw new Error(`${fn}: ${error.message}`);
  return data;
}

async function seedMid() {
  if (mid > 0) return;
  const { data } = await sb.from("trade_history").select("price")
    .eq("instrument", SYMBOL).order("created_at", { ascending: false }).limit(1);
  mid = data?.length ? Number(data[0].price) : 100;
  console.log(`starting mid = ${mid}`);
}

// Cancel whatever this maker still has resting, so quotes don't pile up.
async function clearBook(account) {
  const { data } = await sb.from("open_orders").select("pub_id,instrument_account")
    .eq("instrument", SYMBOL).limit(200);
  const mine = (data ?? []).filter((o) => o.instrument_account === account);
  for (const o of mine) {
    try { await rpc("submit_cancel", { trade_order_id_param: o.pub_id }); } catch { /* already gone */ }
  }
}

async function quote(account, side, levels) {
  const orders = levels.map(({ price, amount }) => ({
    type: "LIMIT", side, price, amount, tif: "GTC",
  }));
  await rpc("submit_orders", {
    instrument_account_id_param: account,
    instrument_name_param: SYMBOL,
    orders,
  });
}

async function tick(A, B) {
  mid *= 1 + (Math.random() - 0.5) * 2 * DRIFT;            // random walk
  const bids = [], asks = [];
  for (let i = 0; i < LEVELS; i++) {
    const off = SPREAD + i * STEP;
    bids.push({ price: round(mid * (1 - off), 2), amount: round(SIZE * (1 + i * 0.4), 5) });
    asks.push({ price: round(mid * (1 + off), 2), amount: round(SIZE * (1 + i * 0.4), 5) });
  }
  // A makes the market, B provides the opposite side of the book.
  await clearBook(A); await clearBook(B);
  await quote(A, "BUY",  bids);
  await quote(B, "SELL", asks);

  // Occasionally cross to print a trade: B lifts A's best bid or vice versa.
  if (Math.random() < CROSS_P) {
    const buy = Math.random() < 0.5;
    const px  = buy ? asks[0].price : bids[0].price;
    const acct = buy ? A : B;
    const side = buy ? "BUY" : "SELL";
    try {
      await rpc("submit_orders", {
        instrument_account_id_param: acct,
        instrument_name_param: SYMBOL,
        orders: [{ type: "LIMIT", side, price: px, amount: round(SIZE * (0.3 + Math.random()), 5), tif: "IOC" }],
      });
      console.log(`  crossed ${side} @ ${px}`);
    } catch (e) { console.warn("  cross skipped:", e.message); }
  }
  console.log(`mid ${round(mid, 2)}  bid ${bids[0].price}  ask ${asks[0].price}`);
}

const A = await rpc("demo_maker_account", { maker_param: "DEMO_MM_A" });
const B = await rpc("demo_maker_account", { maker_param: "DEMO_MM_B" });
if (!A || !B) { console.error("demo makers not provisioned — apply migration 00090"); process.exit(1); }
await seedMid();
console.log(`demo market maker on ${SYMBOL}  A=${A.slice(0,8)} B=${B.slice(0,8)}  every ${QUOTE_MS}ms`);

let busy = false;
setInterval(async () => {
  if (busy) return; busy = true;
  try { await tick(A, B); } catch (e) { console.error("tick:", e.message); } finally { busy = false; }
}, QUOTE_MS);
