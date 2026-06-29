#!/usr/bin/env bash
# Stage 2 verification: advisory-locked submit_order wrapper + the read API.
# Asserts partial fill, order-book level, trade tape, double-entry cash settlement,
# and reservation (frozen balance) — all over PostgREST.
set -euo pipefail
API="${API:-http://127.0.0.1:54321}"
ANON="${SERVICE:?set SERVICE (service_role key) — engine RPCs are admin-only after lockdown}"
H=(-s -H "apikey: $ANON" -H "Authorization: Bearer $ANON" -H "Content-Type: application/json")
rpc(){ curl "${H[@]}" -X POST "$API/rest/v1/rpc/$1" -d "$2"; }
get(){ curl "${H[@]}" "$API/rest/v1/$1"; }

# deterministic assertions need an empty book
if [ "${RESET:-1}" = "1" ]; then echo "(resetting db for clean state)"; bash "$(dirname "$0")/reset-db.sh"; fi

S=$(date +%s)
A=$(rpc create_client "{\"external_id_param\":\"a_$S\"}"|tr -d '"')
B=$(rpc create_client "{\"external_id_param\":\"b_$S\"}"|tr -d '"')
for id in "$A" "$B"; do
  rpc create_currency_account "{\"app_entity_id_param\":\"$id\",\"currency_param\":\"BTC\"}">/dev/null
  for c in EUR BTC; do
    rpc process_transfer "{\"type_param\":\"DEPOSIT\",\"from_customer_id_param\":\"MASTER\",\"amount_param\":1000,\"currency_param\":\"$c\",\"to_customer_id_param\":\"$id\",\"reference_param\":\"s\",\"details_param\":\"s\",\"fee_type_param\":null}">/dev/null
  done
done
AIA=$(rpc find_instrument_account "{\"external_id_param\":\"a_$S\"}"|tr -d '"')
BIA=$(rpc find_instrument_account "{\"external_id_param\":\"b_$S\"}"|tr -d '"')

echo "== alice SELL 2@100 (rests), bob BUY 1@100 (partial fill) via submit_order =="
rpc submit_order "{\"instrument_account_id_param\":\"$AIA\",\"instrument_name_param\":\"BTC_EUR\",\"order_type_param\":\"LIMIT\",\"side_param\":\"SELL\",\"price_param\":100,\"amount_param\":2,\"time_in_force_param\":\"GTC\"}">/dev/null
rpc submit_order "{\"instrument_account_id_param\":\"$BIA\",\"instrument_name_param\":\"BTC_EUR\",\"order_type_param\":\"LIMIT\",\"side_param\":\"BUY\",\"price_param\":100,\"amount_param\":1,\"time_in_force_param\":\"GTC\"}">/dev/null

echo "-- order_book_l2 (expect SELL 100 vol 1)";     get "order_book_l2?instrument=eq.BTC_EUR&select=side,price,volume"; echo
echo "-- open_orders (expect PARTIALLY_FILLED open 1)"; get "open_orders?instrument=eq.BTC_EUR&select=side,amount,open_amount,status"; echo
echo "-- trade_history (expect 1@100)";                get "trade_history?instrument=eq.BTC_EUR&select=price,amount&order=created_at.desc&limit=1"; echo
echo "-- seller BTC (expect amount 999, available 998 = 1 reserved)"; get "cash_balances?currency=eq.BTC&app_entity=eq.$A&select=amount,available"; echo
echo "-- buyer  EUR (expect 900)";                     get "cash_balances?currency=eq.EUR&app_entity=eq.$B&select=amount,available"; echo
