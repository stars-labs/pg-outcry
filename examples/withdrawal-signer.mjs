// ───────────────────────────────────────────────────────────────────────────
// EXAMPLE external EVM withdrawal signer for pg-outcry.
//
// This is the ONLY piece that lives OUTSIDE Postgres. Everything else in this
// project — order matching, the ledger, deposit watching, withdrawal approval,
// the address whitelist and rolling limits — runs as pure SQL. But signing an
// EVM transaction needs secp256k1 + keccak, which pgcrypto does not have, so a
// small outside process holds the hot key and asks the DB what to send.
//
// Trust boundary:
//   • The PRIVATE KEY lives here, in this process's env (HOT_KEY). It is NEVER
//     stored in the database.
//   • The DATABASE decides WHAT to send: it only hands out withdrawals that are
//     APPROVED, have a whitelisted+cooled to_address, and passed rolling limits,
//     and it atomically claims each one so two signers can't double-send.
//   • This signer is "dumb": it signs+broadcasts exactly what next_withdrawal_to_sign
//     returns, then reports the tx hash back. It makes no policy decisions.
//
// Run (testnet only):
//   npm i ethers           # ethers v6 — not a project dependency, not run in CI
//   SUPABASE_URL=...  SERVICE_ROLE_KEY=...  RPC_URL=https://sepolia...  \
//   HOT_KEY=0xabc...  node examples/withdrawal-signer.mjs
//
// Notes / TODO before any real use:
//   • Only handles native-coin transfers here; ERC-20 would build a contract call.
//   • `amount` is treated as whole ether for the demo; map currency→decimals/token
//     for real assets.
//   • A production signer would also poll receipts and call mark_withdrawal_confirmed
//     once a tx has enough confirmations (left as a clearly-marked stub below).
// ───────────────────────────────────────────────────────────────────────────
import { JsonRpcProvider, Wallet, parseEther } from "ethers"; // npm i ethers

const { SUPABASE_URL, SERVICE_ROLE_KEY, RPC_URL, HOT_KEY } = process.env;
for (const [k, v] of Object.entries({ SUPABASE_URL, SERVICE_ROLE_KEY, RPC_URL, HOT_KEY }))
  if (!v) { console.error(`missing env ${k}`); process.exit(2); }

const POLL_MS = Number(process.env.POLL_MS ?? 5000);

// Thin PostgREST RPC helper using the service-role key (the operator plane).
async function rpc(fn, body) {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${fn}`, {
    method: "POST",
    headers: {
      apikey: SERVICE_ROLE_KEY,
      Authorization: `Bearer ${SERVICE_ROLE_KEY}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(body ?? {}),
  });
  if (!res.ok) throw new Error(`${fn} -> ${res.status} ${await res.text()}`);
  const text = await res.text();
  return text ? JSON.parse(text) : null;
}

const provider = new JsonRpcProvider(RPC_URL);
const wallet = new Wallet(HOT_KEY, provider);

async function handleOne() {
  // Atomically claim the next approved+whitelisted withdrawal. Returns null when
  // the queue is empty; the DB has already marked this row as claimed for us.
  const w = await rpc("next_withdrawal_to_sign");
  if (!w) return false;

  console.log(`signing ${w.pub_id}: ${w.amount} ${w.currency} -> ${w.to_address}`);

  // Build + sign + broadcast. The hot key never leaves this process.
  const tx = await wallet.sendTransaction({
    to: w.to_address,
    value: parseEther(String(w.amount)), // demo: treat amount as whole ether
  });
  console.log(`broadcast ${w.pub_id} as ${tx.hash}`);

  // Tell the DB it's on-chain (idempotent: safe to retry).
  await rpc("mark_withdrawal_broadcast", { request_pub: w.pub_id, txid: tx.hash });

  // OPTIONAL production step: wait for confirmations, then:
  //   await tx.wait(3);
  //   await rpc("mark_withdrawal_confirmed", { request_pub: w.pub_id });
  return true;
}

console.log(`signer up as ${wallet.address}; polling every ${POLL_MS}ms`);
for (;;) {
  try {
    // Drain the queue, then sleep. Each handleOne claims exactly one row.
    while (await handleOne()) { /* keep draining */ }
  } catch (e) {
    console.error("signer error:", e.message); // never crash the loop on one bad tx
  }
  await new Promise((r) => setTimeout(r, POLL_MS));
}
