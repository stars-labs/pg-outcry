-- Group-commit batch order submission.
--
-- Durable-settlement throughput is bound by the per-commit WAL fsync (see
-- TUNING.md): one submit_order = one transaction = one fsync. Processing N
-- orders for an instrument in ONE transaction amortizes that fsync over N
-- orders — a large throughput gain WITHOUT relaxing durability
-- (synchronous_commit stays on). The whole batch also takes the per-instrument
-- advisory lock once.
--
-- Trade-off to tune (see scripts/bench-batch.sh): a bigger batch raises
-- throughput but holds the instrument lock longer, so concurrent submitters on
-- the same symbol wait more — pick the batch size at the throughput/latency knee.
--
-- orders: jsonb array of {"type","side","price","amount","tif"}.
-- Returns the taker pub_ids in order. All-or-nothing: any order that raises
-- aborts the whole batch (one transaction).

create or replace function submit_orders(
    instrument_account_id_param text,
    instrument_name_param       text,
    orders                      jsonb
  )
  returns text[]
  language plpgsql
  security definer
  set search_path = public, pg_temp
as $$
declare
  iid  bigint;
  o    jsonb;
  ids  text[] := '{}';
begin
  if jsonb_typeof(orders) <> 'array' then
    raise exception 'orders must be a JSON array';
  end if;

  select id into iid from instrument where name = instrument_name_param;
  if iid is null then raise exception 'instrument_not_found: %', instrument_name_param; end if;

  perform pg_advisory_xact_lock(iid);   -- one lock for the whole batch

  for o in select value from jsonb_array_elements(orders) loop
    ids := ids || process_trade_order(
      instrument_account_id_param, instrument_name_param,
      o->>'type', (o->>'side')::order_side,
      nullif(o->>'price','')::numeric, (o->>'amount')::numeric,
      coalesce(o->>'tif','GTC'), 0);
  end loop;

  return ids;
end $$;

-- Like submit_order, this takes an explicit account id, so it is an operator /
-- market-maker tool on the service_role plane — NOT a self-scoped end-user RPC.
-- 9900_lockdown revokes execute from public/anon/authenticated on every function
-- and re-grants service_role, so we only need to lock out PUBLIC here; the
-- service_role grant is (re)applied by lockdown. End users place single orders
-- via the auth.uid()-scoped place_order; an auth-scoped place_orders could be
-- added later if per-user batching is needed.
revoke execute on function submit_orders(text,text,jsonb) from public;
grant  execute on function submit_orders(text,text,jsonb) to service_role;
