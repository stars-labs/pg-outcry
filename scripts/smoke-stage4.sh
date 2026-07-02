#!/usr/bin/env bash
# Stage 4 verification: chain-backed funding + wallet withdrawal approvals.
# - chain deposit credit -> balance credited
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

echo "== deposit: register address, chain watcher credits 500 EUR =="
STAMP="$(date +%s)"
ADDR="0xSTAGE4$STAMP"
urpc "$TOK" register_deposit_address "{\"chain_param\":\"ethereum-sepolia\",\"address_param\":\"$ADDR\"}" >/dev/null
arpc credit_chain_deposit "{\"chain_param\":\"ethereum-sepolia\",\"txid_param\":\"0xSTAGE4$STAMP\",\"log_index_param\":0,\"address_param\":\"$ADDR\",\"currency_param\":\"EUR\",\"amount_param\":500,\"confirmations_param\":20}" >/dev/null
echo "after deposit:    $(eur "$TOK")  (expect amount 500, available 500)"

echo "== legacy wallet deposit requests are disabled =="
DISABLED=$(urpc "$TOK" request_deposit '{"currency_param":"EUR","amount_param":1}')
echo "$DISABLED"

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

echo "== test-open RBAC: signed-in users can approve during demo =="
FRESH=$(urpc "$TOK" request_withdrawal '{"currency_param":"EUR","amount_param":1}' | tr -d '"')
OPEN_APPROVE=$(urpc "$TOK" approve_wallet_request "{\"request_pub_param\":\"$FRESH\"}")
echo "$OPEN_APPROVE"

FINAL=$(eur "$TOK")
OK_BAL=$(echo "$FINAL" | jq -e '(.amount|tonumber)==299 and (.amount_reserved|tonumber)==0 and (.available|tonumber)==299' >/dev/null && echo y || echo n)
OK_OPEN=$(echo "$OPEN_APPROVE" | jq -e 'type=="string" and length>0' >/dev/null && echo y || echo n)
OK_DISABLED=$(echo "$DISABLED" | jq -e '.message|test("wallet_deposit_requests_disabled")' >/dev/null && echo y || echo n)
[ "$OK_BAL" = y ] && [ "$OK_OPEN" = y ] && [ "$OK_DISABLED" = y ] \
  && echo "PASS: chain funding + wallet reservations correct; test-open admin enforced" \
  || { echo "FAIL: balance_ok=$OK_BAL open_ok=$OK_OPEN disabled_ok=$OK_DISABLED final=$FINAL approve=$OPEN_APPROVE disabled=$DISABLED"; exit 1; }
