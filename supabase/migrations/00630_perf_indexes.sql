-- Performance: kill the per-trade stop-order seq scan.
--
-- process_crossing_stop_orders / activate_crossing_stop_orders run on EVERY trade
-- and scan trade_order for crossing STOPLOSS/STOPLIMIT orders. No index covered
-- order_type, so each trade did a Seq Scan over all live orders (profiled:
-- "Rows Removed by Filter: 2602" per call). A partial index over just the stop
-- orders makes that probe instant (0 rows) and stays tiny since stops are rare.

create index if not exists trade_order_stops_idx
  on trade_order (instrument_id, side, price)
  where order_type in ('STOPLOSS','STOPLIMIT');
