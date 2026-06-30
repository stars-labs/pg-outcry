// Smoke: per-user API keys (9905), referral (9910), withdrawal whitelist+limits (9915).
// Pure fetch (no deps). Usage: ANON=.. SERVICE=.. node scripts/smoke-features.mjs
import { execSync } from "node:child_process";
const API = process.env.API ?? "http://127.0.0.1:54321";
const ANON = process.env.ANON, SERVICE = process.env.SERVICE;
const PGURL = process.env.PGURL ?? "postgresql://postgres:postgres@127.0.0.1:54322/postgres";
if (!ANON || !SERVICE) { console.error("set ANON and SERVICE"); process.exit(2); }

let failed = 0;
const ok = (b, m) => { console.log((b ? "PASS" : "FAIL") + " " + m); if (!b) failed++; };
const J = (r) => r.text().then((t) => { try { return JSON.parse(t); } catch { return t; } });
const rpc = (token, fn, body) => fetch(`${API}/rest/v1/rpc/${fn}`, { method: "POST",
  headers: { apikey: ANON, Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
  body: JSON.stringify(body ?? {}) }).then(async (r) => ({ status: r.status, body: await J(r) }));
const svc = (fn, body) => rpc(SERVICE, fn, body);
const get = (token, path) => fetch(`${API}/rest/v1/${path}`,
  { headers: { apikey: ANON, Authorization: `Bearer ${token}` } }).then(J);

async function signup(tag) {
  const r = await fetch(`${API}/auth/v1/signup`, { method: "POST",
    headers: { apikey: ANON, "Content-Type": "application/json" },
    body: JSON.stringify({ email: `${tag}_${Date.now()}@ex.com`, password: "Passw0rd!demo" }) }).then(J);
  const token = r.access_token, uid = r.user?.id ?? r.id;
  const ent = await get(SERVICE, `app_entity?external_id=eq.${uid}&select=pub_id`);
  return { token, uid, pub: ent[0].pub_id };
}
const fund = (pub, cur, amt) => svc("process_transfer", { type_param: "DEPOSIT", from_customer_id_param: "MASTER",
  amount_param: amt, currency_param: cur, to_customer_id_param: pub, reference_param: "f", details_param: "f", fee_type_param: null });
const acct = (pub, cur) => svc("create_currency_account", { app_entity_id_param: pub, currency_param: cur });
const ia = (uid) => svc("find_instrument_account", { external_id_param: uid }).then((r) => r.body);

console.log("── API keys ──");
const K = await signup("k"); await acct(K.pub, "BTC"); await fund(K.pub, "EUR", 100000);
const ck = (await rpc(K.token, "create_api_key", { label_param: "bot" })).body;
ok(ck?.secret && ck?.key_id, "create_api_key returns key_id+secret");
const lg = (await rpc("anon-placeholder", "api_key_login", { key_id_param: ck.key_id, secret_param: ck.secret }));
// api_key_login is callable with the anon key as bearer too; use ANON as bearer:
const lg2 = (await rpc(ANON, "api_key_login", { key_id_param: ck.key_id, secret_param: ck.secret })).body;
ok(lg2?.access_token, "api_key_login mints a JWT");
const po = await rpc(lg2.access_token, "place_order", { instrument_name_param: "BTC_EUR", side_param: "BUY",
  order_type_param: "LIMIT", price_param: 50, amount_param: 1, time_in_force_param: "GTC" });
ok(po.status < 300, "bot places order via minted JWT");
const bad = await rpc(ANON, "api_key_login", { key_id_param: ck.key_id, secret_param: "ocs_wrong" });
ok(bad.status >= 400, "wrong secret rejected");

console.log("── Referral ──");
const A = await signup("A"), B = await signup("B"), M = await signup("M");
await acct(B.pub, "BTC"); await fund(B.pub, "EUR", 100000); await acct(M.pub, "BTC"); await fund(M.pub, "BTC", 100);
const code = (await rpc(A.token, "my_referral_code")).body;
ok(typeof code === "string" && code.length > 0, "A gets referral code");
ok((await rpc(B.token, "set_my_referrer", { code_param: code })).body === true, "B attributes to A");
ok((await rpc(B.token, "set_my_referrer", { code_param: code })).status >= 400, "double attribution rejected");
await svc("submit_orders", { instrument_account_id_param: await ia(M.uid), instrument_name_param: "BTC_EUR",
  orders: [{ type: "LIMIT", side: "SELL", price: 100, amount: 3, tif: "GTC" }] });
ok((await rpc(B.token, "place_order", { instrument_name_param: "BTC_EUR", side_param: "BUY", order_type_param: "LIMIT",
  price_param: 100, amount_param: 3, time_in_force_param: "GTC" })).status < 300, "B buys as taker");
const sum = (await get(A.token, "referral_summary?select=referred_count,total_earned"))[0];
ok(sum && Number(sum.total_earned) > 0, `referrer earned commission (${JSON.stringify(sum)})`);
ok(Number((await svc("pay_referral_earnings", { entity_pub: A.pub, currency_param: "EUR" })).body) > 0, "admin pays referral earnings");

// --- server-side OHLCV (9965) — the BUY taker above produced a BTC_EUR trade @100 x3 ---
const candles = (await rpc(ANON, "ohlcv", { p_instrument: "BTC_EUR", p_resolution: 60 })).body;
const lastBar = Array.isArray(candles) ? candles.at(-1) : null;
ok(lastBar && Number(lastBar.o) === 100 && Number(lastBar.h) === 100 && Number(lastBar.l) === 100 &&
   Number(lastBar.c) === 100 && Number(lastBar.v) >= 3,
   `ohlcv returns server-side candles (${JSON.stringify(lastBar)})`);

console.log("── Withdrawal whitelist + limits ──");
const W = await signup("W"); await fund(W.pub, "EUR", 100000);
await rpc(W.token, "add_withdrawal_address", { currency_param: "EUR", address_param: "IBAN-OK", label_param: "bank" });
ok((await rpc(W.token, "request_withdrawal_to", { currency_param: "EUR", amount_param: 100, to_address_param: "IBAN-OK" })).status < 300, "whitelisted address usable immediately (no cooling)");
ok((await rpc(W.token, "request_withdrawal_to", { currency_param: "EUR", amount_param: 999999, to_address_param: "IBAN-OK" })).status >= 400, "over-limit blocked");
ok((await rpc(W.token, "request_withdrawal_to", { currency_param: "EUR", amount_param: 100, to_address_param: "NOPE" })).status >= 400, "non-whitelisted blocked");

console.log("── Chain deposits (in-DB watcher core) ──");
const C = await signup("C");
ok((await rpc(C.token, "register_deposit_address", { chain_param: "ethereum-sepolia", address_param: "0xSMOKE" })).status < 300, "user registers a deposit address");
const credit = (txid, conf) => svc("credit_chain_deposit", { chain_param: "ethereum-sepolia", txid_param: txid, log_index_param: 0, address_param: "0xSMOKE", currency_param: "EUR", amount_param: 123.45, confirmations_param: conf });
ok((await credit("0xT1", 3)).body === "pending", "below N confirmations → pending (no credit)");
ok((await credit("0xT1", 20)).body === "credited", "≥ N confirmations → credited");
ok((await credit("0xT1", 30)).body === "duplicate", "same txid again → duplicate (idempotent)");
ok((await svc("credit_chain_deposit", { chain_param: "ethereum-sepolia", txid_param: "0xT2", log_index_param: 0, address_param: "0xUNWATCHED", currency_param: "EUR", amount_param: 1, confirmations_param: 20 })).body === "unwatched", "unwatched address → unwatched");
const dep = await get(C.token, "my_chain_deposits?select=txid,amount,credited_at");
ok(Array.isArray(dep) && dep.some(d => d.txid === "0xT1" && d.credited_at), "deposit visible to owner via RLS view");

console.log("── Withdrawal send queue ──");
// Simulate the external signer with service RPCs (no real chain in CI). The DB
// hands out approved+whitelisted withdrawals once; a real signer would sign+broadcast.
// fund exactly the withdrawal amount so this is a FULL-balance withdrawal (regression:
// approve must release the reservation BEFORE the debit, else reserved transiently > amount).
const S = await signup("S"); await fund(S.pub, "EUR", 100);
await rpc(S.token, "add_withdrawal_address", { currency_param: "EUR", address_param: "0xQUEUE", label_param: "hot" });
const wreq = (await rpc(S.token, "request_withdrawal_to", { currency_param: "EUR", amount_param: 100, to_address_param: "0xQUEUE" })).body;
ok(typeof wreq === "string" && wreq.length > 0, "request_withdrawal_to returns a request pub_id");
ok((await svc("approve_wallet_request", { request_pub_param: wreq })).status < 300, "admin approves full-balance withdrawal (reserve released before debit, ledger settled)");
const claim1 = (await svc("next_withdrawal_to_sign")).body;
ok(claim1 && claim1.pub_id === wreq && claim1.to_address === "0xQUEUE" && Number(claim1.amount) === 100,
  "next_withdrawal_to_sign returns the approved withdrawal");
const claim2 = (await svc("next_withdrawal_to_sign")).body;
ok(claim2 === null || claim2 === "" , "second claim returns nothing (claimed-once, no double-send)");
ok((await svc("mark_withdrawal_broadcast", { request_pub: wreq, txid: "0xDEADBEEF" })).body === true, "mark_withdrawal_broadcast records the txid");
ok((await svc("mark_withdrawal_broadcast", { request_pub: wreq, txid: "0xOTHER" })).body === false, "mark_withdrawal_broadcast is idempotent (no clobber)");
ok((await svc("mark_withdrawal_confirmed", { request_pub: wreq })).body === true, "mark_withdrawal_confirmed sets confirmed_at");
ok((await svc("mark_withdrawal_confirmed", { request_pub: wreq })).body === false, "mark_withdrawal_confirmed is idempotent");
const wrow = (await get(S.token, `wallet_request?pub_id=eq.${wreq}&select=broadcast_txid,confirmed_at`))[0];
ok(wrow && wrow.broadcast_txid === "0xDEADBEEF" && wrow.confirmed_at, "owner sees broadcast txid + confirmation via RLS");

console.log("── Staking (pgmq unbonding + pg_cron) ──");
const T2 = await signup("stk"); await fund(T2.pub, "EUR", 1000);
const eur = async () => Number((await get(T2.token, "cash_balances?currency=eq.EUR&select=available"))[0]?.available || 0);
ok((await rpc(T2.token, "stake", { currency_param: "EUR", amount_param: 100 })).status < 300, "stake 100");
ok(await eur() === 900, "principal debited (EUR 900)");
// my_stakes is security_invoker, joins stake_pool, and calls banker_round — reading
// it as the user exercises the grant + RLS-policy path (regressed once, see 9960).
ok((await get(T2.token, "stake_pools?select=currency,apr")).some((p) => p.currency === "EUR"), "stake_pools readable by user");
const myStk = await get(T2.token, "my_stakes?select=currency,amount,pending_reward");
ok(Array.isArray(myStk) && myStk.some((s) => s.currency === "EUR" && Number(s.amount) === 100), "my_stakes shows the position (banker_round + RLS ok)");
execSync(`psql "${PGURL}" -tAqc "update stake_pool set updated_at = now() - interval '365 days' where currency='EUR';"`);
const reward = (await rpc(T2.token, "claim_stake_rewards", { currency_param: "EUR" })).body;
ok(Number(reward) >= 9.9 && Number(reward) <= 10.1, `~10 reward at 10% APR (got ${reward})`);
execSync(`psql "${PGURL}" -tAqc "update stake_config set unbond_seconds=0;"`);
ok((await rpc(T2.token, "unstake", { currency_param: "EUR", amount_param: 100 })).status < 300, "unstake 100 (queued for unbonding)");
ok(Number((await svc("process_unbonding")).body) >= 1, "process_unbonding releases matured principal");
ok(Math.abs(await eur() - 1010) < 0.2, `principal returned (~EUR 1010, got ${await eur()})`);
const rec = (await svc("reconcile")).body;
ok(Array.isArray(rec) && rec.filter((r) => r.status !== "PASS").length === 0, "ledger still reconciles after staking");

console.log("── Spot margin (borrow / leverage cap / liquidation) ──");
const MG = await signup("mg"); await fund(MG.pub, "EUR", 1000);
const meur = async () => Number((await get(MG.token, "cash_balances?currency=eq.EUR&select=available"))[0]?.available || 0);
ok((await rpc(MG.token, "borrow", { currency_param: "EUR", amount_param: 1000 })).status < 300, "borrow 1000 EUR (2x)");
ok(await meur() === 2000, "borrowed funds received (EUR 2000)");
ok((await rpc(MG.token, "borrow", { currency_param: "EUR", amount_param: 5000 })).status >= 400, "over-leverage borrow rejected");
const mh = (await rpc(MG.token, "my_margin_health")).body;
ok(mh && Math.abs(Number(mh.debt) - 1000) < 1, `my_margin_health debt ~1000 (equity ${mh?.equity})`);
ok(Number((await rpc(MG.token, "repay", { currency_param: "EUR", amount_param: 400 })).body) > 0, "repay 400");
execSync(`psql "${PGURL}" -tAqc "update margin_config set borrow_apr=5.0; update margin_loan set updated_at=now()-interval '5 years';"`);
ok(Number((await svc("check_margin_liquidations")).body) >= 1, "liquidation engine liquidates the underwater account");
ok((await get(MG.token, "my_margin?select=debt")).length === 0, "loan cleared after liquidation");
ok(await meur() === 0, "collateral seized after liquidation (EUR 0)");
const rec2 = (await svc("reconcile")).body;
ok(Array.isArray(rec2) && rec2.filter((r) => r.status !== "PASS").length === 0, "ledger reconciles after margin + liquidation");

console.log("── Perpetual futures (mark / leverage / funding / liquidation) ──");
const setmark = (x) => execSync(`psql "${PGURL}" -tAqc "update perp_market set mark_price=${x} where symbol='BTC-PERP';"`);
setmark(100);
const PP = await signup("pp"); await fund(PP.pub, "EUR", 1000);
const peur = async () => Number((await get(PP.token, "cash_balances?currency=eq.EUR&select=available"))[0]?.available || 0);
const o = (await rpc(PP.token, "open_perp", { symbol_param: "BTC-PERP", size_param: 1, margin_param: 20 })).body;
ok(o && Number(o.leverage) === 5, "open long 1 @100 margin 20 (5x)");
ok(await peur() === 980, "margin locked (EUR 980)");
setmark(130);
const mp = (await get(PP.token, "my_perp?symbol=eq.BTC-PERP&select=upnl,equity"))[0];
ok(mp && Number(mp.upnl) === 30 && Number(mp.equity) === 50, "mark→130: uPnL 30, equity 50");
const cl = (await rpc(PP.token, "close_perp", { symbol_param: "BTC-PERP" })).body;
ok(cl && Number(cl.pnl) === 30 && Number(cl.payout) === 50, "close: pnl 30, payout 50");
ok(await peur() === 1030, "profit realized (EUR 1030)");
setmark(100);
const PL = await signup("pl"); await fund(PL.pub, "EUR", 1000);
await rpc(PL.token, "open_perp", { symbol_param: "BTC-PERP", size_param: 1, margin_param: 11 });
setmark(90);
ok(Number((await svc("check_perp_liquidations")).body) >= 1, "underwater long liquidated on price drop");
ok((await get(PL.token, "my_perp?select=symbol")).length === 0, "position cleared after liquidation");
setmark(100);
const PF = await signup("pf"); await fund(PF.pub, "EUR", 1000);
await rpc(PF.token, "open_perp", { symbol_param: "BTC-PERP", size_param: 1, margin_param: 50 });
execSync(`psql "${PGURL}" -tAqc "update perp_market set funding_rate=0.01 where symbol='BTC-PERP';"`);
await svc("apply_perp_funding");
ok(Math.abs(Number((await get(PF.token, "my_perp?symbol=eq.BTC-PERP&select=margin"))[0]?.margin) - 49) < 0.01, "funding charged long (margin 50→49)");
execSync(`psql "${PGURL}" -tAqc "update perp_market set funding_rate=0 where symbol='BTC-PERP';"`);
const rec3 = (await svc("reconcile")).body;
ok(Array.isArray(rec3) && rec3.filter((r) => r.status !== "PASS").length === 0, "ledger reconciles after perp trading");

console.log(failed ? `\n${failed} FAILED` : "\nall feature smokes passed");
process.exit(failed ? 1 : 0);
