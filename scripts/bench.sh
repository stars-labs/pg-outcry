#!/usr/bin/env bash
# pg-outcry benchmark — throughput, engine latency percentiles, per-symbol concurrency scaling.
# Measures the matching+settlement hot path (the real work: double-entry across the ledger).
# Usage: SERVICE=<service_role key> ./scripts/bench.sh   [PAIRS=2000] [SHARDS=6] [SHARD_PAIRS=1500]
set -euo pipefail
API="${API:-http://127.0.0.1:54321}"
SERVICE="${SERVICE:?set SERVICE (service_role key)}"
PGURL="${PGURL:-postgresql://postgres:postgres@127.0.0.1:54322/postgres}"
PAIRS="${PAIRS:-2000}"; SHARDS="${SHARDS:-6}"; SHARD_PAIRS="${SHARD_PAIRS:-1500}"
arpc(){ curl -s -X POST "$API/rest/v1/rpc/$1" -H "apikey: $SERVICE" -H "Authorization: Bearer $SERVICE" -H "Content-Type: application/json" -d "$2"; }
psqlq(){ psql "$PGURL" -tAqc "$1"; }

echo "════════════════════════════════════════════════════════════"
echo " pg-outcry benchmark"
echo "════════════════════════════════════════════════════════════"
echo "host : $(nproc) vCPU · $(awk '/MemTotal/{printf "%.1f GiB RAM", $2/1048576}' /proc/meminfo 2>/dev/null)"
echo "pg   : $(psqlq 'show server_version')"
echo "cfg  : shared_buffers=$(psqlq 'show shared_buffers') synchronous_commit=$(psqlq 'show synchronous_commit') wal_compression=$(psqlq 'show wal_compression')"
echo "engine banker_round: $(psqlq "select l.lanname from pg_proc p join pg_language l on l.oid=p.prolang where proname='banker_round'")"
echo

# ---- funded maker/taker on BTC_EUR ----
mk(){ p=$(arpc create_client "{\"external_id_param\":\"$1\"}"|tr -d '"'); arpc create_currency_account "{\"app_entity_id_param\":\"$p\",\"currency_param\":\"BTC\"}">/dev/null
  for c in EUR BTC; do arpc process_transfer "{\"type_param\":\"DEPOSIT\",\"from_customer_id_param\":\"MASTER\",\"amount_param\":1000000000,\"currency_param\":\"$c\",\"to_customer_id_param\":\"$p\",\"reference_param\":\"b\",\"details_param\":\"b\",\"fee_type_param\":null}">/dev/null; done
  arpc find_instrument_account "{\"external_id_param\":\"$1\"}"|tr -d '"'; }
T=$(date +%s); M=$(mk "bM_$T"); K=$(mk "bK_$T")

echo "── 1) sequential throughput + engine latency (BTC_EUR, $PAIRS matched pairs) ──"
psql "$PGURL" -qX <<SQL
CREATE TEMP TABLE _lat(us double precision);
DO \$\$
DECLARE i int; t0 timestamptz;
BEGIN
  FOR i IN 1..$PAIRS LOOP
    PERFORM submit_order('$M','BTC_EUR','LIMIT','SELL',100,1,'GTC');   -- resting maker (untimed)
    t0 := clock_timestamp();
    PERFORM submit_order('$K','BTC_EUR','LIMIT','BUY',100,1,'GTC');    -- taker: match + double-entry settle
    INSERT INTO _lat VALUES (extract(epoch FROM clock_timestamp()-t0)*1e6);
  END LOOP;
END\$\$;
SELECT
  count(*)                                                   AS matches,
  round((count(*)/ (sum(us)/1e6))::numeric, 0)              AS "matches_per_sec(engine)",
  round(avg(us)::numeric,1)                                  AS "avg_us",
  round((percentile_cont(0.5)  WITHIN GROUP (ORDER BY us))::numeric,1) AS "p50_us",
  round((percentile_cont(0.95) WITHIN GROUP (ORDER BY us))::numeric,1) AS "p95_us",
  round((percentile_cont(0.99) WITHIN GROUP (ORDER BY us))::numeric,1) AS "p99_us"
FROM _lat;
SQL

echo
echo "── 2) end-to-end latency over PostgREST/HTTP (100 orders) ──"
M="$M" API="$API" SERVICE="$SERVICE" node -e '
  const API=process.env.API, KEY=process.env.SERVICE, IA=process.env.M;
  const t=[]; const body=JSON.stringify({instrument_account_id_param:IA,instrument_name_param:"BTC_EUR",order_type_param:"LIMIT",side_param:"SELL",price_param:50,amount_param:1,time_in_force_param:"GTC"});
  (async()=>{ for(let i=0;i<100;i++){ const s=performance.now();
      await fetch(`${API}/rest/v1/rpc/submit_order`,{method:"POST",headers:{apikey:KEY,Authorization:`Bearer ${KEY}`,"Content-Type":"application/json"},body}).then(r=>r.text());
      t.push(performance.now()-s); }
    t.sort((a,b)=>a-b); const q=p=>t[Math.floor(p*t.length)].toFixed(2);
    console.log(`  HTTP round-trip ms — p50 ${q(.5)} · p95 ${q(.95)} · p99 ${q(.99)} · avg ${(t.reduce((a,b)=>a+b)/t.length).toFixed(2)}`);
  })();
' 2>/dev/null || echo "  (node fetch unavailable — skipped)"

echo
echo "── 3) per-symbol concurrency scaling ($SHARDS symbols × $SHARD_PAIRS pairs, parallel) ──"
# create N independent FX instruments + funded maker/taker each
for n in $(seq 0 $((SHARDS-1))); do
  cur="Q${T}_$n"; inst="${cur}_EUR"
  psqlq "insert into currency(name,precision) values ('$cur',5) on conflict do nothing" >/dev/null
  arpc create_currency_account "{\"app_entity_id_param\":\"MASTER\",\"currency_param\":\"$cur\"}">/dev/null 2>&1 || true
  psqlq "insert into instrument(name,base_currency,quote_currency,fx_instrument) values ('$inst','$cur','EUR',true) on conflict do nothing" >/dev/null
  mm=$(arpc create_client "{\"external_id_param\":\"m${n}_$T\"}"|tr -d '"'); tk=$(arpc create_client "{\"external_id_param\":\"t${n}_$T\"}"|tr -d '"')
  for who in "$mm" "$tk"; do arpc create_currency_account "{\"app_entity_id_param\":\"$who\",\"currency_param\":\"$cur\"}">/dev/null
    for c in EUR "$cur"; do arpc process_transfer "{\"type_param\":\"DEPOSIT\",\"from_customer_id_param\":\"MASTER\",\"amount_param\":1000000000,\"currency_param\":\"$c\",\"to_customer_id_param\":\"$who\",\"reference_param\":\"b\",\"details_param\":\"b\",\"fee_type_param\":null}">/dev/null; done; done
  echo "$(arpc find_instrument_account "{\"external_id_param\":\"m${n}_$T\"}"|tr -d '"') $(arpc find_instrument_account "{\"external_id_param\":\"t${n}_$T\"}"|tr -d '"') $inst" >> /tmp/bench_shards
done
run_shard(){ read -r mia tia inst <<<"$1"; psql "$PGURL" -qXc "DO \$\$ BEGIN FOR i IN 1..$SHARD_PAIRS LOOP PERFORM submit_order('$mia','$inst','LIMIT','SELL',100,1,'GTC'); PERFORM submit_order('$tia','$inst','LIMIT','BUY',100,1,'GTC'); END LOOP; END\$\$"; }
start=$(date +%s.%N)
while read -r line; do run_shard "$line" & done < /tmp/bench_shards
wait
end=$(date +%s.%N)
elapsed=$(awk "BEGIN{print $end-$start}")
total=$((SHARDS*SHARD_PAIRS))
echo "  $SHARDS symbols in parallel: $total matches in ${elapsed}s → $(awk "BEGIN{printf \"%.0f\", $total/$elapsed}") matches/sec (aggregate)"
rm -f /tmp/bench_shards
echo
echo "Note: ms-scale, durable, single-node figures — not µs HFT. Reproduce: scripts/bench.sh"
