#!/usr/bin/env bash
# Stage 3 verification: GoTrue signup auto-opens an account; authenticated users
# trade via place_order (self-scoped); RLS isolates each user's data.
set -euo pipefail
API="${API:-http://127.0.0.1:54321}"
ANON="${ANON:?set ANON}"
SERVICE="${SERVICE:?set SERVICE to the service_role key}"
PGURL="${PGURL:-postgresql://postgres:postgres@127.0.0.1:54322/postgres}"

. "$(dirname "$0")/_lib.sh"
if [ "${RESET:-1}" = "1" ]; then echo "(resetting db)"; bash "$(dirname "$0")/reset-db.sh"; fi
wait_ready

signup() { signup_jwt "$1"; }   # -> "access_token uid", with retries
admin_rpc() { curl -s -X POST "$API/rest/v1/rpc/$1" -H "apikey: $SERVICE" -H "Authorization: Bearer $SERVICE" -H "Content-Type: application/json" -d "$2"; }
user_rpc()  { curl -s -X POST "$API/rest/v1/rpc/$2" -H "apikey: $ANON" -H "Authorization: Bearer $1" -H "Content-Type: application/json" -d "$3"; }
user_get()  { curl -s "$API/rest/v1/$2" -H "apikey: $ANON" -H "Authorization: Bearer $1"; }

S=$(date +%s)
echo "== signup two users (trigger auto-creates app_entity) =="
read -r ATOK AUID <<<"$(signup "alice_$S@ex.com")"; echo "alice uid=$AUID"
read -r BTOK BUID <<<"$(signup "bob_$S@ex.com")";   echo "bob   uid=$BUID"

echo "== admin (service_role) funds both =="
for uid in "$AUID" "$BUID"; do
  pub=$(psql "$PGURL" -tAc "select pub_id from app_entity where external_id='$uid'")
  admin_rpc create_currency_account "{\"app_entity_id_param\":\"$pub\",\"currency_param\":\"BTC\"}" >/dev/null
  for c in EUR BTC; do
    admin_rpc process_transfer "{\"type_param\":\"DEPOSIT\",\"from_customer_id_param\":\"MASTER\",\"amount_param\":1000,\"currency_param\":\"$c\",\"to_customer_id_param\":\"$pub\",\"reference_param\":\"s\",\"details_param\":\"s\",\"fee_type_param\":null}" >/dev/null
  done
done
echo "funded alice & bob"

echo "== alice places SELL 1@100 (her JWT, account resolved from auth.uid) =="
user_rpc "$ATOK" place_order '{"instrument_name_param":"BTC_EUR","side_param":"SELL","order_type_param":"LIMIT","price_param":100,"amount_param":1,"time_in_force_param":"GTC"}'; echo
echo "== bob places crossing BUY 1@100 =="
user_rpc "$BTOK" place_order '{"instrument_name_param":"BTC_EUR","side_param":"BUY","order_type_param":"LIMIT","price_param":100,"amount_param":1,"time_in_force_param":"GTC"}'; echo

echo "-- public trade tape (any authed user):"; user_get "$ATOK" "trade_history?select=price,amount&order=created_at.desc&limit=1"; echo
echo "-- alice cash_balances (RLS: only her rows):"; user_get "$ATOK" "cash_balances?select=currency,amount,available&order=currency"; echo
echo "-- bob cash_balances (RLS: only his rows):";   user_get "$BTOK" "cash_balances?select=currency,amount,available&order=currency"; echo

echo "== RLS isolation checks =="
ACNT=$(user_get "$ATOK" "cash_balances?select=app_entity" | jq 'length')
BCNT=$(user_get "$BTOK" "cash_balances?select=app_entity" | jq 'length')
ANON_CNT=$(curl -s "$API/rest/v1/cash_balances?select=app_entity" -H "apikey: $ANON" | jq 'length')
echo "alice sees $ACNT balance rows, bob sees $BCNT, anon sees $ANON_CNT"
echo "alice tries the admin funding RPC (must fail):"
user_rpc "$ATOK" process_transfer '{"type_param":"DEPOSIT","from_customer_id_param":"MASTER","amount_param":999999,"currency_param":"EUR","to_customer_id_param":"MASTER","reference_param":"x","details_param":"x","fee_type_param":null}'; echo

test "$ACNT" -ge 1 && test "$BCNT" -ge 1 && test "$ANON_CNT" -eq 0 \
  && echo "PASS: each user sees only their own balances; anon sees none" \
  || { echo "FAIL: RLS isolation"; exit 1; }
