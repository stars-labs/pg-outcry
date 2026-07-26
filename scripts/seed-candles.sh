#!/usr/bin/env bash
# Demo-only: insert a back-dated random-walk of BTC_USDT trades so the K-line chart
# has history to render. These are SYNTHETIC visual rows (FKs point at one real
# resting order); they don't correspond to real fills. For real candles, let the
# market simulator / live trading populate the tape over time.
set -euo pipefail
PGURL="${PGURL:-postgresql://postgres:postgres@127.0.0.1:54322/postgres}"
N="${N:-360}"                 # number of 1-min steps (~6h)
psql "$PGURL" -v ON_ERROR_STOP=1 <<SQL
DO \$\$
DECLARE iid bigint; oid bigint; px numeric := 100; i int;
BEGIN
  SELECT id INTO iid FROM instrument WHERE name='BTC_USDT';
  SELECT id INTO oid FROM trade_order WHERE instrument_id=iid ORDER BY id LIMIT 1;
  IF oid IS NULL THEN RAISE EXCEPTION 'no trade_order to reference — run seed-demo.sh first'; END IF;
  FOR i IN 1..${N} LOOP
    -- random walk with mild drift + intrabar noise
    px := greatest(5, px + round(((random()-0.49)*1.4)::numeric, 2));
    INSERT INTO trade (instrument_id, price, amount, seller_order_id, buyer_order_id, taker_order_id, created_at, updated_at)
    VALUES (
      iid,
      round((px + (random()-0.5)*0.6)::numeric, 2),
      round((0.2 + random()*2.5)::numeric, 5),
      oid, oid, oid,
      now() - ((${N}-i) || ' minutes')::interval,
      now() - ((${N}-i) || ' minutes')::interval
    );
  END LOOP;
  RAISE NOTICE 'inserted ${N} synthetic trades for BTC_USDT candles';
END\$\$;
SQL
echo "done. K-line now has ~${N}m of history."