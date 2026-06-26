// OUTCRY back-office — service_role admin console over the pure-PG CEX.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
const el = (s) => document.getElementById(s);
let sb = null;

function toast(m, k = "") { const t = document.createElement("div"); t.className = "toast " + k; t.textContent = m; el("toasts").appendChild(t); setTimeout(() => t.remove(), 4200); }
const fmt = (n, d = 2) => (n == null || isNaN(n)) ? "—" : Number(n).toLocaleString(undefined, { minimumFractionDigits: d, maximumFractionDigits: d });
const rpc = async (fn, args) => { const { data, error } = await sb.rpc(fn, args); if (error) { toast(`${fn}: ${error.message}`, "err"); throw error; } return data; };

const _q = new URLSearchParams(location.search);
const DEMO = _q.get("demo") === "1";

// ---- gate ----
el("api").value = sessionStorage.getItem("oc_admin_api") || el("api").value;
if (_q.get("api")) el("api").value = _q.get("api");
if (sessionStorage.getItem("oc_admin_svc")) { el("svc").value = sessionStorage.getItem("oc_admin_svc"); }
el("enter").onclick = enter;
el("svc").addEventListener("keydown", (e) => { if (e.key === "Enter") enter(); });
async function enter() {
  const api = el("api").value.trim(), svc = el("svc").value.trim();
  if (!svc) { el("msg").textContent = "service_role key required"; return; }
  sb = createClient(api, svc, { auth: { persistSession: false } });
  // probe: reconcile() is service_role-only — confirms the key works
  const { error } = await sb.rpc("reconcile");
  if (error) { el("msg").textContent = "key rejected: " + error.message; return; }
  sessionStorage.setItem("oc_admin_api", api); sessionStorage.setItem("oc_admin_svc", svc);
  el("gate").style.display = "none"; el("app").classList.add("live");
  refreshAll();
}
el("lock").onclick = () => { sessionStorage.removeItem("oc_admin_svc"); location.reload(); };
el("refresh").onclick = refreshAll;

async function refreshAll() {
  await Promise.all([loadRecon(), loadApprovals(), loadAccounts(), loadFees(), loadRisk(), loadAudit()]);
  loadStats();
}

// ---- stats ----
let S = {};
function loadStats() {
  el("stats").innerHTML = [
    ["entities", S.entities ?? "—", S.suspended ? "" : ""],
    ["suspended", S.suspended ?? "—", S.suspended ? "warn" : "ok"],
    ["pending wallet", S.pending ?? "—", S.pending ? "warn" : "ok"],
    ["recon fails", S.reconFails ?? "—", S.reconFails ? "bad" : "ok"],
    ["audit (24h)", S.audit ?? "—", ""],
  ].map(([l, n, c]) => `<div class="stat"><div class="n ${c}">${n}</div><div class="l">${l}</div></div>`).join("");
}

// ---- reconciliation ----
async function loadRecon() {
  const { data } = await sb.from("reconciliation_report").select("check_name,failures,status");
  const rows = data || [];
  S.reconFails = rows.filter((r) => r.status !== "PASS").length;
  el("reconBadge").textContent = S.reconFails ? `${S.reconFails} FAIL` : "ALL PASS";
  el("reconBadge").className = "" ; el("reconBadge").style.color = S.reconFails ? "var(--coral)" : "var(--phos)";
  el("reconWhen").textContent = new Date().toLocaleTimeString();
  el("recon").innerHTML = rows.map((r) => `<div class="recon-row"><span class="nm">${r.check_name.replace(/_/g, " ")}</span><span class="v ${r.status}">${r.status}${r.failures ? " · " + r.failures : ""}</span></div>`).join("")
    || `<div class="empty">no checks</div>`;
}

// ---- approvals ----
async function loadApprovals() {
  const { data } = await sb.from("wallet_request").select("pub_id,direction,currency,amount,status,created_at,app_entity(external_id)").eq("status", "PENDING").order("created_at");
  const rows = data || [];
  S.pending = rows.length;
  el("apprCount").textContent = `${rows.length} pending`;
  el("approvals").innerHTML = rows.length ? `<table><thead><tr><th>When</th><th>Entity</th><th>Dir</th><th>Cur</th><th>Amount</th><th>Action</th></tr></thead><tbody>${
    rows.map((r) => `<tr><td>${new Date(r.created_at).toLocaleTimeString()}</td><td>${(r.app_entity?.external_id || "—").slice(0, 14)}</td>
      <td class="${r.direction === "DEPOSIT" ? "up" : "down"}">${r.direction}</td><td>${r.currency}</td><td class="mono-num">${fmt(r.amount)}</td>
      <td><div class="act"><button class="ok" data-appr="${r.pub_id}">approve</button><button class="no" data-rej="${r.pub_id}">reject</button></div></td></tr>`).join("")}</tbody></table>`
    : `<div class="empty">No pending wallet requests</div>`;
  el("approvals").querySelectorAll("[data-appr]").forEach((b) => b.onclick = async () => { await rpc("approve_wallet_request", { request_pub_param: b.dataset.appr }); toast("Approved"); refreshAll(); });
  el("approvals").querySelectorAll("[data-rej]").forEach((b) => b.onclick = async () => { await rpc("reject_wallet_request", { request_pub_param: b.dataset.rej }); toast("Rejected", "warn"); refreshAll(); });
}

// ---- accounts ----
async function loadAccounts() {
  const { data } = await sb.from("app_entity").select("pub_id,external_id,type,status").order("created_at", { ascending: false }).limit(100);
  const rows = data || [];
  S.entities = rows.length; S.suspended = rows.filter((r) => r.status === "SUSPENDED").length;
  el("acctCount").textContent = `${rows.length}`;
  el("accounts").innerHTML = `<table><thead><tr><th>External ID</th><th>Type</th><th>Status</th><th>Action</th></tr></thead><tbody>${
    rows.map((r) => `<tr><td title="${r.pub_id}">${(r.external_id || "—").slice(0, 22)}</td><td>${r.type}</td>
      <td><span class="pill ${r.status}">${r.status}</span></td>
      <td>${r.type === "MASTER" ? "" : (r.status === "SUSPENDED"
        ? `<div class="act"><button class="ok" data-unsus="${r.pub_id}">unsuspend</button></div>`
        : `<div class="act"><button class="no" data-sus="${r.pub_id}">suspend</button></div>`)}</td></tr>`).join("")}</tbody></table>`;
  el("accounts").querySelectorAll("[data-sus]").forEach((b) => b.onclick = async () => { await rpc("admin_suspend_entity", { entity_pub: b.dataset.sus, reason: "admin console" }); toast("Suspended", "warn"); refreshAll(); });
  el("accounts").querySelectorAll("[data-unsus]").forEach((b) => b.onclick = async () => { await rpc("admin_unsuspend_entity", { entity_pub: b.dataset.unsus }); toast("Unsuspended"); refreshAll(); });
}

// ---- fees ----
async function loadFees() {
  const { data } = await sb.from("fee").select("type,currency_name,percentage,min,max").order("type");
  el("fees").innerHTML = (data && data.length) ? `<table><thead><tr><th>Type</th><th>Cur</th><th>%</th><th>min</th><th>max</th></tr></thead><tbody>${
    data.map((f) => `<tr><td>${f.type}</td><td>${f.currency_name}</td><td class="mono-num">${f.percentage ?? "—"}</td><td class="mono-num">${f.min ?? "—"}</td><td class="mono-num">${f.max ?? "—"}</td></tr>`).join("")}</tbody></table>`
    : `<div class="empty">No fees configured</div>`;
}
el("setFee").onclick = async () => {
  const t = el("feeType").value.trim(), c = el("feeCur").value.trim(), p = parseFloat(el("feePct").value);
  if (!t || !c || isNaN(p)) { toast("type, currency, % required", "err"); return; }
  await rpc("admin_set_fee", { fee_type: t, currency_param: c, percentage_param: p }); toast("Fee set"); loadFees(); loadAudit();
};

// ---- risk ----
async function loadRisk() {
  const { data } = await sb.from("instrument_risk").select("max_order_amount,max_order_notional,price_band_pct,enabled,instrument(name)");
  el("risk").innerHTML = (data && data.length) ? `<table><thead><tr><th>Instrument</th><th>Max amt</th><th>Max notional</th><th>Band %</th></tr></thead><tbody>${
    data.map((r) => `<tr><td>${r.instrument?.name || "—"}</td><td class="mono-num">${fmt(r.max_order_amount, 2)}</td><td class="mono-num">${fmt(r.max_order_notional, 0)}</td><td class="mono-num">${r.price_band_pct ?? "—"}</td></tr>`).join("")}</tbody></table>`
    : `<div class="empty">No risk configured</div>`;
}
el("setRisk").onclick = async () => {
  const i = el("rInst").value.trim(), a = parseFloat(el("rAmt").value), nn = parseFloat(el("rNot").value), b = parseFloat(el("rBand").value);
  if (!i) { toast("instrument required", "err"); return; }
  await rpc("admin_set_instrument_risk", { instrument_name_param: i, max_amount: a || null, max_notional: nn || null, band_pct: b || null }); toast("Risk set"); loadRisk(); loadAudit();
};

// ---- audit ----
async function loadAudit() {
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
  el("refresh").onclick = refreshDemo;
  refreshDemo();
}

async function refreshDemo() {
  let d;
  try { d = await rpc("demo_admin_overview"); } catch { return; }
  const recon = d.recon || [], appr = d.approvals || [], accts = d.accounts || [],
        fees = d.fees || [], risk = d.risk || [], audit = d.audit || [];
  const reconFails = recon.filter((r) => r.status !== "PASS").length;
  S = { entities: accts.length, suspended: accts.filter((a) => a.status === "SUSPENDED").length,
        pending: appr.length, reconFails, audit: audit.length };
  loadStats();

  el("reconBadge").textContent = reconFails ? `${reconFails} FAIL` : "ALL PASS";
  el("reconBadge").style.color = reconFails ? "var(--coral)" : "var(--phos)";
  el("reconWhen").textContent = new Date().toLocaleTimeString();
  el("recon").innerHTML = recon.map((r) => `<div class="recon-row"><span class="nm">${r.check_name.replace(/_/g, " ")}</span><span class="v ${r.status}">${r.status}${r.failures ? " · " + r.failures : ""}</span></div>`).join("") || `<div class="empty">no checks</div>`;

  el("apprCount").textContent = `${appr.length} pending`;
  el("approvals").innerHTML = appr.length ? `<table><thead><tr><th>When</th><th>Entity</th><th>Dir</th><th>Cur</th><th>Amount</th></tr></thead><tbody>${
    appr.map((r) => `<tr><td>${new Date(r.created_at).toLocaleTimeString()}</td><td>${(r.external_id || "—").slice(0, 14)}</td><td class="${r.direction === "DEPOSIT" ? "up" : "down"}">${r.direction}</td><td>${r.currency}</td><td class="mono-num">${fmt(r.amount)}</td></tr>`).join("")}</tbody></table>` : `<div class="empty">No pending wallet requests</div>`;

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
}

if (DEMO) bootDemo();
// auto-enter if key already in session (operator mode only)
else if (sessionStorage.getItem("oc_admin_svc")) enter();
