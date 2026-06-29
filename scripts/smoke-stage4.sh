#!/usr/bin/env bash
# Stage 4 verification: internal-ledger wallet with admin approval.
# - deposit request -> admin approve -> balance credited
# - withdrawal request -> funds reserved -> admin approve -> balance debited
# - withdrawal request -> admin reject -> reservation released
set -euo pipefail
API="${API:-http://127.0.0.1:54321}"
ANON="${ANON:?set ANON}"; SERVICE="${SERVICE:?set SERVICE}"
. "$(dirname "$0")/_lib.sh"
if [ "${RESET:-1}" = "1" ]; then echo "(resetting db)"; bash "$(dirname "$0")/reset-db.sh"; fi
wait_ready

signup(){ signup_jwt "$1" | cut -d" " -f1; }
urpc(){ curl -s -X POST "$API/rest/v1/rpc/$2" -H "apikey: $ANON" -H "Authorization: Bearer $1" -H "Content-Type: application/json" -d "$3"; }
uget(){ curl -s "$API/rest/v1/$2" -H "apikey: $ANON" -H "Authorization: Bearer $1"; }
arpc(){ curl -s -X POST "$API/rest/v1/rpc/$1" -H "apikey: $SERVICE" -H "Authorization: Bearer $SERVICE" -H "Content-Type: application/json" -d "$2"; }
eur(){ uget "$1" "cash_balances?currency=eq.EUR&select=amount,amount_reserved,available" | jq -c '.[0]'; }

TOK=$(signup "w_$(date +%s)@ex.com")
echo "initial EUR: $(eur "$TOK")  (new account, expect zeros)"

echo "== deposit: request 500 EUR, admin approves =="
DREQ=$(urpc "$TOK" request_deposit '{"currency_param":"EUR","amount_param":500}' | tr -d '"')
arpc approve_wallet_request "{\"request_pub_param\":\"$DREQ\"}" >/dev/null
echo "after deposit:    $(eur "$TOK")  (expect amount 500, available 500)"

echo "== withdrawal: request 200 EUR (reserves), admin approves (debits) =="
WREQ=$(urpc "$TOK" request_withdrawal '{"currency_param":"EUR","amount_param":200}' | tr -d '"')
echo "after request:    $(eur "$TOK")  (expect amount 500, reserved 200, available 300)"
arpc approve_wallet_request "{\"request_pub_param\":\"$WREQ\"}" >/dev/null
echo "after approve:    $(eur "$TOK")  (expect amount 300, reserved 0, available 300)"

echo "== withdrawal reject releases the reservation =="
RREQ=$(urpc "$TOK" request_withdrawal '{"currency_param":"EUR","amount_param":100}' | tr -d '"')
echo "after request:    $(eur "$TOK")  (expect amount 300, reserved 100, available 200)"
arpc reject_wallet_request "{\"request_pub_param\":\"$RREQ\"}" >/dev/null
echo "after reject:     $(eur "$TOK")  (expect amount 300, reserved 0, available 300)"

echo "== user sees own wallet history (RLS) =="
uget "$TOK" "wallet_request?select=direction,currency,amount,status&order=created_at" ; echo

echo "== a normal user cannot approve (admin-only); test on a FRESH pending request =="
FRESH=$(urpc "$TOK" request_deposit '{"currency_param":"EUR","amount_param":1}' | tr -d '"')
DENY=$(urpc "$TOK" approve_wallet_request "{\"request_pub_param\":\"$FRESH\"}")
echo "$DENY"
arpc reject_wallet_request "{\"request_pub_param\":\"$FRESH\"}" >/dev/null  # clean up

FINAL=$(eur "$TOK")
OK_BAL=$(echo "$FINAL" | jq -e '(.amount|tonumber)==300 and (.amount_reserved|tonumber)==0 and (.available|tonumber)==300' >/dev/null && echo y || echo n)
OK_DENY=$(echo "$DENY" | jq -e '.code=="42501"' >/dev/null && echo y || echo n)
[ "$OK_BAL" = y ] && [ "$OK_DENY" = y ] \
  && echo "PASS: wallet ledger + reservations correct; admin-only enforced" \
  || { echo "FAIL: balance_ok=$OK_BAL deny_ok=$OK_DENY final=$FINAL deny=$DENY"; exit 1; }
