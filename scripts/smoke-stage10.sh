#!/usr/bin/env bash
# Stage 10: house market maker anchored to an external (Binance) reference.
# Network-free: the reference is set with mm_set_reference instead of fetched, so
# the quoting, arbitrage, inventory skew and safety pauses are all deterministic.
set -euo pipefail
API="${API:-http://127.0.0.1:54321}"
SERVICE="${SERVICE:?set SERVICE}"
PGURL="${PGURL:-postgresql://postgres:postgres@127.0.0.1:54322/postgres}"
if [ "${RESET:-1}" = "1" ]; then echo "(resetting db)"; bash "$(dirname "$0")/reset-db.sh"; fi

arpc(){ curl -s -X POST "$API/rest/v1/rpc/$1" -H "apikey: $SERVICE" -H "Authorization: Bearer $SERVICE" -H "Content-Type: application/json" -d "$2"; }
q(){ psql "$PGURL" -X -tAc "$1"; }
pass=0; fail=0
chk(){ if [ "$2" = "$3" ]; then echo "  ok: $1"; pass=$((pass+1)); else echo "  FAIL: $1 (got '$2' want '$3')"; fail=$((fail+1)); fi; }
mm_orders(){ q "select count(*) from trade_order o join instrument_account ia on ia.id=o.instrument_account_id
               join app_entity e on e.id=ia.app_entity_id where e.pub_id='HOUSE_MM'
               and o.status in ('OPEN','PARTIALLY_FILLED') ${1:+and o.side='$1'}"; }
S=$(date +%s)

echo "== decoder: Binance bookTicker fixture =="
chk "decodes bid/ask" "$(q "select bid||'/'||ask from mm_decode_book_ticker('{\"symbol\":\"BTCUSDT\",\"bidPrice\":\"100000.01000000\",\"bidQty\":\"1.2\",\"askPrice\":\"100000.02000000\",\"askQty\":\"0.4\"}')")" "100000.01000000/100000.02000000"
chk "crossed book rejected" "$(q "select count(*) from mm_decode_book_ticker('{\"bidPrice\":\"2\",\"askPrice\":\"1\"}')")" "0"

echo "== operator controls (service_role through PostgREST) =="
arpc admin_mm_fund '{"currency_param":"USDT","amount_param":1000000}' >/dev/null
arpc admin_mm_fund '{"currency_param":"BTC","amount_param":1}' >/dev/null
chk "float funded from MASTER" "$(q "select trim_scale(mm_free_balance('HOUSE_MM','BTC'))")" "1"
arpc admin_mm_configure '{"instrument_param":"BTC_USDT","settings":{"target_base":1,"max_skew_base":0.5,"level_size":0.01}}' >/dev/null
chk "unknown setting rejected" "$(arpc admin_mm_configure '{"instrument_param":"BTC_USDT","settings":{"spread":1}}' | grep -c mm_unknown_setting)" "1"
arpc admin_mm_set_enabled '{"instrument_param":"BTC_USDT","enabled_param":true}' >/dev/null
chk "cron armed while enabled" "$(q "select count(*) from cron.job where jobname='mm-tick'")" "1"
q "select cron.unschedule('mm-tick')" >/dev/null   # this test drives ticks by hand

echo "== quotes bracket the reference =="
q "select mm_set_reference('BTC_USDT', 99990, 100010)" >/dev/null
chk "quoting" "$(q "select mm_quote('BTC_USDT')")" "quoting"
chk "5 bid levels" "$(mm_orders BUY)" "5"
chk "5 ask levels" "$(mm_orders SELL)" "5"
chk "best bid 5bps under mid" "$(q "select quoted_bid from mm_state where instrument='BTC_USDT'")" "99950.00"
chk "best ask 5bps over mid" "$(q "select quoted_ask from mm_state where instrument='BTC_USDT'")" "100050.00"
q "select mm_quote('BTC_USDT')" >/dev/null
chk "requote replaces, does not stack" "$(mm_orders)" "10"

echo "== price band and perp index follow the reference =="
chk "reference_price is the anchor mid" "$(q "select trim_scale(reference_price('BTC_USDT'))")" "100000"
chk "order 20% off the anchor fails the band" \
  "$(q "do \$\$ begin perform check_order_risk((select id from instrument where name='BTC_USDT'),'BUY',120000,0.01); raise exception 'passed'; exception when others then raise notice '%', sqlerrm; end \$\$" 2>&1 | grep -c risk_price_band)" "1"

echo "== a mispriced user order is arbitraged back to the anchor =="
U=$(arpc create_client "{\"external_id_param\":\"mmu_$S\"}" | tr -d '"')
arpc create_currency_account "{\"app_entity_id_param\":\"$U\",\"currency_param\":\"BTC\"}" >/dev/null
arpc process_transfer "{\"type_param\":\"DEPOSIT\",\"from_customer_id_param\":\"MASTER\",\"amount_param\":1,\"currency_param\":\"BTC\",\"to_customer_id_param\":\"$U\",\"reference_param\":\"s\",\"details_param\":\"s\",\"fee_type_param\":null}" >/dev/null
UA=$(arpc find_instrument_account "{\"external_id_param\":\"mmu_$S\"}" | tr -d '"')
q "select mm_cancel_quotes('BTC_USDT')" >/dev/null
UO=$(arpc submit_order "{\"instrument_account_id_param\":\"$UA\",\"instrument_name_param\":\"BTC_USDT\",\"order_type_param\":\"LIMIT\",\"side_param\":\"SELL\",\"price_param\":99000,\"amount_param\":0.01,\"time_in_force_param\":\"GTC\"}" | tr -d '"')
q "select mm_quote('BTC_USDT')" >/dev/null
chk "cheap ask filled by the maker" "$(q "select status from trade_order where pub_id='$UO'")" "FILLED"
chk "maker bought the 0.01" "$(q "select trim_scale(base_free) from mm_state where instrument='BTC_USDT'")" "1.01"

echo "== inventory skew stops the side that grows the position =="
arpc admin_mm_configure '{"instrument_param":"BTC_USDT","settings":{"target_base":0.4}}' >/dev/null
q "select mm_quote('BTC_USDT')" >/dev/null
chk "long past the limit: no bids" "$(mm_orders BUY)" "0"
chk "still offering" "$(mm_orders SELL)" "5"
chk "asks skewed down 10bps" "$(q "select quoted_ask from mm_state where instrument='BTC_USDT'")" "99949.95"
arpc admin_mm_configure '{"instrument_param":"BTC_USDT","settings":{"target_base":1}}' >/dev/null

echo "== safety: stale or jumping reference pulls all quotes =="
q "update mm_state set ref_at = now() - interval '1 hour' where instrument='BTC_USDT'" >/dev/null
chk "stale -> paused" "$(q "select mm_quote('BTC_USDT')")" "paused"
chk "stale -> no quotes" "$(mm_orders)" "0"
chk "stale reference not used for the band" "$(q "select trim_scale(reference_price('BTC_USDT'))")" "99000"
q "select mm_set_reference('BTC_USDT', 99990, 100010)" >/dev/null
chk "5% jump flagged" "$(q "select mm_set_reference('BTC_USDT', 104990, 105010)")" "jump"
chk "jump -> paused" "$(q "select mm_quote('BTC_USDT')")" "paused"
chk "jump -> no quotes" "$(mm_orders)" "0"
chk "confirmed move accepted" "$(q "select mm_set_reference('BTC_USDT', 104995, 105005)")" "ok"
chk "resumes quoting" "$(q "select mm_quote('BTC_USDT')")" "quoting"

echo "== tick survives a failed fetch without leaving quotes =="
q "update mm_config set ref_url='http://127.0.0.1:9/nope' where instrument='BTC_USDT'" >/dev/null
q "update mm_state set ref_at = now() - interval '1 hour' where instrument='BTC_USDT'" >/dev/null
q "select mm_tick()" >/dev/null
chk "fetch failure recorded" "$(q "select reason like 'fetch_failed%' from mm_state where instrument='BTC_USDT'")" "t"
chk "no quotes on a dead feed" "$(mm_orders)" "0"

echo "== disable pulls quotes and disarms cron =="
q "select mm_set_reference('BTC_USDT', 104995, 105005)" >/dev/null
q "select mm_quote('BTC_USDT')" >/dev/null
arpc admin_mm_set_enabled '{"instrument_param":"BTC_USDT","enabled_param":false}' >/dev/null
chk "disabled -> no quotes" "$(mm_orders)" "0"
chk "cron disarmed" "$(q "select count(*) from cron.job where jobname='mm-tick'")" "0"
chk "status via admin RPC" "$(arpc admin_mm_status '{}' | grep -o '"status": *"[a-z]*"' | tr -d ' "' )" "status:disabled"

echo "== ledger invariants still hold =="
chk "reconcile all PASS" "$(arpc reconcile '{}' | jq '[.[] | select(.status != "PASS")] | length')" "0"

echo "result: $pass passed, $fail failed"; [ "$fail" -eq 0 ] && echo "PASS: house market maker" || exit 1
