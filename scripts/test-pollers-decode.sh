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

# ── Native balance decoders (migration 9990 — present after db reset) ────────────
# eth_getBalance result hex wei (0xb1a2bc2ec50000 = 5e16 = 0.05 ETH)
evm_bal="$(q "select trim_scale(decode_evm_balance('{\"result\":\"0xb1a2bc2ec50000\"}'::jsonb))::text;")"
check "evm balance: hex wei decoded (0.05 ETH)" "50000000000000000" "$evm_bal"
# getBalance result.value lamports
sol_bal="$(q "select decode_solana_balance('{\"result\":{\"context\":{\"slot\":1},\"value\":2500000000}}'::jsonb)::text;")"
check "solana balance: result.value lamports" "2500000000" "$sol_bal"
# TronGrid /v1/accounts data[0].balance sun; inactive account [] -> 0
tron_bal="$(q "select decode_tron_balance('{\"data\":[{\"balance\":1500000}]}'::jsonb)::text;")"
check "tron balance: data[0].balance sun" "1500000" "$tron_bal"
tron_bal0="$(q "select decode_tron_balance('{\"data\":[]}'::jsonb)::text;")"
check "tron balance: inactive account -> 0" "0" "$tron_bal0"

# ── Bitcoin testnet4 (migration 00160) ──────────────────────────────────────────
# BIP-173 vector: priv = 1 -> pubkey G -> P2WPKH
btc_tb="$(q "select btc_p2wpkh_address(secp_n2bytea(1), 'tb');")"
check "bitcoin: BIP-173 testnet P2WPKH for priv=1" "tb1qw508d6qejxtdg4y5r3zarvary0c5xw7kxpjzsx" "$btc_tb"
btc_bc="$(q "select btc_p2wpkh_address(secp_n2bytea(1), 'bc');")"
check "bitcoin: BIP-173 mainnet P2WPKH for priv=1" "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4" "$btc_bc"
# odd-y pubkey takes the 03 prefix (priv = 6: 6G has odd y). Expected value
# computed independently (Python EC math + hashlib + BIP-173 reference bech32).
btc_odd="$(q "select btc_p2wpkh_address(secp_n2bytea(6), 'bc');")"
check "bitcoin: odd-y key uses 03 prefix" "bc1q0ldfeupqc9k2eaffep7cm6yml3ct3jwtwzqt7k" "$btc_odd"

# Esplora /address/:a/txs, shape taken from mempool.space/testnet4: one confirmed tx
# paying us at vout 1, one mempool tx paying us, one tx where we only spend.
ME="tb1q8tjcjtnz4aq78ur03jv2znjzhxg3360z77lqcv"
ESPLORA="[
 {\"txid\":\"f8340df19c3ddb0cbd96f6a7752fcaf45fa7af6660b47fe84b4cd8465da7d3c4\",\"status\":{\"confirmed\":true,\"block_height\":153960},
  \"vout\":[{\"scriptpubkey_address\":\"tb1qqws3aatj6jz2nz8d7zefwmtmcccx4umlc5ygr7\",\"value\":5602338},{\"scriptpubkey_address\":\"$ME\",\"value\":50000}]},
 {\"txid\":\"aa00\",\"status\":{\"confirmed\":false},\"vout\":[{\"scriptpubkey_address\":\"$ME\",\"value\":120000000}]},
 {\"txid\":\"bb00\",\"status\":{\"confirmed\":true,\"block_height\":153900},\"vin\":[{\"prevout\":{\"scriptpubkey_address\":\"$ME\"}}],
  \"vout\":[{\"scriptpubkey_type\":\"op_return\",\"value\":0},{\"scriptpubkey_address\":\"tb1qother\",\"value\":1}]}
]"
btc_rows="$(q "select string_agg(left(txid,6)||':'||vout||':'||sats||':'||confirmations, ' ' order by txid desc)
               from decode_esplora_deposits('${ESPLORA}'::jsonb, '$ME', 153961);")"
check "bitcoin: esplora outputs to us, with vout index and confirmations" \
  "f8340d:1:50000:2 aa00:0:120000000:0" "$btc_rows"

echo "----------------------------------------"
if [[ "$fails" -gt 0 ]]; then
  echo "FAILED: $fails assertion(s)"
  exit 1
fi
echo "ALL PASS"
