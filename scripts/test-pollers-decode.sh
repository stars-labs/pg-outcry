#!/usr/bin/env bash
# Deterministic, network-free unit test for the pure JSON->deposit decoders in
# supabase/chain/pollers.sql (decode_evm_logs / decode_tron_trc20 /
# decode_solana_credit). Loads the pollers file, feeds REAL representative RPC/
# explorer JSON fixtures into the decoders, and asserts the decoded
# txid / to-address / amount are exactly correct — including amounts that overflow
# int64 (the bug class these decoders exist to prevent). No network, no db reset.
#
#   ./scripts/test-pollers-decode.sh
#   PGURL=postgresql://... ./scripts/test-pollers-decode.sh
set -euo pipefail

PGURL="${PGURL:-postgresql://postgres:postgres@127.0.0.1:54322/postgres}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PSQL=(psql "$PGURL" -X -q -t -A -v ON_ERROR_STOP=1)

fails=0
check() { # check <name> <expected> <actual>
  if [[ "$2" == "$3" ]]; then
    printf 'PASS  %s\n' "$1"
  else
    printf 'FAIL  %s\n        expected: %q\n        actual:   %q\n' "$1" "$2" "$3"
    fails=$((fails + 1))
  fi
}

# Load the decoders (and pollers). CREATE OR REPLACE only — no data mutation.
"${PSQL[@]}" -f "$ROOT/supabase/chain/pollers.sql" >/dev/null

q() { "${PSQL[@]}" -c "$1"; }

# ── EVM fixture: eth_getLogs result, ERC-20 Transfer to a watched address ────────
# data is 5000000000000000000000 (5e21) = 0x...10f0cf064dd59200000 — far above
# int64 max (~9.2e18); the old ::bit(64) parse errored/overflowed here.
EVM_RESP='{"result":[
  {"transactionHash":"0xfeed0001",
   "logIndex":"0x11","blockNumber":"0x1000",
   "topics":["0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef",
             "0x0000000000000000000000001111111111111111111111111111111111111111",
             "0x000000000000000000000000aabbccddeeff00112233445566778899aabbccdd"],
   "data":"0x00000000000000000000000000000000000000000000010f0cf064dd59200000"},
  {"transactionHash":"0xfeed0002",
   "logIndex":"0x2","blockNumber":"0x1001",
   "topics":["0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef",
             "0x0000000000000000000000001111111111111111111111111111111111111111",
             "0x000000000000000000000000deadbeef00000000000000000000000000000000"],
   "data":"0x0000000000000000000000000000000000000000000000000de0b6b3a7640000"}
]}'
EVM_WATCH="ARRAY['0xaabbccddeeff00112233445566778899aabbccdd']"

evm_row="$(q "select txid||'|'||to_addr||'|'||log_index||'|'||amount::text||'|'||block
  from decode_evm_logs('${EVM_RESP}'::jsonb, '0xtoken', 18, ${EVM_WATCH});")"
check "evm: only the watched log is decoded, big amount intact" \
  "0xfeed0001|0xaabbccddeeff00112233445566778899aabbccdd|17|5000|4096" \
  "$evm_row"

# ── Tron fixture: TronGrid /transactions/trc20 (value is a STRING) ───────────────
# Includes a value of 99999999999999999999999 (>> int64) and a non-Transfer row
# and a transfer to an unwatched address — both must be excluded.
TRON_RESP='{"data":[
  {"transaction_id":"trontx01",
   "token_info":{"address":"TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t","decimals":6,"symbol":"USDT"},
   "from":"TFrom","to":"TWatchedAddr","value":"1500000","type":"Transfer"},
  {"transaction_id":"trontx02",
   "token_info":{"address":"TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t","decimals":6,"symbol":"USDT"},
   "from":"TFrom","to":"TWatchedAddr","value":"99999999999999999999999","type":"Transfer"},
  {"transaction_id":"trontx03",
   "token_info":{"address":"TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t","decimals":6,"symbol":"USDT"},
   "from":"TFrom","to":"TWatchedAddr","value":"5","type":"Approval"},
  {"transaction_id":"trontx04",
   "token_info":{"address":"TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t","decimals":6,"symbol":"USDT"},
   "from":"TFrom","to":"TSomeoneElse","value":"7","type":"Transfer"}
]}'
# decoder lower()s the watched array; match on the lowercased `to`.
TRON_WATCH="ARRAY['twatchedaddr']"

tron_n="$(q "select count(*) from decode_tron_trc20('${TRON_RESP}'::jsonb, ${TRON_WATCH});")"
check "tron: excludes Approval + unwatched (2 of 4 rows)" "2" "$tron_n"

tron_first="$(q "select txid||'|'||token||'|'||amount_raw::text
  from decode_tron_trc20('${TRON_RESP}'::jsonb, ${TRON_WATCH})
  where txid='trontx01';")"
check "tron: first transfer decoded (raw value, token lowercased)" \
  "trontx01|tr7nhqjekqxgtci8q8zy4pl8otszgjlj6t|1500000" \
  "$tron_first"

tron_big="$(q "select amount_raw::text from decode_tron_trc20('${TRON_RESP}'::jsonb, ${TRON_WATCH})
  where txid='trontx02';")"
check "tron: int64-overflowing string value parsed exactly as numeric" \
  "99999999999999999999999" "$tron_big"

# ── Solana fixture: getTransaction(jsonParsed) — accountKeys are OBJECTS ──────────
# The watched account is at index 1; postBalances[1]-preBalances[1] = 2e9 lamports.
SOL_TX='{"meta":{"preBalances":[100000000,500000000,7],
                 "postBalances":[99995000,2500000000,7]},
         "transaction":{"message":{"accountKeys":[
            {"pubkey":"PayerPubkey1111","signer":true,"writable":true},
            {"pubkey":"WatchedSolAddr","signer":false,"writable":true},
            {"pubkey":"SysProgram1111","signer":false,"writable":false}]}}}'

sol_lamports="$(q "select decode_solana_credit('${SOL_TX}'::jsonb, 'WatchedSolAddr')::text;")"
check "solana: lamports gained read via accountKeys[].pubkey (objects, not strings)" \
  "2000000000" "$sol_lamports"

sol_missing="$(q "select coalesce(decode_solana_credit('${SOL_TX}'::jsonb, 'NotInTx')::text, 'NULL');")"
check "solana: returns NULL when address not in accountKeys" "NULL" "$sol_missing"

echo "----------------------------------------"
if [[ "$fails" -gt 0 ]]; then
  echo "FAILED: $fails assertion(s)"
  exit 1
fi
echo "ALL PASS"
