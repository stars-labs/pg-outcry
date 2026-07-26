// Stage 1/2 realtime: the public trade tape is delivered via Broadcast on
// md:<symbol> (event 'trade'), emitted by an AFTER INSERT trigger on the
// (partitioned) trade table. Cross two orders, assert the tape broadcast arrives.
import { createClient } from "@supabase/supabase-js";
const API = process.env.API ?? "http://127.0.0.1:54321";
const KEY = process.env.SERVICE ?? process.env.ANON;
if (!KEY) throw new Error("set SERVICE or ANON");
const sb = createClient(API, KEY);
const rpc = (fn, b) => sb.rpc(fn, b).then(({ data, error }) => { if (error) throw new Error(`${fn}: ${error.message}`); return data; });

const got = new Promise((resolve) => {
  sb.channel("md:BTC_USDT")
    .on("broadcast", { event: "trade" }, ({ payload }) => resolve(payload))
    .subscribe((s) => console.log("[realtime] md:BTC_USDT channel:", s));
});
await new Promise((r) => setTimeout(r, 3500));

const suffix = Math.floor(performance.now());
const a = await rpc("create_client", { external_id_param: `rt_sell_${suffix}` });
const b = await rpc("create_client", { external_id_param: `rt_buy_${suffix}` });
for (const id of [a, b]) await rpc("create_currency_account", { app_entity_id_param: id, currency_param: "BTC" });
const dep = (to, cur) => rpc("process_transfer", {
  type_param: "DEPOSIT", from_customer_id_param: "MASTER", amount_param: 1000,
  currency_param: cur, to_customer_id_param: to, reference_param: "rt", details_param: "rt", fee_type_param: null,
});
for (const id of [a, b]) { await dep(id, "USDT"); await dep(id, "BTC"); }

const sellIA = await rpc("find_instrument_account", { external_id_param: `rt_sell_${suffix}` });
const buyIA = await rpc("find_instrument_account", { external_id_param: `rt_buy_${suffix}` });
const order = (ia, side) => rpc("submit_order", {
  instrument_account_id_param: ia, instrument_name_param: "BTC_USDT", order_type_param: "LIMIT",
  side_param: side, price_param: 100, amount_param: 1, time_in_force_param: "GTC",
});
await order(sellIA, "SELL");
await order(buyIA, "BUY");
console.log("[rpc] crossing orders placed, waiting for tape broadcast...");

const timeout = new Promise((_, rej) => setTimeout(() => rej(new Error("timed out waiting for trade broadcast")), 10000));
const trade = await Promise.race([got, timeout]);
console.log("[realtime] tape broadcast:", { symbol: trade.symbol, price: trade.price, amount: trade.amount });
console.log("PASS: realtime delivered the engine trade (broadcast tape)");
process.exit(0);
