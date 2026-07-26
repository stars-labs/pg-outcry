#!/usr/bin/env bash
# Seed a lively BTC_USDT book + tape for the OUTCRY terminal demo (admin plane).
set -euo pipefail
API="${API:-http://127.0.0.1:54321}"; SERVICE="${SERVICE:?set SERVICE}"
arpc(){ curl -s -X POST "$API/rest/v1/rpc/$1" -H "apikey: $SERVICE" -H "Authorization: Bearer $SERVICE" -H "Content-Type: application/json" -d "$2"; }
mk(){ p=$(arpc create_client "{\"external_id_param\":\"$1\"}"|tr -d '"'); arpc create_currency_account "{\"app_entity_id_param\":\"$p\",\"currency_param\":\"BTC\"}">/dev/null; for c in USDT BTC; do arpc process_transfer "{\"type_param\":\"DEPOSIT\",\"from_customer_id_param\":\"MASTER\",\"amount_param\":100000000,\"currency_param\":\"$c\",\"to_customer_id_param\":\"$p\",\"reference_param\":\"d\",\"details_param\":\"d\",\"fee_type_param\":null}">/dev/null; done; arpc find_instrument_account "{\"external_id_param\":\"$1\"}"|tr -d '"'; }
ord(){ arpc submit_order "{\"instrument_account_id_param\":\"$1\",\"instrument_name_param\":\"BTC_USDT\",\"order_type_param\":\"LIMIT\",\"side_param\":\"$2\",\"price_param\":$3,\"amount_param\":$4,\"time_in_force_param\":\"GTC\"}">/dev/null; }
T=$(date +%s); MM=$(mk "mm_$T"); TK=$(mk "tk_$T")
echo "posting bid/ask ladder around 100..."
for i in 1 2 3 4 5 6 7 8; do
  ord "$MM" SELL $((100+i)) "$(awk "BEGIN{print 0.5+$i*0.3}")"
  ord "$MM" BUY  $((100-i)) "$(awk "BEGIN{print 0.5+$i*0.3}")"
done
echo "generating a few trades for the tape..."
for px in 100 101 100 99 101 102 100; do ord "$MM" SELL $px 0.2; ord "$TK" BUY $px 0.2; done
echo "done. book + tape seeded for BTC_USDT."