#!/usr/bin/env bash
# pg-outcry tuning ladder — run scripts/bench.sh at each optimization rung and
# print one markdown table row per rung, so you can see how throughput climbs
# from the baseline to the self-host ceiling on YOUR hardware.
#
# Run on a QUIET machine (no other heavy load) for meaningful deltas — durable
# settlement throughput is dominated by WAL/fsync, so a busy box produces noise
# that swamps the levers.
#
# Usage:
#   supabase db reset                 # start from a clean baseline (plpgsql banker_round)
#   SERVICE=<service_role key> ./scripts/bench-ladder.sh
#
# Rungs (additive, in order):
#   0 baseline          synchronous_commit=on  · wal_compression=off · plpgsql banker_round
#   1 + wal_compression on
#   2 + synchronous_commit=off        (the dominant lever for write-heavy settlement)
#   3 + native C banker_round         (ext/oc_fastmath; reverting needs `supabase db reset`)
# The per-symbol "aggregate" figure on every rung is the horizontal (sharding) ceiling
# at that config — a CEX has no cross-symbol transactions, so symbols run fully parallel.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SERVICE="${SERVICE:?set SERVICE (service_role key)}"
PGURL="${PGURL:-postgresql://postgres:postgres@127.0.0.1:54322/postgres}"
export SERVICE PGURL
export PAIRS="${PAIRS:-1500}" SHARDS="${SHARDS:-6}" SHARD_PAIRS="${SHARD_PAIRS:-800}"
CID="$(docker ps --format '{{.Names}}' | grep -i supabase_db | head -1)"
[ -n "$CID" ] || { echo "supabase_db container not found; run 'supabase start'"; exit 1; }

adm(){ docker exec -i "$CID" psql -U supabase_admin -d postgres -tAc "$1" >/dev/null; }
setcfg(){ adm "ALTER SYSTEM SET $1;"; adm "SELECT pg_reload_conf();"; }
rows=()

run_rung() {  # $1 = label
  local out seq agg p50
  out="$($HERE/bench.sh 2>/dev/null)"
  seq="$(printf '%s\n' "$out" | awk -F'|' '/^ *[0-9]+ \|/{gsub(/ /,"",$2);print $2; exit}')"
  p50="$(printf '%s\n' "$out" | awk -F'|' '/^ *[0-9]+ \|/{gsub(/ /,"",$4);printf "%.1f", $4/1000; exit}')"
  agg="$(printf '%s\n' "$out" | sed -n 's/.*→ \([0-9]*\) matches\/sec.*/\1/p')"
  printf '  %-46s seq=%-5s/s  p50=%-5sms  agg(%sx)=%s/s\n' "$1" "${seq:-?}" "${p50:-?}" "$SHARDS" "${agg:-?}"
  rows+=("| $1 | ${seq:-?} | ${p50:-?} | ${agg:-?} |")
}

echo "════════ pg-outcry tuning ladder (PAIRS=$PAIRS SHARDS=$SHARDS SHARD_PAIRS=$SHARD_PAIRS) ════════"
echo "host: $(nproc) vCPU · $(awk '/MemTotal/{printf "%.1f GiB", $2/1048576}' /proc/meminfo 2>/dev/null)"
echo

setcfg "synchronous_commit=on"; setcfg "wal_compression=off"
run_rung "0 · baseline (sc=on, walc=off, plpgsql)"

setcfg "wal_compression=on"
run_rung "1 · + wal_compression=on"

setcfg "synchronous_commit=off"
run_rung "2 · + synchronous_commit=off"

"$HERE/../ext/oc_fastmath/build.sh" >/dev/null 2>&1 && \
run_rung "3 · + native C banker_round" || echo "  (skipped C banker_round build)"

echo
echo "Markdown table:"
echo "| rung | seq trades/s | p50 ms | ${SHARDS}-symbol agg/s |"
echo "|---|---|---|---|"
printf '%s\n' "${rows[@]}"
echo
echo "Restore safe dev config:"
echo "  docker exec -i $CID psql -U supabase_admin -d postgres -c \"ALTER SYSTEM SET synchronous_commit=on; SELECT pg_reload_conf();\""
echo "  (revert native C banker_round with: supabase db reset)"
