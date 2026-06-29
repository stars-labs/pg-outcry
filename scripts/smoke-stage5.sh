#!/usr/bin/env bash
# Stage 2/3 extras: pre-trade risk controls + back-office admin (suspend, fees, risk, audit).
set -euo pipefail
API="${API:-http://127.0.0.1:54321}"
ANON="${ANON:?set ANON}"; SERVICE="${SERVICE:?set SERVICE}"
PGURL="${PGURL:-postgresql://postgres:postgres@127.0.0.1:54322/postgres}"
. "$(dirname "$0")/_lib.sh"
if [ "${RESET:-1}" = "1" ]; then echo "(resetting db)"; bash "$(dirname "$0")/reset-db.sh"; fi
wait_ready

signup(){ signup_jwt "$1"; }
urpc(){ curl -s -X POST "$API/rest/v1/rpc/$2" -H "apikey: $ANON" -H "Authorization: Bearer $1" -H "Content-Type: application/json" -d "$3"; }
arpc(){ curl -s -X POST "$API/rest/v1/rpc/$1" -H "apikey: $SERVICE" -H "Authorization: Bearer $SERVICE" -H "Content-Type: application/json" -d "$2"; }
msg(){ echo "$1" | jq -r '.message // .code // .'; }
ord(){ urpc "$1" place_order "{\"instrument_name_param\":\"BTC_EUR\",\"side_param\":\"$2\",\"order_type_param\":\"LIMIT\",\"price_param\":$3,\"amount_param\":$4,\"time_in_force_param\":\"GTC\"}"; }

S=$(date +%s); pass=0; fail=0
chk(){ if [ "$2" = "$3" ]; then echo "  ok: $1"; pass=$((pass+1)); else echo "  FAIL: $1 (got '$2' want '$3')"; fail=$((fail+1)); fi; }

read -r AT AU <<<"$(signup "ra_$S@ex.com")"
read -r BT BU <<<"$(signup "rb_$S@ex.com")"
for uid in "$AU" "$BU"; do
  pub=$(psql "$PGURL" -tAc "select pub_id from app_entity where external_id='$uid'")
  arpc create_currency_account "{\"app_entity_id_param\":\"$pub\",\"currency_param\":\"BTC\"}" >/dev/null
  for c in EUR BTC; do arpc process_transfer "{\"type_param\":\"DEPOSIT\",\"from_customer_id_param\":\"MASTER\",\"amount_param\":1000,\"currency_param\":\"$c\",\"to_customer_id_param\":\"$pub\",\"reference_param\":\"s\",\"details_param\":\"s\",\"fee_type_param\":null}" >/dev/null; done
done

echo "== establish reference price (trade @100) =="
ord "$AT" SELL 100 1 >/dev/null
ord "$BT" BUY  100 1 >/dev/null
echo "  last trade: $(curl -s "$API/rest/v1/trade_history?select=price&order=created_at.desc&limit=1" -H "apikey: $SERVICE" | jq -c .)"

echo "== risk controls (seed: band 10%, max amount 100) =="
chk "price 150 rejected by band"      "$(msg "$(ord "$AT" SELL 150 1)")"   "risk_price_band: 150 beyond 10 pct band of last 100.00"
chk "amount 1000 rejected by max amt" "$(msg "$(ord "$AT" SELL 100 1000)")" "risk_max_order_amount: 1000 > 100"

echo "== admin widens band -> 150 now allowed =="
arpc admin_set_instrument_risk '{"instrument_name_param":"BTC_EUR","max_amount":100,"max_notional":100000,"band_pct":60}' >/dev/null
R=$(ord "$AT" SELL 150 1); chk "price 150 accepted after widen" "$([ "${#R}" -ge 30 ] && echo ok || msg "$R")" "ok"

echo "== suspend / unsuspend =="
APUB=$(psql "$PGURL" -tAc "select pub_id from app_entity where external_id='$AU'")
arpc admin_suspend_entity "{\"entity_pub\":\"$APUB\",\"reason\":\"kyc\"}" >/dev/null
chk "suspended user cannot trade" "$(msg "$(ord "$AT" BUY 100 1)")" "account_suspended"
arpc admin_unsuspend_entity "{\"entity_pub\":\"$APUB\"}" >/dev/null
R=$(ord "$AT" BUY 100 1); chk "unsuspended user can trade" "$([ "${#R}" -ge 30 ] && echo ok || msg "$R")" "ok"

echo "== fee management + audit log =="
arpc admin_set_fee '{"fee_type":"TAKER_FEE","currency_param":"EUR","percentage_param":0.1}' >/dev/null
chk "fee row persisted" "$(psql "$PGURL" -tAc "select percentage from fee where type='TAKER_FEE' and currency_name='EUR'")" "0.1"
chk "audit log has 4 admin actions" "$(psql "$PGURL" -tAc "select count(*) from admin_audit_log")" "4"

echo "== a normal user cannot call admin RPC =="
chk "admin RPC denied for user" "$(urpc "$AT" admin_suspend_entity "{\"entity_pub\":\"$APUB\"}" | jq -r .code)" "42501"

echo "result: $pass passed, $fail failed"; [ "$fail" -eq 0 ] && echo "PASS: risk + back-office" || exit 1
