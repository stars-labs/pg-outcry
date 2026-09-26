#!/usr/bin/env bash
# Stage 11: purging an account funded only with unbacked (minted) money.
# The minted balance is partly traded away and partly held by a resting order; the
# purge must cancel, claw back what is left, write off what already left, and close
# the funding report. An account with a real chain deposit must be refused.
set -euo pipefail
API="${API:-http://127.0.0.1:54321}"
ANON="${ANON:?set ANON}"; SERVICE="${SERVICE:?set SERVICE}"
PGURL="${PGURL:-postgresql://postgres:postgres@127.0.0.1:54322/postgres}"
. "$(dirname "$0")/_lib.sh"
if [ "${RESET:-1}" = "1" ]; then echo "(resetting db)"; bash "$(dirname "$0")/reset-db.sh"; fi
wait_ready

arpc(){ curl -s -X POST "$API/rest/v1/rpc/$1" -H "apikey: $SERVICE" -H "Authorization: Bearer $SERVICE" -H "Content-Type: application/json" -d "$2"; }
q(){ psql "$PGURL" -X -tAc "$1"; }
pass=0; fail=0
chk(){ if [ "$2" = "$3" ]; then echo "  ok: $1"; pass=$((pass+1)); else echo "  FAIL: $1 (got '$2' want '$3')"; fail=$((fail+1)); fi; }
S=$(date +%s)
mint(){ arpc process_transfer "{\"type_param\":\"DEPOSIT\",\"from_customer_id_param\":\"MASTER\",\"amount_param\":$3,\"currency_param\":\"$2\",\"to_customer_id_param\":\"$1\",\"reference_param\":\"demo\",\"details_param\":\"faucet\",\"fee_type_param\":null}" >/dev/null; }
client(){ local pub; pub=$(arpc create_client "{\"external_id_param\":\"$1\"}" | tr -d '"')
  arpc create_currency_account "{\"app_entity_id_param\":\"$pub\",\"currency_param\":\"BTC\"}" >/dev/null; echo "$pub"; }
ord(){ arpc submit_order "{\"instrument_account_id_param\":\"$(arpc find_instrument_account "{\"external_id_param\":\"$1\"}" | tr -d '"')\",\"instrument_name_param\":\"BTC_USDT\",\"order_type_param\":\"LIMIT\",\"side_param\":\"$2\",\"price_param\":$3,\"amount_param\":$4,\"time_in_force_param\":\"GTC\"}" >/dev/null; }
report(){ arpc funding_reconciliation_report '{}' | jq -r --arg e "$1" "[.[] | select(.entity_pub_id==\$e)] | $2"; }

echo "== an account funded only by the faucet trades part of it away =="
BAD=$(client "bad_$S"); mint "$BAD" BTC 10; mint "$BAD" USDT 5000
CP=$(client "cp_$S"); mint "$CP" USDT 100000          # counterparty (unbacked too; purged below)
ord "cp_$S" BUY 100 4                                  # CP bids 4 @100
ord "bad_$S" SELL 100 4                                # BAD sells 4 BTC -> 400 USDT
ord "bad_$S" BUY 90 10                                 # resting bid reserves 900 USDT
chk "report shows BTC outstanding" "$(report "$BAD" '[.[] | select(.currency=="BTC")][0].outstanding_amount')" "10"
chk "reversal alone can't reach the traded BTC" "$(report "$BAD" '[.[] | select(.currency=="BTC")][0].available_cash | . * 1')" "6"

echo "== purge =="
R=$(arpc admin_purge_unbacked_account "{\"entity_pub_param\":\"$BAD\",\"note_param\":\"smoke\"}")
chk "resting order cancelled" "$(q "select count(*) from trade_order o join instrument_account ia on ia.id=o.instrument_account_id join app_entity e on e.id=ia.app_entity_id where e.pub_id='$BAD' and o.status in ('OPEN','PARTIALLY_FILLED')")" "0"
chk "every balance clawed back" "$(q "select count(*) from currency_account ca join app_entity e on e.id=ca.app_entity_id where e.pub_id='$BAD' and ca.amount > 0")" "0"
chk "traded-away BTC written off" "$(echo "$R" | jq -r '.written_off.BTC | . * 1')" "4"
chk "account gone from the report" "$(report "$BAD" 'length')" "0"
chk "note required" "$(arpc admin_purge_unbacked_account "{\"entity_pub_param\":\"$CP\",\"note_param\":\"\"}" | grep -c note_required)" "1"

echo "== an account with a real chain deposit is refused =="
MIX=$(client "mix_$S"); mint "$MIX" USDT 50
q "insert into watched_address(app_entity_id, chain, address) select id, 'tron-nile', 'TMIX$S' from app_entity where pub_id='$MIX'" >/dev/null
arpc credit_chain_deposit "{\"chain_param\":\"tron-nile\",\"txid_param\":\"mix$S\",\"log_index_param\":0,\"address_param\":\"TMIX$S\",\"currency_param\":\"USDT\",\"amount_param\":5,\"confirmations_param\":50}" >/dev/null
chk "mixed account refused" "$(arpc admin_purge_unbacked_account "{\"entity_pub_param\":\"$MIX\",\"note_param\":\"smoke\"}" | grep -c entity_has_backed_funding)" "1"
chk "mixed account untouched" "$(q "select trim_scale(amount) from currency_account ca join app_entity e on e.id=ca.app_entity_id where e.pub_id='$MIX' and ca.currency_name='USDT'")" "55"

echo "== ledger =="
arpc admin_purge_unbacked_account "{\"entity_pub_param\":\"$CP\",\"note_param\":\"smoke\"}" >/dev/null
chk "counterparty purged too" "$(report "$CP" 'length')" "0"
chk "reconcile all PASS" "$(arpc reconcile '{}' | jq '[.[] | select(.status != "PASS")] | length')" "0"

echo "result: $pass passed, $fail failed"; [ "$fail" -eq 0 ] && echo "PASS: unbacked account purge" || exit 1
