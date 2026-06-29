#!/usr/bin/env bash
# Stage 9: stop-order placement + trigger activation (STOPLOSS, STOPLIMIT).
# A resting stop persists to stop_order; a trade on the same side with
# trade_price <= stop price activates it (STOPLOSS->MARKET, STOPLIMIT->LIMIT).
set -euo pipefail
API="${API:-http://127.0.0.1:54321}"
SERVICE="${SERVICE:?set SERVICE}"
PGURL="${PGURL:-postgresql://postgres:postgres@127.0.0.1:54322/postgres}"
if [ "${RESET:-1}" = "1" ]; then echo "(resetting db)"; bash "$(dirname "$0")/reset-db.sh"; fi

arpc(){ curl -s -X POST "$API/rest/v1/rpc/$1" -H "apikey: $SERVICE" -H "Authorization: Bearer $SERVICE" -H "Content-Type: application/json" -d "$2"; }
otype(){ psql "$PGURL" -tAc "select order_type from trade_order where pub_id='$1'"; }
stopcount(){ psql "$PGURL" -tAc "select count(*) from stop_order s join trade_order t on t.id=s.trade_order_id where t.pub_id='$1'"; }
pass=0; fail=0
chk(){ if [ "$2" = "$3" ]; then echo "  ok: $1"; pass=$((pass+1)); else echo "  FAIL: $1 (got '$2' want '$3')"; fail=$((fail+1)); fi; }
mkacc(){ local x="$1" pub;
  pub=$(arpc create_client "{\"external_id_param\":\"$x\"}" | tr -d '"')
  arpc create_currency_account "{\"app_entity_id_param\":\"$pub\",\"currency_param\":\"BTC\"}" >/dev/null
  for c in EUR BTC; do arpc process_transfer "{\"type_param\":\"DEPOSIT\",\"from_customer_id_param\":\"MASTER\",\"amount_param\":100000,\"currency_param\":\"$c\",\"to_customer_id_param\":\"$pub\",\"reference_param\":\"s\",\"details_param\":\"s\",\"fee_type_param\":null}" >/dev/null; done
  arpc find_instrument_account "{\"external_id_param\":\"$x\"}" | tr -d '"'
}
ord(){ arpc submit_order "{\"instrument_account_id_param\":\"$1\",\"instrument_name_param\":\"BTC_EUR\",\"order_type_param\":\"$2\",\"side_param\":\"$3\",\"price_param\":$4,\"amount_param\":$5,\"time_in_force_param\":\"$6\"}" | tr -d '"'; }
S=$(date +%s)
LP=$(mkacc "lp_$S"); ST=$(mkacc "st_$S"); TR=$(mkacc "tr_$S")

echo "== STOPLOSS: place (persists to stop_order), then trigger trade activates it =="
ord "$LP" LIMIT SELL 90 10 GTC >/dev/null                 # deep ask @90
SO=$(ord "$ST" STOPLOSS BUY 100 1 GTC)                    # stop BUY, trigger price 100
chk "stoploss persisted to stop_order" "$(stopcount "$SO")" "1"
chk "order_type is STOPLOSS while resting" "$(otype "$SO")" "STOPLOSS"
ord "$TR" LIMIT BUY 90 1 GTC >/dev/null                   # trade @90 (taker BUY) -> fires stops
chk "stop_order cleared after trigger" "$(stopcount "$SO")" "0"
chk "STOPLOSS activated -> MARKET" "$(otype "$SO")" "MARKET"

echo "== STOPLIMIT: activates into a resting LIMIT order =="
LP2=$(mkacc "lp2_$S"); ST2=$(mkacc "st2_$S"); TR2=$(mkacc "tr2_$S")
ord "$LP2" LIMIT SELL 80 10 GTC >/dev/null
SO2=$(ord "$ST2" STOPLIMIT BUY 95 1 GTC)
chk "stoplimit persisted" "$(stopcount "$SO2")" "1"
ord "$TR2" LIMIT BUY 80 1 GTC >/dev/null                  # trade @80 (<=95) -> fires
chk "stoplimit stop_order cleared" "$(stopcount "$SO2")" "0"
chk "STOPLIMIT activated -> LIMIT" "$(otype "$SO2")" "LIMIT"

echo "result: $pass passed, $fail failed"; [ "$fail" -eq 0 ] && echo "PASS: stop-order activation" || exit 1
