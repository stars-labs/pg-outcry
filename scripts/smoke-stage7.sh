#!/usr/bin/env bash
# Stage 7: chain deposit idempotency + wallet idempotency + reconciliation reports + append-only ledger.
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

echo "== chain deposit idempotency: same tx twice -> one credit =="
arpc admin_unsuspend_entity "{\"entity_pub\":\"$APUB\"}" >/dev/null 2>&1 || true
STAMP="$(date +%s)"
ADDR="0xIDEM$STAMP"
TXID="0xIDEM$STAMP"
urpc "$TOK" register_deposit_address "{\"chain_param\":\"ethereum-sepolia\",\"address_param\":\"$ADDR\"}" >/dev/null
C1=$(arpc credit_chain_deposit "{\"chain_param\":\"ethereum-sepolia\",\"txid_param\":\"$TXID\",\"log_index_param\":0,\"address_param\":\"$ADDR\",\"currency_param\":\"EUR\",\"amount_param\":500,\"confirmations_param\":20}" | tr -d '"')
C2=$(arpc credit_chain_deposit "{\"chain_param\":\"ethereum-sepolia\",\"txid_param\":\"$TXID\",\"log_index_param\":0,\"address_param\":\"$ADDR\",\"currency_param\":\"EUR\",\"amount_param\":500,\"confirmations_param\":30}" | tr -d '"')
chk "first credit succeeds" "$C1" "credited"
chk "duplicate tx is ignored" "$C2" "duplicate"
chk "only one chain_deposit row for tx" "$(psql "$PGURL" -tAc "select count(*) from chain_deposit where txid='$TXID' and address='$ADDR'")" "1"
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

echo "== custody funding reconciliation (no unbacked exposure) =="
CUST=$(curl -s "$API/rest/v1/custody_reconciliation_report?select=check_name,failures,status" -H "apikey: $SERVICE" -H "Authorization: Bearer $SERVICE")
echo "$CUST" | jq -c '.[]'
chk "custody checks pass" "$(echo "$CUST" | jq '[.[]|select(.status!="PASS")]|length')" "0"
EXPO=$(curl -s "$API/rest/v1/custody_funding_exposure?select=entity_pub_id" -H "apikey: $SERVICE" -H "Authorization: Bearer $SERVICE")
chk "no unbacked funding exposure" "$(echo "$EXPO" | jq 'length')" "0"

echo "result: $pass passed, $fail failed"; [ "$fail" -eq 0 ] && echo "PASS: idempotency + reconciliation + append-only" || exit 1
