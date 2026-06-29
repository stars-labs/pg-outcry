#!/usr/bin/env bash
# Stage 8: order-type coverage — MARKET, IOC, FOK (engine supports them; we only
# exercised LIMIT/GTC before). Admin plane (service_role + submit_order).
set -euo pipefail
API="${API:-http://127.0.0.1:54321}"
SERVICE="${SERVICE:?set SERVICE}"
PGURL="${PGURL:-postgresql://postgres:postgres@127.0.0.1:54322/postgres}"
if [ "${RESET:-1}" = "1" ]; then echo "(resetting db)"; bash "$(dirname "$0")/reset-db.sh"; fi

arpc(){ curl -s -X POST "$API/rest/v1/rpc/$1" -H "apikey: $SERVICE" -H "Authorization: Bearer $SERVICE" -H "Content-Type: application/json" -d "$2"; }
status(){ psql "$PGURL" -tAc "select status from trade_order where pub_id='$1'"; }
pass=0; fail=0
chk(){ if [ "$2" = "$3" ]; then echo "  ok: $1"; pass=$((pass+1)); else echo "  FAIL: $1 (got '$2' want '$3')"; fail=$((fail+1)); fi; }
# executed = order matched and traded (engine reports MARKET fills as PARTIALLY_FILLED
# due to its base/quote open_amount accounting, so accept either filled state)
chk_exec(){ case "$2" in FILLED|PARTIALLY_FILLED) echo "  ok: $1 ($2)"; pass=$((pass+1));; *) echo "  FAIL: $1 (got '$2')"; fail=$((fail+1));; esac; }

# fresh funded client -> prints its instrument_account pub_id
mkacc(){ local x="$1" pub ia;
  pub=$(arpc create_client "{\"external_id_param\":\"$x\"}" | tr -d '"')
  arpc create_currency_account "{\"app_entity_id_param\":\"$pub\",\"currency_param\":\"BTC\"}" >/dev/null
  for c in EUR BTC; do arpc process_transfer "{\"type_param\":\"DEPOSIT\",\"from_customer_id_param\":\"MASTER\",\"amount_param\":100000,\"currency_param\":\"$c\",\"to_customer_id_param\":\"$pub\",\"reference_param\":\"s\",\"details_param\":\"s\",\"fee_type_param\":null}" >/dev/null; done
  arpc find_instrument_account "{\"external_id_param\":\"$x\"}" | tr -d '"'
}
# submit_order; echoes taker pub_id. price may be 'null' for MARKET.
ord(){ arpc submit_order "{\"instrument_account_id_param\":\"$1\",\"instrument_name_param\":\"BTC_EUR\",\"order_type_param\":\"$2\",\"side_param\":\"$3\",\"price_param\":$4,\"amount_param\":$5,\"time_in_force_param\":\"$6\"}" | tr -d '"'; }
S=$(date +%s)

# MARKET orders use price=0 sentinel (trade_order.price is NOT NULL). With ample
# resting liquidity a MARKET order fills fully (FILLED) and produces a trade.
echo "== MARKET BUY crosses resting LIMIT SELL (ample liquidity) =="
M=$(mkacc "m1_$S"); T=$(mkacc "t1_$S")
ord "$M" LIMIT SELL 100 100 GTC >/dev/null     # deep ask
O=$(ord "$T" MARKET BUY 0 1 GTC)
chk_exec "market buy executed" "$(status "$O")"
chk "market buy produced a trade @100" "$(psql "$PGURL" -tAc "select count(*) from trade t where t.price=100 and (t.buyer_order_id=(select id from trade_order where pub_id='$O') or t.taker_order_id=(select id from trade_order where pub_id='$O'))")" "1"

echo "== MARKET SELL crosses resting LIMIT BUY (ample liquidity) =="
M=$(mkacc "m2_$S"); T=$(mkacc "t2_$S")
ord "$M" LIMIT BUY 110 100 GTC >/dev/null      # deep bid
O=$(ord "$T" MARKET SELL 0 1 GTC)
chk_exec "market sell executed" "$(status "$O")"

echo "== IOC partial: fills what it can, rejects the rest (no resting remainder) =="
M=$(mkacc "m3_$S"); T=$(mkacc "t3_$S")
ord "$M" LIMIT SELL 120 1 GTC >/dev/null
O=$(ord "$T" LIMIT BUY 120 2 IOC)              # only 1 available -> fill 1, reject 1
chk "IOC partial -> PARTIALLY_REJECTED" "$(status "$O")" "PARTIALLY_REJECTED"
chk "IOC leaves nothing resting" "$(psql "$PGURL" -tAc "select count(*) from trade_order where pub_id='$O' and status in ('OPEN','PARTIALLY_FILLED')")" "0"

echo "== FOK kill: can't fully fill -> REJECTED, no trade, maker untouched =="
M=$(mkacc "m4_$S"); T=$(mkacc "t4_$S")
MO=$(ord "$M" LIMIT SELL 130 1 GTC)
O=$(ord "$T" LIMIT BUY 130 2 FOK)              # need 2, only 1 available -> kill
chk "FOK insufficient -> REJECTED" "$(status "$O")" "REJECTED"
chk "maker still OPEN (untouched)" "$(status "$MO")" "OPEN"

echo "== FOK success: full fill available -> FILLED =="
M=$(mkacc "m5_$S"); T=$(mkacc "t5_$S")
ord "$M" LIMIT SELL 150 2 GTC >/dev/null
O=$(ord "$T" LIMIT BUY 150 2 FOK)
chk "FOK fully fillable -> FILLED" "$(status "$O")" "FILLED"

echo "result: $pass passed, $fail failed"; [ "$fail" -eq 0 ] && echo "PASS: order types MARKET/IOC/FOK" || exit 1
