// OUTCRY back-office — Supabase Auth + database RBAC console over the pure-PG CEX.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
const el = (s) => document.getElementById(s);
let sb = null;
let ADMIN_PERMS = new Set();

function toast(m, k = "") { const t = document.createElement("div"); t.className = "toast " + k; t.textContent = m; el("toasts").appendChild(t); setTimeout(() => t.remove(), 4200); }
const fmt = (n, d = 2) => (n == null || isNaN(n)) ? "—" : Number(n).toLocaleString(undefined, { minimumFractionDigits: d, maximumFractionDigits: d });
const escH = (s) => String(s ?? "").replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
const rpc = async (fn, args) => { const { data, error } = await sb.rpc(fn, args); if (error) { toast(`${fn}: ${error.message}`, "err"); throw error; } return data; };

const _q = new URLSearchParams(location.search);
const DEMO = _q.get("demo") === "1";
const can = (...permissions) => permissions.some((p) => ADMIN_PERMS.has(p));
const noPerm = (id, permission) => { el(id).innerHTML = `<div class="empty">Permission required: ${escH(permission)}</div>`; };
const noPermCount = (id) => { const x = el(id); if (x) x.textContent = "restricted"; };
const disabledAttr = (permission) => can(permission) ? "" : ` disabled title="requires ${permission}"`;
const ADMIN_SECTIONS = {
  overview: ["Operations overview", "Control room", "Live exchange health, treasury queues, account controls, product risk, security oversight, and audit evidence."],
  treasury: ["Treasury operations", "Cash and custody", "Run withdrawal signer queues, configure chain assets, inspect detected deposits, and clear unbacked funding exposure."],
  accounts: ["Client operations", "Accounts and payouts", "Review clients, suspend compromised accounts, restore cleared accounts, and settle referral liabilities."],
  markets: ["Market operations", "Products and risk", "Manage fee schedules, instrument risk limits, derivatives markets, margin terms, and staking pools."],
  security: ["Security operations", "Access oversight", "Review bot API access and revoke keys without entering the customer wallet surface."],
  audit: ["Compliance operations", "Audit trail", "Inspect immutable admin actions for incident review, compliance sampling, and operator accountability."],
};

function setAdminSection(section = "overview") {
  const next = ADMIN_SECTIONS[section] ? section : "overview";
  const [eyebrow, title, copy] = ADMIN_SECTIONS[next];
  el("opsEyebrow").textContent = eyebrow;
  el("opsTitle").textContent = title;
  el("opsCopy").textContent = copy;
  document.querySelectorAll("[data-admin-section]").forEach((b) => b.classList.toggle("on", b.dataset.adminSection === next));
  document.querySelectorAll("[data-section]").forEach((s) => s.classList.toggle("on", s.dataset.section === next));
}

function mirrorHtml(srcId, dstId) {
  const src = el(srcId), dst = el(dstId);
  if (src && dst) dst.innerHTML = src.innerHTML;
}
function mirrorText(srcId, dstId) {
  const src = el(srcId), dst = el(dstId);
  if (src && dst) dst.textContent = src.textContent;
}

el("opsNav").querySelectorAll("[data-admin-section]").forEach((b) => {
  b.onclick = () => setAdminSection(b.dataset.adminSection);
});
setAdminSection("overview");

function makeClient(api, anon, persistSession) {
  return createClient(api, anon, {
    auth: {
      persistSession,
      autoRefreshToken: persistSession,
      detectSessionInUrl: false,
      storage: window.sessionStorage,
    },
  });
}

async function openOperatorSession(api) {
  const { data: perms, error } = await sb.rpc("current_admin_permissions");
  if (error) {
    el("msg").textContent = "RBAC check failed: " + error.message;
    return false;
  }
  ADMIN_PERMS = new Set(perms || []);
  if (!ADMIN_PERMS.size) {
    await sb.auth.signOut();
    el("msg").textContent = "operator has no back-office permissions";
    return false;
  }
  sessionStorage.setItem("oc_admin_api", api);
  el("gate").style.display = "none";
  el("app").classList.add("live");
  refreshAll();
  return true;
}

// ---- gate ----
el("api").value = sessionStorage.getItem("oc_admin_api") || el("api").value;
if (_q.get("api")) el("api").value = _q.get("api");
el("anon").value = sessionStorage.getItem("oc_admin_anon") || _q.get("anon") || "";
el("email").value = sessionStorage.getItem("oc_admin_email") || "";
el("enter").onclick = enter;
el("pass").addEventListener("keydown", (e) => { if (e.key === "Enter") enter(); });
async function enter() {
  const api = el("api").value.trim(), anon = el("anon").value.trim();
  const email = el("email").value.trim(), password = el("pass").value;
  if (!api || !anon || !email || !password) {
    el("msg").textContent = "API URL, publishable key, email, and password are required";
    return;
  }
  sb = makeClient(api, anon, true);
  const login = await sb.auth.signInWithPassword({ email, password });
  if (login.error) {
    el("msg").textContent = "sign-in failed; creating test operator...";
    const created = await sb.auth.signUp({ email, password });
    if (created.error) {
      el("msg").textContent = `sign-in/create rejected: ${login.error.message}; ${created.error.message}`;
      return;
    }
    if (!created.data?.session) {
      el("msg").textContent = "test operator created; confirm email, then sign in";
      return;
    }
  }
  sessionStorage.setItem("oc_admin_anon", anon);
  sessionStorage.setItem("oc_admin_email", email);
  await openOperatorSession(api);
}
el("lock").onclick = async () => { await sb?.auth?.signOut(); location.reload(); };
el("refresh").onclick = refreshAll;

async function bootSession() {
  const api = el("api").value.trim(), anon = el("anon").value.trim();
  if (!api || !anon) return;
  sb = makeClient(api, anon, true);
  const { data } = await sb.auth.getSession();
  if (data?.session) await openOperatorSession(api);
}

async function refreshAll() {
  await Promise.all([
    loadRecon(), loadApprovals(), loadWithdrawQueue(), loadAccounts(), loadFees(), loadRisk(),
    loadReferrals(), loadChainOps(), loadApiKeys(), loadDeriv(), loadAudit(),
  ]);
  loadStats();
  syncActionState();
  el("opsUpdated").textContent = new Date().toLocaleTimeString();
}

function syncActionState() {
  const pairs = [
    ["setFee", "market.write"],
    ["setRisk", "market.write"],
  ];
  for (const [id, perm] of pairs) {
    const b = el(id);
    if (b) { b.disabled = !can(perm); b.title = can(perm) ? "" : `requires ${perm}`; }
  }
}

// ---- stats ----
let S = {};
function loadStats() {
  el("stats").innerHTML = [
    ["entities", S.entities ?? "—", S.suspended ? "" : ""],
    ["suspended", S.suspended ?? "—", S.suspended ? "warn" : "ok"],
    ["pending wallet", S.pending ?? "—", S.pending ? "warn" : "ok"],
    ["recon fails", S.reconFails ?? "—", S.reconFails ? "bad" : "ok"],
    ["funding exposure", S.fundingExposure ?? "—", S.fundingExposure ? "bad" : "ok"],
    ["ref. unpaid", S.refUnpaid ?? "—", S.refUnpaid ? "warn" : "ok"],
    ["audit (24h)", S.audit ?? "—", ""],
  ].map(([l, n, c]) => `<div class="stat"><div class="n ${c}">${n}</div><div class="l">${l}</div></div>`).join("");
}

// ---- reconciliation ----
async function loadRecon() {
  if (!can("recon.read")) {
    S.reconFails = "—";
    el("reconBadge").textContent = "RBAC";
    el("reconBadge").style.color = "var(--amber)";
    noPerm("recon", "recon.read");
    return;
  }
  const [coreRes, custodyRes, exposureRes] = await Promise.all([
    sb.from("reconciliation_report").select("check_name,failures,status"),
    sb.from("custody_reconciliation_report").select("check_name,failures,status"),
    sb.from("custody_funding_exposure").select("entity_pub_id,external_id,currency,source_kinds,outstanding_amount,available_cash,blocked_amount").order("outstanding_amount", { ascending: false }).limit(20),
  ]);
  const rows = coreRes.data || [];
  const custody = custodyRes.error ? [] : (custodyRes.data || []);
  const exposure = exposureRes.error ? [] : (exposureRes.data || []);
  const allRows = rows.concat(custody);
  S.reconFails = allRows.filter((r) => r.status !== "PASS").length;
  S.fundingExposure = exposure.length;
  el("reconBadge").textContent = S.reconFails ? `${S.reconFails} FAIL` : "ALL PASS";
  el("reconBadge").className = "" ; el("reconBadge").style.color = S.reconFails ? "var(--coral)" : "var(--phos)";
  el("reconWhen").textContent = new Date().toLocaleTimeString();
  const renderChecks = (items) => items.map((r) => `<div class="recon-row"><span class="nm">${r.check_name.replace(/_/g, " ")}</span><span class="v ${r.status}">${r.status}${r.failures ? " · " + r.failures : ""}</span></div>`).join("");
  const exposureHtml = exposure.length
    ? `<div class="recon-sub">Unbacked funding exposure</div><table><thead><tr><th>Entity</th><th>Cur</th><th>Source</th><th>Open</th><th>Available</th><th>Blocked</th></tr></thead><tbody>${
        exposure.map((r) => `<tr><td title="${escH(r.entity_pub_id)}">${escH((r.external_id || r.entity_pub_id || "—").slice(0, 18))}</td><td>${escH(r.currency)}</td><td>${escH(r.source_kinds)}</td><td class="mono-num down">${fmt(r.outstanding_amount, 6)}</td><td class="mono-num">${fmt(r.available_cash, 6)}</td><td class="mono-num ${Number(r.blocked_amount) ? "down" : "up"}">${fmt(r.blocked_amount, 6)}</td></tr>`).join("")}</tbody></table>${
        can("wallet.approve") ? `<div class="adm-form"><button class="btn-sm danger" data-reverse-unbacked="1">Reverse available unbacked cash</button></div>` : ""}`
    : `<div class="empty">No unbacked customer funding exposure.</div>`;
  el("recon").innerHTML =
    `<div class="recon-sub">Core ledger</div>${renderChecks(rows) || `<div class="empty">no core checks</div>`}` +
    `<div class="recon-sub">Custody funding</div>${renderChecks(custody) || `<div class="empty">custody checks unavailable</div>`}` +
    exposureHtml;
  document.querySelectorAll("[data-reverse-unbacked]").forEach((b) => b.onclick = async () => {
    const rows = await rpc("admin_reverse_unbacked_cash", { dry_run_param: false, entity_pub_param: null });
    toast(rows?.length ? `Reversed ${rows.length} exposure rows` : "No reversible available cash", rows?.length ? "warn" : "");
    refreshAll();
  });
}

// ---- approvals ----
async function loadApprovals() {
  if (!can("wallet.read")) {
    S.pending = "—";
    noPermCount("apprCount");
    noPerm("approvals", "wallet.read");
    mirrorText("apprCount", "apprCount2");
    mirrorHtml("approvals", "approvalsMirror");
    return;
  }
  const { data } = await sb.from("wallet_request").select("pub_id,direction,currency,amount,status,created_at,app_entity(external_id)").eq("status", "PENDING").order("created_at");
  const rows = data || [];
  S.pending = rows.length;
  const canApprove = can("wallet.approve");
  el("apprCount").textContent = `${rows.length} pending`;
  el("approvals").innerHTML = rows.length ? `<table><thead><tr><th>When</th><th>Entity</th><th>Dir</th><th>Cur</th><th>Amount</th><th>Action</th></tr></thead><tbody>${
    rows.map((r) => `<tr><td>${new Date(r.created_at).toLocaleTimeString()}</td><td>${(r.app_entity?.external_id || "—").slice(0, 14)}</td>
      <td class="${r.direction === "DEPOSIT" ? "up" : "down"}">${r.direction}</td><td>${r.currency}</td><td class="mono-num">${fmt(r.amount)}</td>
      <td>${canApprove ? (r.direction === "DEPOSIT"
        ? `<div class="act"><span class="label">chain credit only</span><button class="no" data-rej="${r.pub_id}">reject</button></div>`
        : `<div class="act"><button class="ok" data-appr="${r.pub_id}">approve</button><button class="no" data-rej="${r.pub_id}">reject</button></div>`) : `<span class="label">read only</span>`}</td></tr>`).join("")}</tbody></table>`
    : `<div class="empty">No pending wallet requests</div>`;
  mirrorText("apprCount", "apprCount2");
  mirrorHtml("approvals", "approvalsMirror");
  document.querySelectorAll("[data-appr]").forEach((b) => b.onclick = async () => { await rpc("approve_wallet_request", { request_pub_param: b.dataset.appr }); toast("Approved"); refreshAll(); });
  document.querySelectorAll("[data-rej]").forEach((b) => b.onclick = async () => { await rpc("reject_wallet_request", { request_pub_param: b.dataset.rej }); toast("Rejected", "warn"); refreshAll(); });
}

// ---- withdrawal signer queue ----
async function loadWithdrawQueue() {
  if (!can("wallet.read", "withdrawal.sign")) {
    noPermCount("wdqCount");
    noPerm("withdrawQueue", "wallet.read or withdrawal.sign");
    mirrorText("wdqCount", "wdqCount2");
    mirrorHtml("withdrawQueue", "withdrawQueueMirror");
    return;
  }
  const { data } = await sb.from("wallet_request")
    .select("pub_id,direction,currency,amount,to_address,status,created_at,resolved_at,signing_claimed_at,broadcast_txid,broadcast_at,confirmed_at,app_entity(external_id)")
    .eq("direction", "WITHDRAWAL")
    .eq("status", "APPROVED")
    .not("to_address", "is", null)
    .order("resolved_at", { ascending: false })
    .limit(50);
  const rows = data || [];
  const open = rows.filter((r) => !r.confirmed_at).length;
  el("wdqCount").textContent = open ? `${open} open` : "clear";
  const stage = (r) => r.confirmed_at ? "confirmed" : r.broadcast_txid ? "broadcast" : r.signing_claimed_at ? "claimed" : "queued";
  const canSign = can("withdrawal.sign");
  el("withdrawQueue").innerHTML = (canSign ? `<div class="adm-form"><button class="btn-sm" data-claim-withdrawal="1">Claim next to sign</button></div>` : "") +
    (rows.length ? `<table><thead><tr><th>Request</th><th>Entity</th><th>Cur</th><th>Amt</th><th>To</th><th>Stage</th><th>Action</th></tr></thead><tbody>${
      rows.map((r) => `<tr><td class="mono-num" title="${escH(r.pub_id)}">${escH(r.pub_id.slice(0, 10))}</td><td>${escH((r.app_entity?.external_id || "—").slice(0, 14))}</td>
        <td>${escH(r.currency)}</td><td class="mono-num">${fmt(r.amount, 4)}</td><td class="mono-num" title="${escH(r.to_address)}">${escH((r.to_address || "").slice(0, 14))}</td>
        <td><span class="pill ${stage(r).toUpperCase()}">${stage(r)}</span></td><td>${!canSign ? '<span class="label">read only</span>' : r.confirmed_at ? "" : r.broadcast_txid
          ? `<div class="act"><button class="ok" data-confirm-wd="${escH(r.pub_id)}">confirm</button></div>`
          : `<div class="act"><input class="txid-mini" data-txid-for="${escH(r.pub_id)}" placeholder="txid"/><button class="ok" data-broadcast-wd="${escH(r.pub_id)}">broadcast</button></div>`}</td></tr>`).join("")}</tbody></table>`
      : `<div class="empty">No on-chain withdrawals waiting for signer status.</div>`);
  mirrorText("wdqCount", "wdqCount2");
  mirrorHtml("withdrawQueue", "withdrawQueueMirror");
  document.querySelectorAll("[data-claim-withdrawal]").forEach((btn) => btn.onclick = async () => {
    const r = await rpc("next_withdrawal_to_sign", {});
    toast(r ? `Claimed ${r.pub_id?.slice(0, 10)} ${r.amount} ${r.currency}` : "No withdrawal to sign", r ? "warn" : "");
    refreshAll();
  });
  document.querySelectorAll("[data-broadcast-wd]").forEach((b) => b.onclick = async () => {
    const txid = b.parentElement.querySelector("[data-txid-for]")?.value.trim();
    if (!txid) return toast("txid required", "err");
    await rpc("mark_withdrawal_broadcast", { request_pub: b.dataset.broadcastWd, txid });
    toast("Withdrawal marked broadcast"); refreshAll();
  });
  document.querySelectorAll("[data-confirm-wd]").forEach((b) => b.onclick = async () => {
    await rpc("mark_withdrawal_confirmed", { request_pub: b.dataset.confirmWd });
    toast("Withdrawal confirmed"); refreshAll();
  });
}

// ---- accounts ----
async function loadAccounts() {
  if (!can("account.read")) {
    noPermCount("acctCount");
    noPerm("accounts", "account.read");
    return;
  }
  const { data } = await sb.from("app_entity").select("pub_id,external_id,type,status").order("created_at", { ascending: false }).limit(100);
  const rows = data || [];
  S.entities = rows.length; S.suspended = rows.filter((r) => r.status === "SUSPENDED").length;
  const canSuspend = can("account.suspend");
  el("acctCount").textContent = `${rows.length}`;
  el("accounts").innerHTML = `<table><thead><tr><th>External ID</th><th>Type</th><th>Status</th><th>Action</th></tr></thead><tbody>${
    rows.map((r) => `<tr><td title="${r.pub_id}">${(r.external_id || "—").slice(0, 22)}</td><td>${r.type}</td>
      <td><span class="pill ${r.status}">${r.status}</span></td>
      <td>${!canSuspend || r.type === "MASTER" ? "" : (r.status === "SUSPENDED"
        ? `<div class="act"><button class="ok" data-unsus="${r.pub_id}">unsuspend</button></div>`
        : `<div class="act"><button class="no" data-sus="${r.pub_id}">suspend</button></div>`)}</td></tr>`).join("")}</tbody></table>`;
  el("accounts").querySelectorAll("[data-sus]").forEach((b) => b.onclick = async () => { await rpc("admin_suspend_entity", { entity_pub: b.dataset.sus, reason: "admin console" }); toast("Suspended", "warn"); refreshAll(); });
  el("accounts").querySelectorAll("[data-unsus]").forEach((b) => b.onclick = async () => { await rpc("admin_unsuspend_entity", { entity_pub: b.dataset.unsus }); toast("Unsuspended"); refreshAll(); });
}

// ---- fees ----
async function loadFees() {
  if (!can("market.read")) {
    noPerm("fees", "market.read");
    return;
  }
  const { data } = await sb.from("fee").select("type,currency_name,percentage,min,max").order("type");
  el("fees").innerHTML = (data && data.length) ? `<table><thead><tr><th>Type</th><th>Cur</th><th>%</th><th>min</th><th>max</th></tr></thead><tbody>${
    data.map((f) => `<tr><td>${f.type}</td><td>${f.currency_name}</td><td class="mono-num">${f.percentage ?? "—"}</td><td class="mono-num">${f.min ?? "—"}</td><td class="mono-num">${f.max ?? "—"}</td></tr>`).join("")}</tbody></table>`
    : `<div class="empty">No fees configured</div>`;
}
el("setFee").onclick = async () => {
  if (!can("market.write")) return toast("requires market.write", "err");
  const t = el("feeType").value.trim(), c = el("feeCur").value.trim(), p = parseFloat(el("feePct").value);
  if (!t || !c || isNaN(p)) { toast("type, currency, % required", "err"); return; }
  await rpc("admin_set_fee", { fee_type: t, currency_param: c, percentage_param: p }); toast("Fee set"); loadFees(); loadAudit();
};

// ---- risk ----
async function loadRisk() {
  if (!can("market.read")) {
    noPerm("risk", "market.read");
    return;
  }
  const { data } = await sb.from("instrument_risk").select("max_order_amount,max_order_notional,price_band_pct,enabled,instrument(name)");
  el("risk").innerHTML = (data && data.length) ? `<table><thead><tr><th>Instrument</th><th>Max amt</th><th>Max notional</th><th>Band %</th></tr></thead><tbody>${
    data.map((r) => `<tr><td>${r.instrument?.name || "—"}</td><td class="mono-num">${fmt(r.max_order_amount, 2)}</td><td class="mono-num">${fmt(r.max_order_notional, 0)}</td><td class="mono-num">${r.price_band_pct ?? "—"}</td></tr>`).join("")}</tbody></table>`
    : `<div class="empty">No risk configured</div>`;
}
el("setRisk").onclick = async () => {
  if (!can("market.write")) return toast("requires market.write", "err");
  const i = el("rInst").value.trim(), a = parseFloat(el("rAmt").value), nn = parseFloat(el("rNot").value), b = parseFloat(el("rBand").value);
  if (!i) { toast("instrument required", "err"); return; }
  await rpc("admin_set_instrument_risk", { instrument_name_param: i, max_amount: a || null, max_notional: nn || null, band_pct: b || null }); toast("Risk set"); loadRisk(); loadAudit();
};

// ---- referral payouts (operator) ----
async function loadReferrals() {
  if (!can("referral.read")) {
    S.refUnpaid = "—";
    noPermCount("refCount");
    noPerm("referrals", "referral.read");
    mirrorText("refCount", "refCount2");
    mirrorHtml("referrals", "referralsMirror");
    return;
  }
  const [{ data: earn }, { data: ents }] = await Promise.all([
    sb.from("referral_earning").select("referrer_entity,currency,amount").is("paid_at", null),
    sb.from("app_entity").select("id,pub_id,external_id"),
  ]);
  const byId = new Map((ents || []).map((e) => [e.id, e]));
  const agg = new Map();   // key: referrer_entity|currency
  for (const r of (earn || [])) {
    const k = r.referrer_entity + "|" + r.currency;
    agg.set(k, (agg.get(k) || 0) + Number(r.amount));
  }
  const rows = [...agg.entries()].map(([k, total]) => {
    const [id, currency] = k.split("|"); const e = byId.get(+id) || {};
    return { pub: e.pub_id, label: e.external_id || e.pub_id, currency, total };
  }).sort((a, b) => b.total - a.total);
  S.refUnpaid = rows.length;
  const canPay = can("referral.pay");
  el("refCount").textContent = rows.length ? `${rows.length} owed` : "all settled";
  el("referrals").innerHTML = rows.length ? `<table><thead><tr><th>Referrer</th><th>Cur</th><th>Unpaid</th><th>Action</th></tr></thead><tbody>${
    rows.map((r) => `<tr><td title="${r.pub}">${(r.label || "—").slice(0, 18)}</td><td>${r.currency}</td><td class="mono-num">${fmt(r.total, 4)}</td>
      <td>${canPay ? `<div class="act"><button class="ok" data-pay="${r.pub}" data-cur="${r.currency}">pay</button></div>` : `<span class="label">read only</span>`}</td></tr>`).join("")}</tbody></table>`
    : `<div class="empty">No unpaid referral earnings</div>`;
  mirrorText("refCount", "refCount2");
  mirrorHtml("referrals", "referralsMirror");
  document.querySelectorAll("[data-pay]").forEach((b) => b.onclick = async () => {
    await rpc("pay_referral_earnings", { entity_pub: b.dataset.pay, currency_param: b.dataset.cur });
    toast("Referral earnings paid"); refreshAll();
  });
}

// ---- chain deposits (operator config + manual credit) ----
async function loadChainOps() {
  if (!can("chain.read")) {
    noPermCount("chainCount");
    noPerm("chainOps", "chain.read");
    return;
  }
  const [{ data: chains }, { data: assets }, { data: deps }] = await Promise.all([
    sb.from("chain").select("name,kind,rpc_url,confirmations,enabled").order("name"),
    sb.from("chain_asset").select("chain,token,currency,decimals").order("chain"),
    sb.from("chain_deposit").select("chain,txid,address,currency,amount,confirmations,credited_at,created_at").order("created_at", { ascending: false }).limit(20),
  ]);
  const canWrite = can("chain.write");
  el("chainCount").textContent = `${chains?.length || 0} chains`;
  el("chainOps").innerHTML =
    ((chains && chains.length) ? `<table><thead><tr><th>Chain</th><th>Kind</th><th>Enabled</th><th>Conf</th><th>RPC</th></tr></thead><tbody>${
      chains.map((c) => `<tr><td>${escH(c.name)}</td><td>${escH(c.kind)}</td><td class="${c.enabled ? "up" : "amber"}">${c.enabled ? "on" : "off"}</td><td class="mono-num">${c.confirmations}</td><td title="${escH(c.rpc_url || "")}">${c.rpc_url ? "set" : "—"}</td></tr>`).join("")}</tbody></table>` : `<div class="empty">No chain config</div>`) +
    (canWrite ? `<div class="adm-form">
      <div class="row3"><input id="chainName" placeholder="ethereum-sepolia" /><input id="chainRpc" placeholder="rpc url (blank keep)" /><input id="chainConf" type="number" step="1" placeholder="confirmations" /></div>
      <div class="row3"><select id="chainEnabled"><option value="">keep enabled</option><option value="true">enabled</option><option value="false">disabled</option></select><button class="btn-sm" id="setChainConfig" style="grid-column:span 2">Set chain config</button></div>
    </div>` : "") +
    ((assets && assets.length) ? `<table><thead><tr><th>Chain</th><th>Token</th><th>Currency</th><th>Decimals</th></tr></thead><tbody>${
      assets.map((a) => `<tr><td>${escH(a.chain)}</td><td class="mono-num" title="${escH(a.token)}">${escH((a.token || "").slice(0, 18))}</td><td>${escH(a.currency)}</td><td class="mono-num">${a.decimals}</td></tr>`).join("")}</tbody></table>` : `<div class="empty">No chain assets mapped</div>`) +
    (canWrite ? `<div class="adm-form">
      <div class="row3"><input id="assetChain" placeholder="chain" /><input id="assetToken" placeholder="native or token" /><input id="assetCur" placeholder="EUR" /></div>
      <div class="row3"><input id="assetDecimals" type="number" step="1" placeholder="decimals" /><button class="btn-sm" id="setChainAsset" style="grid-column:span 2">Set asset mapping</button></div>
    </div>` : "") +
    (canWrite ? `<div class="adm-form">
      <div class="row3"><input id="depChain" placeholder="chain" /><input id="depTx" placeholder="txid" /><input id="depIdx" type="number" step="1" value="0" placeholder="log idx" /></div>
      <div class="row3"><input id="depAddr" placeholder="watched address" /><input id="depCur" placeholder="currency" /><input id="depAmt" type="number" step="0.000001" placeholder="amount" /></div>
      <div class="row3"><input id="depConf" type="number" step="1" placeholder="confirmations" /><button class="btn-sm" id="manualCredit" style="grid-column:span 2">Credit observed tx</button></div>
    </div>` : "") +
    ((deps && deps.length) ? `<table><thead><tr><th>When</th><th>Chain</th><th>Tx</th><th>Cur</th><th>Amount</th><th>Status</th></tr></thead><tbody>${
      deps.map((d) => `<tr><td>${new Date(d.created_at).toLocaleString()}</td><td>${escH(d.chain)}</td><td class="mono-num" title="${escH(d.txid)}">${escH((d.txid || "").slice(0, 12))}</td><td>${escH(d.currency)}</td><td class="mono-num">${fmt(d.amount, 6)}</td><td>${d.credited_at ? '<span class="up">credited</span>' : '<span class="amber">pending</span>'}</td></tr>`).join("")}</tbody></table>` : `<div class="empty">No detected chain deposits</div>`);

  if (!canWrite) return;
  el("setChainConfig").onclick = async () => {
    const name = el("chainName").value.trim();
    if (!name) return toast("chain required", "err");
    const conf = parseInt(el("chainConf").value, 10);
    const enabled = el("chainEnabled").value;
    await rpc("admin_set_chain_config", {
      chain_param: name,
      rpc_url_param: el("chainRpc").value.trim() || null,
      confirmations_param: Number.isFinite(conf) ? conf : null,
      enabled_param: enabled === "" ? null : enabled === "true",
    });
    toast("Chain config updated"); refreshAll();
  };
  el("setChainAsset").onclick = async () => {
    const dec = parseInt(el("assetDecimals").value, 10);
    await rpc("admin_set_chain_asset", {
      chain_param: el("assetChain").value.trim(),
      token_param: el("assetToken").value.trim(),
      currency_param: el("assetCur").value.trim(),
      decimals_param: Number.isFinite(dec) ? dec : null,
    });
    toast("Asset mapping updated"); refreshAll();
  };
  el("manualCredit").onclick = async () => {
    const idx = parseInt(el("depIdx").value, 10), conf = parseInt(el("depConf").value, 10);
    const amt = parseFloat(el("depAmt").value);
    await rpc("credit_chain_deposit", {
      chain_param: el("depChain").value.trim(),
      txid_param: el("depTx").value.trim(),
      log_index_param: Number.isFinite(idx) ? idx : 0,
      address_param: el("depAddr").value.trim(),
      currency_param: el("depCur").value.trim(),
      amount_param: amt,
      confirmations_param: Number.isFinite(conf) ? conf : 0,
    });
    toast("Deposit credit submitted"); refreshAll();
  };
}

// ---- API key oversight ----
async function loadApiKeys() {
  if (!can("security.read")) {
    noPermCount("keyCount");
    noPerm("apiKeys", "security.read");
    return;
  }
  const { data } = await sb.from("api_key")
    .select("key_id,label,scopes,last_used_at,revoked_at,created_at,app_entity(external_id)")
    .order("created_at", { ascending: false })
    .limit(80);
  const rows = data || [];
  const active = rows.filter((k) => !k.revoked_at).length;
  const canRevoke = can("security.revoke_api_key");
  el("keyCount").textContent = `${active} active`;
  el("apiKeys").innerHTML = rows.length ? `<table><thead><tr><th>Key</th><th>Entity</th><th>Label</th><th>Scopes</th><th>Last used</th><th></th></tr></thead><tbody>${
    rows.map((k) => `<tr><td class="mono-num">${escH(k.key_id)}</td><td>${escH((k.app_entity?.external_id || "—").slice(0, 14))}</td><td>${escH(k.label || "—")}</td><td>${escH((k.scopes || []).join(","))}</td>
      <td>${k.last_used_at ? new Date(k.last_used_at).toLocaleString() : "—"}</td><td>${k.revoked_at ? '<span class="down">revoked</span>' : canRevoke ? `<div class="act"><button class="no" data-revoke-key="${escH(k.key_id)}">revoke</button></div>` : `<span class="label">read only</span>`}</td></tr>`).join("")}</tbody></table>`
    : `<div class="empty">No API keys</div>`;
  el("apiKeys").querySelectorAll("[data-revoke-key]").forEach((b) => b.onclick = async () => {
    await rpc("admin_revoke_api_key", { key_id_param: b.dataset.revokeKey });
    toast("API key revoked", "warn"); refreshAll();
  });
}

// ---- derivatives & staking (operator) ----
async function loadDeriv() {
  if (!can("derivatives.read")) {
    noPermCount("derivWhen");
    noPerm("deriv", "derivatives.read");
    return;
  }
  const [{ data: pools }, { data: stakeCfg }, { data: terms }, { data: mkts }, { data: perps }, { data: loans }] = await Promise.all([
    sb.from("stake_pool").select("currency,apr,total_staked").order("currency"),
    sb.from("stake_config").select("unbond_seconds").maybeSingle(),
    sb.from("margin_config").select("max_leverage,maintenance_ratio,borrow_apr").maybeSingle(),
    sb.from("perp_markets").select("symbol,index_symbol,margin_currency,mark_price,funding_rate,max_leverage,maintenance_ratio").order("symbol"),
    sb.from("perp_position").select("symbol,size,margin"),
    sb.from("margin_loan").select("currency,principal,accrued"),
  ]);
  el("derivWhen").textContent = new Date().toLocaleTimeString();
  const numOrNull = (id) => {
    const v = parseFloat(el(id).value);
    return Number.isFinite(v) ? v : null;
  };
  const perpBySym = new Map();
  for (const p of (perps || [])) { const e = perpBySym.get(p.symbol) || { n: 0, marg: 0 }; e.n++; e.marg += Number(p.margin); perpBySym.set(p.symbol, e); }
  const loanByCur = new Map();
  for (const l of (loans || [])) loanByCur.set(l.currency, (loanByCur.get(l.currency) || 0) + Number(l.principal) + Number(l.accrued));
  const sec = (title, inner) => `<div class="recon-row" style="font-weight:600;color:var(--ink-dim)">${title}</div>${inner}`;
  const canWrite = can("derivatives.write");
  el("deriv").innerHTML =
    sec("Staking pools", (pools && pools.length) ? `<table><thead><tr><th>Cur</th><th>APR</th><th>Total staked</th></tr></thead><tbody>${
        pools.map((p) => `<tr><td>${escH(p.currency)}</td><td class="up">${fmt(p.apr * 100, 2)}%</td><td class="mono-num">${fmt(p.total_staked, 4)}</td></tr>`).join("")}</tbody></table>` : `<div class="empty">none</div>`) +
    (canWrite ? `<div class="adm-form">
      <div class="row3"><input id="stAdmCur" placeholder="EUR" /><input id="stAdmApr" type="number" step="0.01" placeholder="APR %" /><input id="stAdmUnbond" type="number" step="1" value="${stakeCfg?.unbond_seconds ?? 604800}" placeholder="unbond sec" /></div>
      <button class="btn-sm" id="setStakePool">Set stake pool</button>
    </div>` : "") +
    sec("Margin terms", terms ? `<table><thead><tr><th>Max leverage</th><th>Maintenance</th><th>Borrow APR</th></tr></thead><tbody><tr>
        <td class="mono-num">${fmt(terms.max_leverage, 0)}×</td><td class="mono-num">${fmt(terms.maintenance_ratio * 100, 2)}%</td><td class="mono-num">${fmt(terms.borrow_apr * 100, 2)}%</td></tr></tbody></table>` : `<div class="empty">none</div>`) +
    (canWrite ? `<div class="adm-form">
      <div class="row3"><input id="mgAdmLev" type="number" step="0.1" value="${terms?.max_leverage ?? 3}" placeholder="max lev" /><input id="mgAdmMaint" type="number" step="0.01" value="${terms ? terms.maintenance_ratio * 100 : 10}" placeholder="maint %" /><input id="mgAdmApr" type="number" step="0.01" value="${terms ? terms.borrow_apr * 100 : 10}" placeholder="borrow APR %" /></div>
      <button class="btn-sm" id="setMarginTerms">Set margin terms</button>
    </div>` : "") +
    sec("Perp markets", (mkts && mkts.length) ? `<table><thead><tr><th>Symbol</th><th>Mark</th><th>Funding</th><th>Open</th><th>Margin</th></tr></thead><tbody>${
        mkts.map((m) => { const e = perpBySym.get(m.symbol) || { n: 0, marg: 0 }; return `<tr><td>${escH(m.symbol)}</td><td class="mono-num">${fmt(m.mark_price, 2)}</td><td class="mono-num">${fmt(m.funding_rate * 100, 4)}%</td><td class="mono-num">${e.n}</td><td class="mono-num">${fmt(e.marg, 2)}</td></tr>`; }).join("")}</tbody></table>` : `<div class="empty">none</div>`) +
    (canWrite ? `<div class="adm-form">
      <div class="row3"><input id="ppAdmSym" placeholder="BTC-PERP" /><input id="ppAdmIndex" placeholder="BTC_EUR" /><input id="ppAdmCur" placeholder="EUR" /></div>
      <div class="row3"><input id="ppAdmMark" type="number" step="0.01" placeholder="mark" /><input id="ppAdmFunding" type="number" step="0.0001" placeholder="funding %" /><input id="ppAdmLev" type="number" step="0.1" placeholder="max lev" /></div>
      <div class="row3"><input id="ppAdmMaint" type="number" step="0.01" placeholder="maint %" /><button class="btn-sm" id="setPerpMarket" style="grid-column:span 2">Set perp market</button></div>
    </div>` : "") +
    sec("Margin loans outstanding", loanByCur.size ? `<table><thead><tr><th>Cur</th><th>Debt (principal+accrued)</th></tr></thead><tbody>${
        [...loanByCur.entries()].map(([c, d]) => `<tr><td>${escH(c)}</td><td class="mono-num down">${fmt(d, 4)}</td></tr>`).join("")}</tbody></table>` : `<div class="empty">no open loans</div>`) +
    (canWrite ? `<div class="adm-form">
      <div class="act">
        <button class="ok" id="runDerivJobs">run marks/liquidations/unbond</button>
        <button class="ok" id="runFundingNow">apply funding now</button>
      </div>
    </div>` : "");

  if (!canWrite) return;
  el("setStakePool").onclick = async () => {
    const cur = el("stAdmCur").value.trim(), apr = numOrNull("stAdmApr"), ub = numOrNull("stAdmUnbond");
    if (!cur || apr == null) return toast("stake currency + APR required", "err");
    await rpc("admin_set_stake_pool", { currency_param: cur, apr_param: apr / 100, unbond_seconds_param: ub == null ? null : Math.trunc(ub) });
    toast("Stake pool updated"); refreshAll();
  };
  el("setMarginTerms").onclick = async () => {
    const lev = numOrNull("mgAdmLev"), maint = numOrNull("mgAdmMaint"), apr = numOrNull("mgAdmApr");
    if (lev == null || maint == null || apr == null) return toast("margin terms required", "err");
    await rpc("admin_set_margin_terms", { max_leverage_param: lev, maintenance_ratio_param: maint / 100, borrow_apr_param: apr / 100 });
    toast("Margin terms updated"); refreshAll();
  };
  el("setPerpMarket").onclick = async () => {
    const sym = el("ppAdmSym").value.trim();
    if (!sym) return toast("perp symbol required", "err");
    await rpc("admin_set_perp_market", {
      symbol_param: sym,
      index_symbol_param: el("ppAdmIndex").value.trim() || null,
      margin_currency_param: el("ppAdmCur").value.trim() || null,
      mark_price_param: numOrNull("ppAdmMark"),
      funding_rate_param: numOrNull("ppAdmFunding") == null ? null : numOrNull("ppAdmFunding") / 100,
      max_leverage_param: numOrNull("ppAdmLev"),
      maintenance_ratio_param: numOrNull("ppAdmMaint") == null ? null : numOrNull("ppAdmMaint") / 100,
    });
    toast("Perp market updated"); refreshAll();
  };
  el("runDerivJobs").onclick = async () => {
    const r = await rpc("admin_run_derivative_jobs", { update_marks: true, apply_funding: false, check_perps: true, check_margin: true, process_unbonds: true });
    toast(`Jobs: ${JSON.stringify(r)}`); refreshAll();
  };
  el("runFundingNow").onclick = async () => {
    const r = await rpc("admin_run_derivative_jobs", { update_marks: true, apply_funding: true, check_perps: true, check_margin: true, process_unbonds: true });
    toast(`Funding: ${JSON.stringify(r)}`, "warn"); refreshAll();
  };
}

// ---- audit ----
async function loadAudit() {
  if (!can("audit.read")) {
    noPermCount("auditCount");
    noPerm("audit", "audit.read");
    return;
  }
  const { data } = await sb.from("admin_audit_log").select("action,target,detail,created_at").order("created_at", { ascending: false }).limit(40);
  const rows = data || [];
  const dayAgo = Date.now() - 864e5; S.audit = rows.filter((r) => new Date(r.created_at).getTime() > dayAgo).length;
  el("auditCount").textContent = `${rows.length}`;
  el("audit").innerHTML = rows.length ? `<table><thead><tr><th>When</th><th>Action</th><th>Target</th><th>Detail</th></tr></thead><tbody>${
    rows.map((r) => `<tr><td>${new Date(r.created_at).toLocaleString()}</td><td class="amber">${r.action}</td><td>${(r.target || "").slice(0, 18)}</td><td style="color:var(--ink-dim)">${r.detail ? JSON.stringify(r.detail).slice(0, 60) : ""}</td></tr>`).join("")}</tbody></table>`
    : `<div class="empty">No admin actions yet</div>`;
}

// ---- read-only public demo (anon key, no service_role) ----
async function bootDemo() {
  const api = _q.get("api") || el("api").value.trim();
  const anon = _q.get("anon");
  if (!anon) { el("msg").textContent = "demo mode needs ?anon=<publishable key>"; return; }
  sb = createClient(api, anon, { auth: { persistSession: false } });
  el("gate").style.display = "none"; el("app").classList.add("live");
  const banner = document.createElement("div");
  banner.className = "demo-banner";
  banner.textContent = "READ-ONLY DEMO · live data from the hosted pg-outcry back-office · actions disabled";
  document.body.insertBefore(banner, document.body.firstChild);
  ["setFee", "setRisk"].forEach((id) => { const b = el(id); if (b) { b.disabled = true; b.title = "read-only demo"; } });
  // forms have no meaning in read-only demo
  document.querySelectorAll(".adm-form").forEach((f) => f.style.display = "none");
  el("refresh").onclick = refreshDemo;
  refreshDemo();
}

async function refreshDemo() {
  let d;
  try { d = await rpc("demo_admin_overview"); } catch { return; }
  const recon = d.recon || [], appr = d.approvals || [], accts = d.accounts || [],
        fees = d.fees || [], risk = d.risk || [], audit = d.audit || [], refs = d.referrals || [];
  const reconFails = recon.filter((r) => r.status !== "PASS").length;
  S = { entities: accts.length, suspended: accts.filter((a) => a.status === "SUSPENDED").length,
        pending: appr.length, reconFails, audit: audit.length, refUnpaid: refs.length };
  loadStats();
  el("opsUpdated").textContent = new Date().toLocaleTimeString();

  el("reconBadge").textContent = reconFails ? `${reconFails} FAIL` : "ALL PASS";
  el("reconBadge").style.color = reconFails ? "var(--coral)" : "var(--phos)";
  el("reconWhen").textContent = new Date().toLocaleTimeString();
  el("recon").innerHTML = recon.map((r) => `<div class="recon-row"><span class="nm">${r.check_name.replace(/_/g, " ")}</span><span class="v ${r.status}">${r.status}${r.failures ? " · " + r.failures : ""}</span></div>`).join("") || `<div class="empty">no checks</div>`;

  el("apprCount").textContent = `${appr.length} pending`;
  el("approvals").innerHTML = appr.length ? `<table><thead><tr><th>When</th><th>Entity</th><th>Dir</th><th>Cur</th><th>Amount</th></tr></thead><tbody>${
    appr.map((r) => `<tr><td>${new Date(r.created_at).toLocaleTimeString()}</td><td>${(r.external_id || "—").slice(0, 14)}</td><td class="${r.direction === "DEPOSIT" ? "up" : "down"}">${r.direction}</td><td>${r.currency}</td><td class="mono-num">${fmt(r.amount)}</td></tr>`).join("")}</tbody></table>` : `<div class="empty">No pending wallet requests</div>`;
  mirrorText("apprCount", "apprCount2");
  mirrorHtml("approvals", "approvalsMirror");

  const wdq = d.withdrawal_queue || [];
  el("wdqCount").textContent = `${wdq.filter((w) => !w.confirmed_at).length} open`;
  el("withdrawQueue").innerHTML = wdq.length ? `<table><thead><tr><th>Request</th><th>Cur</th><th>Amt</th><th>To</th><th>Stage</th></tr></thead><tbody>${
    wdq.map((w) => `<tr><td class="mono-num">${escH((w.pub_id || "").slice(0, 10))}</td><td>${escH(w.currency)}</td><td class="mono-num">${fmt(w.amount, 4)}</td><td class="mono-num">${escH((w.to_address || "").slice(0, 14))}</td><td>${w.confirmed_at ? "confirmed" : w.broadcast_txid ? "broadcast" : w.signing_claimed_at ? "claimed" : "queued"}</td></tr>`).join("")}</tbody></table>` : `<div class="empty">No signer queue items</div>`;
  mirrorText("wdqCount", "wdqCount2");
  mirrorHtml("withdrawQueue", "withdrawQueueMirror");

  el("acctCount").textContent = `${accts.length}`;
  el("accounts").innerHTML = `<table><thead><tr><th>External ID</th><th>Type</th><th>Status</th></tr></thead><tbody>${
    accts.map((r) => `<tr><td>${(r.external_id || "—").slice(0, 22)}</td><td>${r.type}</td><td><span class="pill ${r.status}">${r.status}</span></td></tr>`).join("")}</tbody></table>`;

  el("fees").innerHTML = fees.length ? `<table><thead><tr><th>Type</th><th>Cur</th><th>%</th><th>min</th><th>max</th></tr></thead><tbody>${
    fees.map((f) => `<tr><td>${f.type}</td><td>${f.currency_name}</td><td class="mono-num">${f.percentage ?? "—"}</td><td class="mono-num">${f.min ?? "—"}</td><td class="mono-num">${f.max ?? "—"}</td></tr>`).join("")}</tbody></table>` : `<div class="empty">No fees configured</div>`;

  el("risk").innerHTML = risk.length ? `<table><thead><tr><th>Instrument</th><th>Max amt</th><th>Max notional</th><th>Band %</th></tr></thead><tbody>${
    risk.map((r) => `<tr><td>${r.instrument || "—"}</td><td class="mono-num">${fmt(r.max_order_amount, 2)}</td><td class="mono-num">${fmt(r.max_order_notional, 0)}</td><td class="mono-num">${r.price_band_pct ?? "—"}</td></tr>`).join("")}</tbody></table>` : `<div class="empty">No risk configured</div>`;

  el("auditCount").textContent = `${audit.length}`;
  el("audit").innerHTML = audit.length ? `<table><thead><tr><th>When</th><th>Action</th><th>Target</th><th>Detail</th></tr></thead><tbody>${
    audit.map((r) => `<tr><td>${new Date(r.created_at).toLocaleString()}</td><td class="amber">${r.action}</td><td>${(r.target || "").slice(0, 18)}</td><td style="color:var(--ink-dim)">${r.detail ? JSON.stringify(r.detail).slice(0, 60) : ""}</td></tr>`).join("")}</tbody></table>` : `<div class="empty">No admin actions yet</div>`;

  // referral payouts (read-only)
  S.refUnpaid = refs.length; loadStats();
  el("refCount").textContent = refs.length ? `${refs.length} owed` : "all settled";
  el("referrals").innerHTML = refs.length ? `<table><thead><tr><th>Referrer</th><th>Cur</th><th>Unpaid</th></tr></thead><tbody>${
    refs.map((r) => `<tr><td>${(r.label || "—").slice(0, 18)}</td><td>${r.currency}</td><td class="mono-num">${fmt(r.total, 4)}</td></tr>`).join("")}</tbody></table>` : `<div class="empty">No unpaid referral earnings</div>`;
  mirrorText("refCount", "refCount2");
  mirrorHtml("referrals", "referralsMirror");

  const chains = d.chains || [], deposits = d.chain_deposits || [];
  el("chainCount").textContent = `${chains.length} chains`;
  el("chainOps").innerHTML =
    (chains.length ? `<table><thead><tr><th>Chain</th><th>Kind</th><th>Enabled</th><th>Conf</th></tr></thead><tbody>${
      chains.map((c) => `<tr><td>${escH(c.name)}</td><td>${escH(c.kind)}</td><td>${c.enabled ? "on" : "off"}</td><td class="mono-num">${c.confirmations}</td></tr>`).join("")}</tbody></table>` : `<div class="empty">No chain config</div>`) +
    (deposits.length ? `<table><thead><tr><th>Chain</th><th>Tx</th><th>Cur</th><th>Amount</th><th>Status</th></tr></thead><tbody>${
      deposits.map((d) => `<tr><td>${escH(d.chain)}</td><td class="mono-num">${escH((d.txid || "").slice(0, 12))}</td><td>${escH(d.currency)}</td><td class="mono-num">${fmt(d.amount, 6)}</td><td>${d.credited_at ? "credited" : "pending"}</td></tr>`).join("")}</tbody></table>` : `<div class="empty">No chain deposits</div>`);

  const keys = d.api_keys || [];
  el("keyCount").textContent = `${keys.filter((k) => !k.revoked_at).length} active`;
  el("apiKeys").innerHTML = keys.length ? `<table><thead><tr><th>Key</th><th>Entity</th><th>Label</th><th>Last used</th><th>Status</th></tr></thead><tbody>${
    keys.map((k) => `<tr><td class="mono-num">${escH(k.key_id)}</td><td>${escH((k.external_id || "—").slice(0, 14))}</td><td>${escH(k.label || "—")}</td><td>${k.last_used_at ? new Date(k.last_used_at).toLocaleString() : "—"}</td><td>${k.revoked_at ? "revoked" : "active"}</td></tr>`).join("")}</tbody></table>` : `<div class="empty">No API keys</div>`;

  // derivatives & staking (read-only)
  const pools = d.stake_pools || [], mkts = d.perp_markets || [], loans = d.margin_loans || [];
  el("derivWhen").textContent = new Date().toLocaleTimeString();
  const sec = (title, inner) => `<div class="recon-row" style="font-weight:600;color:var(--ink-dim)">${title}</div>${inner}`;
  el("deriv").innerHTML =
    sec("Staking pools", pools.length ? `<table><thead><tr><th>Cur</th><th>APR</th><th>Total staked</th></tr></thead><tbody>${
      pools.map((p) => `<tr><td>${p.currency}</td><td class="up">${fmt(p.apr * 100, 2)}%</td><td class="mono-num">${fmt(p.total_staked, 4)}</td></tr>`).join("")}</tbody></table>` : `<div class="empty">none</div>`) +
    sec("Perp markets", mkts.length ? `<table><thead><tr><th>Symbol</th><th>Mark</th><th>Funding</th><th>Open</th><th>Margin</th></tr></thead><tbody>${
      mkts.map((m) => `<tr><td>${m.symbol}</td><td class="mono-num">${fmt(m.mark_price, 2)}</td><td class="mono-num">${fmt(m.funding_rate * 100, 4)}%</td><td class="mono-num">${m.open}</td><td class="mono-num">${fmt(m.margin, 2)}</td></tr>`).join("")}</tbody></table>` : `<div class="empty">none</div>`) +
    sec("Margin loans outstanding", loans.length ? `<table><thead><tr><th>Cur</th><th>Debt</th></tr></thead><tbody>${
      loans.map((l) => `<tr><td>${l.currency}</td><td class="mono-num down">${fmt(l.debt, 4)}</td></tr>`).join("")}</tbody></table>` : `<div class="empty">no open loans</div>`);
}

if (DEMO) bootDemo();
// auto-enter if the operator still has a Supabase Auth session in sessionStorage
else bootSession();
