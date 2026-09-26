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

# ── Bitcoin withdrawals (migration 00180) ───────────────────────────────────────
# Signed-tx vectors produced by bitcoinjs-lib 6 (RFC-6979, so deterministic); the
# builder was checked against 120 random cases, these two are kept as regressions.
BTCV='{"inputs":[{"txid":"86080663da77d30bf1369d8679b7a1dc170e30a7d537eae4aa6f9c3d34f68ef7","vout":4,"value":312794034,"priv":"7e4099a12239d23c2fac0bdf797e961704d001a5b22fe8bf3139f5bd67824493"}],"outputs":[{"address":"mvTujwTjp5LLmJPxyc5chSrnNLMhAHMV6D","value":23948272},{"address":"tb1qm25r95jpzqulxxjfvnrcfw2s260qny03mnqhsulfl5rt90k8g5ps0ssm0m","value":80804343}]}'
btc_tx="$(q "select btc_build_signed_tx(('$BTCV'::jsonb)->'inputs', ('$BTCV'::jsonb)->'outputs')->>'hex';")"
check "bitcoin: 1-in/2-out P2WPKH spend byte-identical to bitcoinjs-lib" "02000000000101f78ef6343d9c6faae4ea37d5a7300e17dca1b779869d36f10bd377da630608860400000000ffffffff02f06b6d01000000001976a914a3f681d4ee9cdbdfd1fa99f587d13142a7e4f33188acf7f9d00400000000220020daa832d2411039f31a4964c784b950569e0991f1dcc17873e9fd06b2bec7450302483045022100d4abae1676a12ea7a1cb60ab41a13116c2ee097bc24a49935fcbbb9020793bdc02201fe418d3700cef32876bfd3211c00b61e953fd0e4af9064fb9e4dbb32ce8ca4b012102606ad2a72aa646ab9144762caea7b183cbeafd26cd5d88c2b160be44f558380600000000" "$btc_tx"
BTCV='{"inputs":[{"txid":"dd9ec8dfb21fa3d7b79382e32e4416cf8122418bbd501f78aef9b0e092ce0ed5","vout":3,"value":751583971,"priv":"2922cb6352e98f8e608d1ec4190cad359b0eea16c510d5d476c80ab08cea1211"},{"txid":"447a15c7afdcd689f16b4f24d92058c3acaf7b688180826bafa35080d5a82177","vout":4,"value":361653323,"priv":"e412fab4f40983761300957d54fa4b67f2324cd353e68e2bc45efeebc35cf56b"},{"txid":"1719102a9537ee71b9622d1c32fb81be098a4dcf3ad623eaee4ab2a22bb93616","vout":3,"value":338212824,"priv":"ae889a96ddb5424141e86eba3e2fadff92c6ee9935c913a0cff6f2c3384b5cb0"}],"outputs":[{"address":"2N4JhnwqNs5YuTdWHWpedVo5AVkNhmroAP7","value":13695271},{"address":"tb1pznce58a6gthaq3w82klch3pv4ltff5vvwn7f7h2leqcjgry0dgjs52kj6j","value":69042607}]}'
btc_tx="$(q "select btc_build_signed_tx(('$BTCV'::jsonb)->'inputs', ('$BTCV'::jsonb)->'outputs')->>'hex';")"
check "bitcoin: 3-in spend incl. a P2TR output byte-identical to bitcoinjs-lib" "02000000000103d50ece92e0b0f9ae781f50bd8b412281cf16442ee38293b7d7a31fb2dfc89edd0300000000ffffffff7721a8d58050a3af6b828081687bafacc35820d9244f6bf189d6dcafc7157a440400000000ffffffff1636b92ba2b24aeeea23d63acf4d8a09be81fb321c2d62b971ee37952a1019170300000000ffffffff0227f9d0000000000017a9147951d77005f5ebdaeb63da82134e853ee6cd817387af811d040000000022512014f19a1fba42efd045c755bf8bc42cafd694d18c74fc9f5d5fc831240c8f6a250247304402201cb4f0f576b8212bc57002a8de718ff36a9c2b007e70a76096e96b27fc43b8ad0220293b10b271553de1b3dc3f2d8abd2bf78b0fd61bd22b9ab870ef614f9dfdd7530121022e06072a2e65a3e3315af08d97a99eba55d30d9d6e335763255039d98dc5030602483045022100c76e443c9a529d772cdf5fdff1f04e42f3e689ab80728d684fb1ed5d5f90c5d502201516a32de81d5ee6b187f535f9f89939d9248d9b898e457c41464684b3799c4e0121038938f0fef02126453bb8cc331ef459bc688fb7ac9a016efe903a0c2298d8a9470248304502210087e83ac5c2075bfaa35fae2a3a51989cdca1e9179d208a683366b76521868b8002206fa9c2e9dc9c0bbca71d7727fda23ea726010e477975f5bf499f92b3af0647bf012103f6f97e2b4f84b6bfbd9f1b4a3f552f31efc4284b9d731a65833096b71e90cb8200000000" "$btc_tx"
btc_bad() { q "do \$\$ begin perform btc_testnet_script('$1'); raise exception 'accepted'; exception when others then raise notice '%', sqlerrm; end \$\$" 2>&1 | grep -o 'btc_address_[a-z_]*\|accepted' | head -1; }
check "bitcoin: mainnet address refused" "btc_address_not_testnet" "$(btc_bad bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4)"
check "bitcoin: bad bech32 checksum refused" "btc_address_bad_checksum" "$(btc_bad tb1qw508d6qejxtdg4y5r3zarvary0c5xw7kxpjzsy)"
check "bitcoin: mixed-case bech32 refused" "btc_address_mixed_case" "$(btc_bad tb1qW508d6qejxtdg4y5r3zarvary0c5xw7kxpjzsx)"
check "bitcoin: bech32 (not bech32m) taproot refused" "btc_address_bad_checksum" "$(btc_bad tb1pw508d6qejxtdg4y5r3zarvary0c5xw7kxpjzsx)"
sel="$(q "select (s->>'fee')||'/'||(s->>'change')||'/'||jsonb_array_length(s->'inputs') from btc_select_coins('[{\"txid\":\"a\",\"vout\":0,\"value\":30000},{\"txid\":\"b\",\"vout\":1,\"value\":100000}]'::jsonb, 90000, 2) s;")"
check "bitcoin: coin selection takes the largest UTXO first, fee at 2 sat/vB" "330/9670/1" "$sel"
dust="$(q "select (s->>'fee')||'/'||(s->>'change') from btc_select_coins('[{\"txid\":\"a\",\"vout\":0,\"value\":100500}]'::jsonb, 100000, 1) s;")"
check "bitcoin: dust change is added to the fee" "500/0" "$dust"

echo "----------------------------------------"
if [[ "$fails" -gt 0 ]]; then
  echo "FAILED: $fails assertion(s)"
  exit 1
fi
echo "ALL PASS"
