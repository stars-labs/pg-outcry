#!/usr/bin/env bash
# Stage 12: withdrawal signers under pg_cron conditions (no JWT), against a fake
# chain API container on the Supabase network (scripts/fake-chain-api.py).
# - BTC: deposit -> whitelist -> request -> approve -> sign -> broadcast -> confirm;
#   a second request can't reuse the spent UTXO; the queues don't cross.
# - EVM: one approved withdrawal is broadcast exactly once across two driver runs
#   (it used to be re-signed and re-paid every run).
set -euo pipefail
API="${API:-http://127.0.0.1:54321}"
ANON="${ANON:?set ANON}"; SERVICE="${SERVICE:?set SERVICE}"
PGURL="${PGURL:-postgresql://postgres:postgres@127.0.0.1:54322/postgres}"
NET="${SUPABASE_NETWORK:-supabase_network_pg-outcry}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/_lib.sh"
if [ "${RESET:-1}" = "1" ]; then echo "(resetting db)"; bash "$ROOT/scripts/reset-db.sh"; fi
wait_ready

STATE="$(mktemp -d)"; chmod 777 "$STATE"
docker rm -f fake-chain-api >/dev/null 2>&1 || true
docker run -d --name fake-chain-api --network "$NET" -e STATE_DIR=/state \
  -v "$STATE:/state" -v "$ROOT/scripts/fake-chain-api.py:/app.py:ro" python:3.12-alpine python /app.py >/dev/null
trap 'docker rm -f fake-chain-api >/dev/null 2>&1 || true; rm -rf "$STATE"' EXIT

q(){ psql "$PGURL" -X -tAc "$1"; }
urpc(){ curl -s -X POST "$API/rest/v1/rpc/$2" -H "apikey: $ANON" -H "Authorization: Bearer $1" -H "Content-Type: application/json" -d "$3"; }
arpc(){ curl -s -X POST "$API/rest/v1/rpc/$1" -H "apikey: $SERVICE" -H "Authorization: Bearer $SERVICE" -H "Content-Type: application/json" -d "$2"; }
pass=0; fail=0
chk(){ if [ "$2" = "$3" ]; then echo "  ok: $1"; pass=$((pass+1)); else echo "  FAIL: $1 (got '$2' want '$3')"; fail=$((fail+1)); fi; }
for i in $(seq 1 30); do [ "$(q "select status from extensions.http_get('http://fake-chain-api:18999/fee-estimates')" 2>/dev/null)" = "200" ] && break; sleep 1; done
S=$(date +%s)
q "update chain set enabled=true, rpc_url='http://fake-chain-api:18999' where name='bitcoin-testnet4'" >/dev/null
q "update chain set enabled=true, rpc_url='http://fake-chain-api:18999/evm' where name='ethereum-sepolia'" >/dev/null
whitelist(){ urpc "$1" add_withdrawal_address "{\"currency_param\":\"$2\",\"address_param\":\"$3\"}" >/dev/null
  q "update withdrawal_address set active_at = now() - interval '1 minute' where address='$3'" >/dev/null; }   # skip cooling

echo "== the migration scheduled the BTC jobs =="
chk "sign/broadcast/confirm jobs exist" "$(q "select count(*) from cron.job where jobname in ('sign-bitcoin-withdrawals','broadcast-bitcoin-withdrawals','confirm-bitcoin-withdrawals')")" "3"

echo "== BTC: deposit is credited =="
TOK=$(signup_jwt "btcw_$S@ex.com" | cut -d" " -f1)
ADDR=$(urpc "$TOK" my_deposit_address '{"chain_param":"bitcoin-testnet4"}' | jq -r .address)
DEPTX=$(openssl rand -hex 32)
echo "{\"deposits\": {\"$ADDR\": [[\"$DEPTX\", 1, 50000000]]}}" > "$STATE/state.json"
q "select poll_bitcoin('bitcoin-testnet4')" >/dev/null
chk "0.5 BTC credited" "$(q "select trim_scale(ca.amount) from currency_account ca join watched_address w on w.app_entity_id=ca.app_entity_id where w.address='$ADDR' and ca.currency_name='BTC'")" "0.5"

echo "== BTC: withdraw 0.1 through the cron jobs =="
DEST=tb1pznce58a6gthaq3w82klch3pv4ltff5vvwn7f7h2leqcjgry0dgjs52kj6j
whitelist "$TOK" BTC "$DEST"
R1=$(urpc "$TOK" request_withdrawal_to "{\"currency_param\":\"BTC\",\"amount_param\":0.1,\"to_address_param\":\"$DEST\"}" | tr -d '"')
R2=$(urpc "$TOK" request_withdrawal_to "{\"currency_param\":\"BTC\",\"amount_param\":0.2,\"to_address_param\":\"$DEST\"}" | tr -d '"')
arpc approve_wallet_request "{\"request_pub_param\":\"$R1\"}" >/dev/null; sleep 1
arpc approve_wallet_request "{\"request_pub_param\":\"$R2\"}" >/dev/null
q "select process_solana_withdrawals()" >/dev/null 2>&1 || true
chk "solana queue leaves BTC alone" "$(q "select count(*) from wallet_request where pub_id in ('$R1','$R2') and broadcast_txid is not null")" "0"
chk "one withdrawal signed per run" "$(q "select sign_bitcoin_withdrawals()")" "1"
chk "second can't reuse the spent UTXO" "$(q "select sign_bitcoin_withdrawals()" 2>/dev/null)" "0"
chk "oldest request went first" "$(q "select count(*) from btc_withdrawal_tx where request_pub='$R1'")" "1"
chk "txid recorded on the request" "$(q "select broadcast_txid = (select txid from btc_withdrawal_tx where request_pub='$R1') from wallet_request where pub_id='$R1'")" "t"
chk "broadcast once" "$(q "select broadcast_bitcoin_withdrawals()")" "1"
chk "rebroadcast is a no-op" "$(q "select broadcast_bitcoin_withdrawals()")" "0"
RAW=$(head -1 "$STATE/broadcast.log")
chk "raw tx on the wire is the recorded one" "$(q "select raw_hex = '$RAW' from btc_withdrawal_tx where request_pub='$R1'")" "t"
chk "pays 0.1 BTC to the destination" "$(q "select position(encode(btc_le(10000000, 8) || '\\x22'::bytea || btc_testnet_script('$DEST'), 'hex') in '$RAW') > 0")" "t"
chk "confirmed" "$(q "select confirm_bitcoin_withdrawals()")" "1"

echo "== EVM: one approved withdrawal is paid once =="
TOK2=$(signup_jwt "evmw_$S@ex.com" | cut -d" " -f1)
PUB2=$(q "select e.pub_id from auth.users u join app_user au on au.user_id=u.id join app_entity e on e.id=au.app_entity_id where u.email='evmw_$S@ex.com'")
arpc process_transfer "{\"type_param\":\"DEPOSIT\",\"from_customer_id_param\":\"MASTER\",\"amount_param\":1,\"currency_param\":\"EUR\",\"to_customer_id_param\":\"$PUB2\",\"reference_param\":\"t\",\"details_param\":\"t\",\"fee_type_param\":null}" >/dev/null
EDEST=0x1111111111111111111111111111111111111111
whitelist "$TOK2" EUR "$EDEST"
R3=$(urpc "$TOK2" request_withdrawal_to "{\"currency_param\":\"EUR\",\"amount_param\":0.01,\"to_address_param\":\"$EDEST\"}" | tr -d '"')
arpc approve_wallet_request "{\"request_pub_param\":\"$R3\"}" >/dev/null
q "select process_evm_withdrawals()" >/dev/null 2>&1 || true
q "select process_evm_withdrawals()" >/dev/null 2>&1 || true
chk "broadcast exactly once" "$(cat "$STATE/evm.log" 2>/dev/null | wc -l | tr -d ' ')" "1"
chk "txid recorded" "$(q "select broadcast_txid is not null from wallet_request where pub_id='$R3'")" "t"

echo "== ledger =="
chk "reconcile all PASS" "$(arpc reconcile '{}' | jq '[.[] | select(.status != "PASS")] | length')" "0"
echo "result: $pass passed, $fail failed"; [ "$fail" -eq 0 ] && echo "PASS: withdrawal signers" || exit 1
