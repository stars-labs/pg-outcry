// Stage 6: authenticated PRIVATE realtime channel.
// Each user subscribes to trade_order changes with their own JWT; Realtime must
// enforce the trade_order RLS so a user only receives their OWN order events.
import { createClient } from "@supabase/supabase-js";
const API = process.env.API ?? "http://127.0.0.1:54321";
const ANON = process.env.ANON, SERVICE = process.env.SERVICE;
if (!ANON || !SERVICE) throw new Error("set ANON and SERVICE");

const { execSync } = await import("node:child_process");
if (process.env.RESET !== "0") { console.log("(resetting db)"); execSync("supabase db reset", { stdio: "ignore" }); }

const admin = createClient(API, SERVICE);
const PG = "postgresql://postgres:postgres@127.0.0.1:54322/postgres";

const signup = async (email) => {
  const r = await fetch(`${API}/auth/v1/signup`, {
    method: "POST", headers: { apikey: ANON, "Content-Type": "application/json" },
    body: JSON.stringify({ email, password: "password123" }),
  }).then((x) => x.json());
  return { jwt: r.access_token, uid: r.user.id };
};
const arpc = (fn, b) => admin.rpc(fn, b).then(({ data, error }) => { if (error) throw new Error(`${fn}: ${error.message}`); return data; });

const fund = async (uid) => {
  const { execSync } = await import("node:child_process");
  const pub = execSync(`psql "${PG}" -tAc "select pub_id from app_entity where external_id='${uid}'"`).toString().trim();
  await arpc("create_currency_account", { app_entity_id_param: pub, currency_param: "BTC" });
  for (const c of ["USDT", "BTC"])
    await arpc("process_transfer", { type_param: "DEPOSIT", from_customer_id_param: "MASTER", amount_param: 1000, currency_param: c, to_customer_id_param: pub, reference_param: "s", details_param: "s", fee_type_param: null });
};

const S = Math.floor(performance.now());
const A = await signup(`p_a_${S}@ex.com`);
const B = await signup(`p_b_${S}@ex.com`);
await fund(A.uid); await fund(B.uid);

// one client per user, each authed with its own JWT so Realtime evaluates RLS as that user
const mkSub = async (jwt, name, bucket) => {
  const c = createClient(API, ANON);
  await c.realtime.setAuth(jwt);
  await new Promise((res) => {
    c.channel(name)
      .on("postgres_changes", { event: "*", schema: "public", table: "trade_order" },
          (p) => { bucket.events.push(p.new ?? p.old); console.log(`  [${name}] ${p.eventType} ${(p.new ?? p.old)?.pub_id} status=${(p.new ?? p.old)?.status}`); })
      .subscribe((s) => { console.log(`  [${name}] ${s}`); if (s === "SUBSCRIBED") res(); });
  });
  return c;
};
const aSeen = { events: [] }, bSeen = { events: [] };
await mkSub(A.jwt, "orders_alice", aSeen);
await mkSub(B.jwt, "orders_bob", bSeen);
await new Promise((r) => setTimeout(r, 4000));

// place orders with each user's JWT (place_order resolves their own account)
const userRpc = (jwt, fn, b) => fetch(`${API}/rest/v1/rpc/${fn}`, {
  method: "POST", headers: { apikey: ANON, Authorization: `Bearer ${jwt}`, "Content-Type": "application/json" },
  body: JSON.stringify(b),
}).then((x) => x.json());
const order = (jwt, side, price, amount) => userRpc(jwt, "place_order",
  { instrument_name_param: "BTC_USDT", side_param: side, order_type_param: "LIMIT", price_param: price, amount_param: amount, time_in_force_param: "GTC" });

const aSell = (await order(A.jwt, "SELL", 100, 1)).toString().replace(/"/g, "");
const bBuy  = (await order(B.jwt, "BUY", 100, 1)).toString().replace(/"/g, "");  // fully crosses
console.log("alice order:", aSell, " bob order:", bBuy);
await new Promise((r) => setTimeout(r, 6000)); // let fill updates arrive

const aPubs = new Set(aSeen.events.map((e) => e.pub_id));
const bPubs = new Set(bSeen.events.map((e) => e.pub_id));
const aFilled = aSeen.events.some((e) => e.pub_id === aSell && e.status === "FILLED");
const bFilled = bSeen.events.some((e) => e.pub_id === bBuy && e.status === "FILLED");
console.log("alice channel pub_ids:", [...aPubs], "own fill seen:", aFilled);
console.log("bob   channel pub_ids:", [...bPubs], "own fill seen:", bFilled);

const aOnlyOwn = [...aPubs].every((p) => p === aSell) && aPubs.has(aSell);
const bOnlyOwn = [...bPubs].every((p) => p === bBuy) && bPubs.has(bBuy);
const noLeak = !aPubs.has(bBuy) && !bPubs.has(aSell);

// ── private wallet feed: alice subscribes to her own wallet_request changes ──
const aWallet = createClient(API, ANON);
await aWallet.realtime.setAuth(A.jwt);
const walletEvents = [];
await new Promise((res) => {
  aWallet.channel("wallet_alice")
    .on("postgres_changes", { event: "*", schema: "public", table: "wallet_request" },
        (p) => walletEvents.push(p.new ?? p.old))
    .subscribe((s) => s === "SUBSCRIBED" && res());
});
await new Promise((r) => setTimeout(r, 1000));
const wreq = (await userRpc(A.jwt, "request_withdrawal", { currency_param: "USDT", amount_param: 50 })).toString().replace(/"/g, "");
await arpc("approve_wallet_request", { request_pub_param: wreq });
await new Promise((r) => setTimeout(r, 3500));
const walletApproved = walletEvents.some((e) => e.pub_id === wreq && e.status === "APPROVED");
console.log("alice wallet channel saw APPROVED for own request:", walletApproved);

if (aOnlyOwn && bOnlyOwn && noLeak && aFilled && bFilled && walletApproved) {
  console.log("PASS: private channels delivered each user's own order lifecycle (incl. FILL) + wallet status, no cross-leak");
  process.exit(0);
} else {
  console.log(`FAIL: aOnlyOwn=${aOnlyOwn} bOnlyOwn=${bOnlyOwn} noLeak=${noLeak} aFilled=${aFilled} bFilled=${bFilled} walletApproved=${walletApproved}`);
  process.exit(1);
}
