#!/usr/bin/env bash
# Stage 7: wallet idempotency keys + reconciliation report + append-only ledger.
set -euo pipefail
API="${API:-http://127.0.0.1:54321}"
ANON="${ANON:?set ANON}"; SERVICE="${SERVICE:?set SERVICE}"
PGURL="${PGURL:-postgresql://postgres:postgres@127.0.0.1:54322/postgres}"
. "$(dirname "$0")/_lib.sh"
if [ "${RESET:-1}" = "1" ]; then echo "(resetting db)"; bash "$(dirname "$0")/reset-db.sh"; fi
wait_ready

signup(){ signup_jwt "$1" | cut -d" " -f1; }
urpc(){ curl -s -X POST "$API/rest/v1/rpc/$2" -H "apikey: $ANON" -H "Authorization: Bearer $1" -H "Content-Type: application/json" -d "$3"; }
arpc(){ curl -s -X POST "$API/rest/v1/rpc/$1" -H "apikey: $SERVICE" -H "Authorization: Bearer $SERVICE" -H "Content-Type: application/json" -d "$2"; }
pass=0; fail=0
chk(){ if [ "$2" = "$3" ]; then echo "  ok: $1"; pass=$((pass+1)); else echo "  FAIL: $1 (got '$2' want '$3')"; fail=$((fail+1)); fi; }

TOK=$(signup "idem_$(date +%s)@ex.com")
APUB=$(psql "$PGURL" -tAc "select ae.pub_id from app_entity ae join app_user au on au.app_entity_id=ae.id order by au.created_at desc limit 1")
EID=$(psql "$PGURL" -tAc "select id from app_entity where pub_id='$APUB'")

echo "== deposit idempotency: same key twice -> one request, one credit =="
arpc admin_unsuspend_entity "{\"entity_pub\":\"$APUB\"}" >/dev/null 2>&1 || true
D1=$(urpc "$TOK" request_deposit '{"currency_param":"EUR","amount_param":500,"idempotency_key_param":"dep-001"}' | tr -d '"')
D2=$(urpc "$TOK" request_deposit '{"currency_param":"EUR","amount_param":500,"idempotency_key_param":"dep-001"}' | tr -d '"')
chk "same pub_id returned" "$D1" "$D2"
chk "only one wallet_request row for key" "$(psql "$PGURL" -tAc "select count(*) from wallet_request where idempotency_key='dep-001' and app_entity_id=$EID")" "1"
arpc approve_wallet_request "{\"request_pub_param\":\"$D1\"}" >/dev/null
chk "credited once (EUR amount=500)" "$(psql "$PGURL" -tAc "select amount from currency_account where app_entity_id=$EID and currency_name='EUR'")" "500.00"

echo "== withdrawal idempotency: same key twice -> reserved once =="
W1=$(urpc "$TOK" request_withdrawal '{"currency_param":"EUR","amount_param":200,"idempotency_key_param":"wd-001"}' | tr -d '"')
W2=$(urpc "$TOK" request_withdrawal '{"currency_param":"EUR","amount_param":200,"idempotency_key_param":"wd-001"}' | tr -d '"')
chk "same withdrawal pub_id" "$W1" "$W2"
chk "reserved only once (=200)" "$(psql "$PGURL" -tAc "select amount_reserved from currency_account where app_entity_id=$EID and currency_name='EUR'")" "200.00"

echo "== append-only ledger: UPDATE/DELETE rejected =="
UPD=$(psql "$PGURL" -tAc "update transfer_ledger_entry set amount=amount+1 where id=(select id from transfer_ledger_entry limit 1)" 2>&1 || true)
chk "ledger UPDATE blocked" "$(echo "$UPD" | grep -c append_only_ledger)" "1"

echo "== reconciliation report (all invariants PASS) =="
REC=$(curl -s "$API/rest/v1/reconciliation_report?select=check_name,failures,status" -H "apikey: $SERVICE" -H "Authorization: Bearer $SERVICE")
echo "$REC" | jq -c '.[]'
chk "no failing checks" "$(echo "$REC" | jq '[.[]|select(.status!="PASS")]|length')" "0"
chk "five invariants reported" "$(echo "$REC" | jq 'length')" "5"

echo "result: $pass passed, $fail failed"; [ "$fail" -eq 0 ] && echo "PASS: idempotency + reconciliation + append-only" || exit 1
