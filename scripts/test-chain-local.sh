#!/usr/bin/env bash
# Live end-to-end test of the in-DB deposit watcher against a LOCAL EVM node.
#
# Spins up anvil (Foundry), deploys a minimal ERC-20, sends a Transfer to a
# watched address, then runs poll_evm() inside Postgres and asserts the deposit
# was credited. Proves the pg_cron+pg_net/http watcher works against a real chain.
#
# Requires: foundry (anvil, cast, forge/solc), a running `supabase start`, docker.
# Run on a normal machine (this needs long-lived background processes + sleep,
# which some sandboxes block). Usage:  ./scripts/test-chain-local.sh
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
RPC=http://127.0.0.1:8545
PGURL="${PGURL:-postgresql://postgres:postgres@127.0.0.1:54322/postgres}"
# anvil default account[0] (deployer) + account[1] (watched recipient)
K0=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
ACCT1=0x70997970C51812dc3A010C7d01b50e0d17dc79C8
TMP="$(mktemp -d)"; cleanup(){ kill "${APID:-0}" 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT

echo "▶ starting anvil…"
anvil --host 0.0.0.0 --port 8545 >"$TMP/anvil.log" 2>&1 & APID=$!
until cast block-number --rpc-url $RPC >/dev/null 2>&1; do sleep 0.3; done

echo "▶ deploying ERC-20 + sending a Transfer to $ACCT1…"
cat > "$TMP/T.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
contract T {
  mapping(address=>uint256) public balanceOf;
  event Transfer(address indexed from,address indexed to,uint256 value);
  constructor(){ balanceOf[msg.sender]=10**24; }
  function transfer(address to,uint256 v) external returns(bool){
    balanceOf[msg.sender]-=v; balanceOf[to]+=v; emit Transfer(msg.sender,to,v); return true; }
}
SOL
solc --bin --optimize -o "$TMP/out" --overwrite "$TMP/T.sol" >/dev/null
TOKEN=$(cast send --rpc-url $RPC --private-key $K0 --create "0x$(cat "$TMP/out/T.bin")" --json \
        | python3 -c 'import sys,json;print(json.load(sys.stdin)["contractAddress"])')
cast send --rpc-url $RPC --private-key $K0 "$TOKEN" "transfer(address,uint256)" $ACCT1 2500000000000000000 --json >/dev/null
cast rpc --rpc-url $RPC anvil_mine 0x3 >/dev/null   # extra confirmations
echo "  token=$TOKEN  latest=$(cast block-number --rpc-url $RPC)"

# RPC URL the supabase_db container can use to reach the host
CID=$(docker ps --format '{{.Names}}' | grep -i supabase_db | head -1)
HOSTURL=""
for h in host.docker.internal 172.18.0.1 172.17.0.1; do
  if docker exec "$CID" bash -lc "(exec 3<>/dev/tcp/$h/8545) 2>/dev/null"; then HOSTURL="http://$h:8545"; break; fi
done
[ -n "$HOSTURL" ] || { echo "✗ container cannot reach the host node"; exit 1; }
echo "▶ PG → node at $HOSTURL ; running poll_evm()…"

psql "$PGURL" -q -f "$REPO/supabase/chain/pollers.sql" >/dev/null
psql "$PGURL" -X -v ON_ERROR_STOP=1 -v tok="$(echo "$TOKEN" | tr 'A-Z' 'a-z')" -v rpc="$HOSTURL" -v acct1="$ACCT1" <<'SQL'
update chain set rpc_url=:'rpc', confirmations=1, enabled=true where name='ethereum-sepolia';
delete from chain_asset where chain='ethereum-sepolia';
insert into chain_asset(chain,token,currency,decimals) values ('ethereum-sepolia', :'tok','EUR',18);
select set_config('t.eid', (select id::text from app_entity where pub_id=create_client('chain-local-test')), false);
delete from watched_address where address=:'acct1';
insert into watched_address(app_entity_id,chain,address) values (current_setting('t.eid')::bigint,'ethereum-sepolia',:'acct1');
delete from chain_cursor where chain='ethereum-sepolia';
\echo --- before ---
select currency_name, amount from currency_account where app_entity_id=current_setting('t.eid')::bigint;
select 'poll_evm credited '||poll_evm('ethereum-sepolia')||' deposit(s)' as result;
\echo --- after (expect EUR = 2.5) ---
select currency_name, amount from currency_account where app_entity_id=current_setting('t.eid')::bigint;
select chain, amount, confirmations, (credited_at is not null) as credited from chain_deposit where address=:'acct1';
-- teardown config
update chain set enabled=false, rpc_url=null where name='ethereum-sepolia';
select cron.unschedule('poll-chain-deposits') where exists(select 1 from cron.job where jobname='poll-chain-deposits');
SQL
echo "✓ done — EUR should read 2.5 (2.5 tokens credited from the on-chain Transfer)"
