// Stage 2 market data: L2 order book is delivered via coalesced Broadcast on
// md:<symbol> (event 'l2'). A resting order marks the book dirty; broadcast_md()
// (called here directly; in prod by the 100ms ticker / pg_cron) emits one L2
// snapshot. Subscribe, rest an order, flush, assert the L2 broadcast arrives.
import { createClient } from "@supabase/supabase-js";
const API = process.env.API ?? "http://127.0.0.1:54321";
const KEY = process.env.SERVICE ?? process.env.ANON;
if (!KEY) throw new Error("set SERVICE or ANON");
const sb = createClient(API, KEY);
const rpc = (fn, b) => sb.rpc(fn, b).then(({ data, error }) => { if (error) throw new Error(`${fn}: ${error.message}`); return data; });

const got = new Promise((res) => {
  sb.channel("md:BTC_USDT")
    .on("broadcast", { event: "l2" }, ({ payload }) => res(payload))
    .subscribe((s) => console.log("[realtime] md:BTC_USDT channel:", s));
});
await new Promise((r) => setTimeout(r, 3500));

const s = Math.floor(performance.now());
const a = await rpc("create_client", { external_id_param: `md_${s}` });
await rpc("create_currency_account", { app_entity_id_param: a, currency_param: "BTC" });
await rpc("process_transfer", { type_param: "DEPOSIT", from_customer_id_param: "MASTER", amount_param: 1000, currency_param: "BTC", to_customer_id_param: a, reference_param: "md", details_param: "md", fee_type_param: null });
const ia = await rpc("find_instrument_account", { external_id_param: `md_${s}` });
await rpc("submit_order", { instrument_account_id_param: ia, instrument_name_param: "BTC_USDT", order_type_param: "LIMIT", side_param: "SELL", price_param: 123, amount_param: 1, time_in_force_param: "GTC" });
const flushed = await rpc("broadcast_md");   // ticker would do this every 100ms
console.log(`[rpc] resting SELL @123 placed, broadcast_md flushed ${flushed} book(s)`);

const to = new Promise((_, rej) => setTimeout(() => rej(new Error("no l2 broadcast")), 10000));
const l2 = await Promise.race([got, to]);
const ask = (l2.asks || []).find((x) => Number(x.price) === 123);
console.log("[realtime] L2 broadcast:", { symbol: l2.symbol, asks: l2.asks });
if (!ask) { console.log("FAIL: expected an ask at 123"); process.exit(1); }
console.log("PASS: market data (L2) delivered via coalesced broadcast");
process.exit(0);
