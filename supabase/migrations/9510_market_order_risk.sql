-- Market orders carry no meaningful limit price, so the price-band and
-- max-notional sanity checks in `check_order_risk` (which compare against a
-- limit price) don't apply. The frontend sends price = 0 for MARKET orders,
-- which the old place_order fed straight into the band check and got rejected
-- with `risk_price_band: 0 beyond N pct band of last <price>`.
--
-- Also note the engine's BUY MARKET model treats `amount` as the QUOTE budget
-- (currency to spend), not a base quantity — so the per-instrument max base
-- amount limit doesn't map to a BUY MARKET either. SELL MARKET `amount` is
-- still base, so we keep the amount cap for that side.
--
-- Re-define place_order to apply the right risk checks per order type:
--   LIMIT / STOPLIMIT / STOPLOSS → full check (band/notional/amount)
--   SELL MARKET                  → amount cap only (price-based checks skipped)
--   BUY  MARKET                  → no instrument risk check (bounded by funds)

create or replace function place_order(
    instrument_name_param text,
    side_param            order_side,
    order_type_param      text,
    price_param           numeric,
    amount_param          numeric,
    time_in_force_param   text
  )
  returns text
  language plpgsql security definer set search_path = public, pg_temp
as $$
declare
  ia  text;
  iid bigint;
begin
  select ia2.pub_id into ia
  from instrument_account ia2
  where ia2.app_entity_id = current_app_entity_id()
  limit 1;
  if ia is null then raise exception 'not_authenticated_or_no_account'; end if;

  select id into iid from instrument where name = instrument_name_param;
  if iid is null then raise exception 'instrument_not_found: %', instrument_name_param; end if;

  if order_type_param = 'MARKET' then
    -- price-based checks (band/notional) are meaningless without a limit price.
    -- SELL MARKET amount is base → keep the amount cap by passing a null price
    -- (check_order_risk guards band/notional on `price is not null`).
    -- BUY MARKET amount is a quote budget → skip the instrument risk check.
    if side_param = 'SELL' then
      perform check_order_risk(iid, side_param, null, amount_param);
    end if;
  else
    perform check_order_risk(iid, side_param, price_param, amount_param);
  end if;

  perform pg_advisory_xact_lock(iid);
  return process_trade_order(ia, instrument_name_param, order_type_param,
    side_param, price_param, amount_param, time_in_force_param, 0);
end $$;
