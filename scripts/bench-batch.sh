#!/usr/bin/env bash
# Dimension ② — API throughput over PostgREST/HTTP (see BENCH.md).
# This does NOT measure the matching engine (that's scripts/bench.sh, dimension ①);
# it measures what a client achieves end-to-end, via the two client-side levers:
#   A) concurrency  — many parallel connections (throughput ↑ until it hits the engine ceiling)
#   B) batch size   — submit_orders: N orders per HTTP call (amortizes round-trip/auth/commit)
# A single connection sending one order at a time is a LATENCY probe, not throughput.
#
# Usage: SERVICE=<service_role key> ./scripts/bench-batch.sh [N=600] [CONC="1 4 8 16 32"] [SIZES="1 10 25 50 100"]
# Run on a QUIET box; concurrency cannot scale if other apps already use all cores.
set -euo pipefail
export API="${API:-http://127.0.0.1:54321}"
export SERVICE="${SERVICE:?set SERVICE (service_role key)}"
export N="${N:-600}"
export CONC="${CONC:-1 4 8 16 32}"
export SIZES="${SIZES:-1 10 25 50 100}"

node -e '
const API=process.env.API, KEY=process.env.SERVICE, N=+process.env.N;
const CONC=process.env.CONC.trim().split(/\s+/).map(Number), SIZES=process.env.SIZES.trim().split(/\s+/).map(Number);
const H={apikey:KEY,Authorization:`Bearer ${KEY}`,"Content-Type":"application/json"};
const rpc=(fn,b)=>fetch(`${API}/rest/v1/rpc/${fn}`,{method:"POST",headers:H,body:JSON.stringify(b)}).then(r=>r.text());
const T=Date.now();
const mk=async(n)=>{const p=JSON.parse(await rpc("create_client",{external_id_param:n}));await rpc("create_currency_account",{app_entity_id_param:p,currency_param:"BTC"});
  for(const c of["USDT","BTC"])await rpc("process_transfer",{type_param:"DEPOSIT",from_customer_id_param:"MASTER",amount_param:1e9,currency_param:c,to_customer_id_param:p,reference_param:"b",details_param:"b",fee_type_param:null});
  return JSON.parse(await rpc("find_instrument_account",{external_id_param:n}));};
const rest=async(M,n)=>{const o=Array.from({length:200},()=>({type:"LIMIT",side:"SELL",price:100,amount:1,tif:"GTC"}));for(let i=0;i<n;i+=200)await rpc("submit_orders",{instrument_account_id_param:M,instrument_name_param:"BTC_USDT",orders:o.slice(0,Math.min(200,n-i))});};
const single=(K)=>rpc("submit_order",{instrument_account_id_param:K,instrument_name_param:"BTC_USDT",order_type_param:"LIMIT",side_param:"BUY",price_param:100,amount_param:1,time_in_force_param:"GTC"});
(async()=>{
  const M=await mk("bbM_"+T), K=await mk("bbK_"+T);
  console.log(`\n②A · concurrency sweep (single orders over HTTP, N=${N})  — throughput rises with parallel clients toward the engine ceiling`);
  console.log("conc   orders/s   notes");
  for(const C of CONC){ await rest(M,N); let i=0; const t=Date.now();
    await Promise.all(Array.from({length:C},async()=>{ while(i<N){ i++; await single(K); } }));
    const ops=(N/((Date.now()-t)/1000));
    console.log(`${String(C).padStart(4)}   ${ops.toFixed(0).padStart(8)}   ${C===1?"(= latency probe, NOT throughput)":""}`);
  }
  console.log(`\n②B · batch-size sweep (1 connection, N=${N})  — amortizes round-trip/auth/commit; watch the latency/throughput knee`);
  console.log("batch   calls   orders/s   per-call ms");
  for(const B of SIZES){ await rest(M,N);
    const o=Array.from({length:B},()=>({type:"LIMIT",side:"BUY",price:100,amount:1,tif:"GTC"}));
    const calls=Math.ceil(N/B), t=Date.now();
    if(B===1){ for(let i=0;i<N;i++) await single(K); }
    else { for(let i=0;i<N;i+=B) await rpc("submit_orders",{instrument_account_id_param:K,instrument_name_param:"BTC_USDT",orders:o}); }
    const s=(Date.now()-t)/1000;
    console.log(`${String(B).padStart(5)}   ${String(calls).padStart(5)}   ${(N/s).toFixed(0).padStart(8)}   ${(s/calls*1000).toFixed(1).padStart(11)}`);
  }
  console.log("\nReminder: this is dimension ② (API). The engine ceiling is dimension ① — scripts/bench.sh.");
})();
'
