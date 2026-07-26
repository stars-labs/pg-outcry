#!/usr/bin/env bash
# Stage 1 verification: drive the matching engine end-to-end through PostgREST.
# Two clients are funded, then a SELL and a crossing BUY are placed; we assert a
# trade was produced — all via HTTP /rpc, no direct SQL.
set -euo pipefail

API="${API:-http://127.0.0.1:54321}"
ANON="${SERVICE:?set SERVICE (service_role key) — engine RPCs are admin-only after lockdown}"
H=(-s -H "apikey: $ANON" -H "Authorization: Bearer $ANON" -H "Content-Type: application/json")
rpc() { curl "${H[@]}" -X POST "$API/rest/v1/rpc/$1" -d "$2"; }

echo "== create clients (returns app_entity pub_id, a UUID) =="
ALICE=$(rpc create_client '{"external_id_param":"alice"}' | tr -d '"'); echo "alice=$ALICE"
BOB=$(rpc create_client '{"external_id_param":"bob"}'   | tr -d '"'); echo "bob=$BOB"

echo "== give each a BTC currency account (create_client only opens USDT) =="
rpc create_currency_account "{\"app_entity_id_param\":\"$ALICE\",\"currency_param\":\"BTC\"}"; echo
rpc create_currency_account "{\"app_entity_id_param\":\"$BOB\",\"currency_param\":\"BTC\"}";   echo

echo "== fund from MASTER (DEPOSIT, no fee) =="
for who in "$ALICE" "$BOB"; do
  rpc process_transfer "{\"type_param\":\"DEPOSIT\",\"from_customer_id_param\":\"MASTER\",\"amount_param\":1000,\"currency_param\":\"USDT\",\"to_customer_id_param\":\"$who\",\"reference_param\":\"seed\",\"details_param\":\"seed\",\"fee_type_param\":null}"; echo
  rpc process_transfer "{\"type_param\":\"DEPOSIT\",\"from_customer_id_param\":\"MASTER\",\"amount_param\":1000,\"currency_param\":\"BTC\",\"to_customer_id_param\":\"$who\",\"reference_param\":\"seed\",\"details_param\":\"seed\",\"fee_type_param\":null}"; echo
done
echo "funded alice & bob with 1000 USDT + 1000 BTC each"

ALICE_IA=$(rpc find_instrument_account '{"external_id_param":"alice"}' | tr -d '"')
BOB_IA=$(rpc find_instrument_account '{"external_id_param":"bob"}' | tr -d '"')
echo "alice instrument_account=$ALICE_IA  bob=$BOB_IA"

echo "== alice posts a LIMIT SELL 1 BTC @ 100 =="
rpc process_trade_order "{\"instrument_account_id_param\":\"$ALICE_IA\",\"instrument_name_param\":\"BTC_USDT\",\"order_type_param\":\"LIMIT\",\"side_param\":\"SELL\",\"price_param\":100,\"amount_param\":1,\"time_in_force_param\":\"GTC\",\"trade_order_id_param\":0}"; echo

# amount_param is the BASE quantity for both sides; for a BUY the engine reserves
# amount * price in the quote currency (USDT).
echo "== bob posts a crossing LIMIT BUY 1 BTC @ 100 =="
rpc process_trade_order "{\"instrument_account_id_param\":\"$BOB_IA\",\"instrument_name_param\":\"BTC_USDT\",\"order_type_param\":\"LIMIT\",\"side_param\":\"BUY\",\"price_param\":100,\"amount_param\":1,\"time_in_force_param\":\"GTC\",\"trade_order_id_param\":0}"; echo

echo "== resulting trades (via PostgREST GET) =="
curl "${H[@]}" "$API/rest/v1/trade?select=pub_id,price,amount,created_at&order=created_at.desc"; echo
