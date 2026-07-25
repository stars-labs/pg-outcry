-- Stage 2 (part 3): pre-trade risk controls (per instrument).
-- Enforced on the authenticated user path (place_order). The admin path
-- (submit_order via service_role) intentionally bypasses risk for overrides.

create table instrument_risk (
  instrument_id      bigint primary key references instrument(id),
  max_order_amount   numeric,        -- max base qty per order (null = unlimited)
  max_order_notional numeric,        -- max price*amount in quote per order
  price_band_pct     numeric,        -- limit price must be within +/- pct of last trade
  enabled            boolean not null default true,
  updated_at         timestamptz not null default current_timestamp
);

create or replace function check_order_risk(
    iid bigint, side_param order_side, price_param numeric, amount_param numeric)
  returns void
  language plpgsql security definer set search_path = public, pg_temp
as $$
declare
  r   instrument_risk%rowtype;
  ref numeric;
begin
  select * into r from instrument_risk where instrument_id = iid;
  if not found or not r.enabled then return; end if;

  if r.max_order_amount is not null and amount_param > r.max_order_amount then
    raise exception 'risk_max_order_amount: % > %', amount_param, r.max_order_amount;
  end if;

  if r.max_order_notional is not null and price_param is not null
     and price_param * amount_param > r.max_order_notional then
    raise exception 'risk_max_order_notional: % > %', price_param * amount_param, r.max_order_notional;
  end if;

  if r.price_band_pct is not null and price_param is not null then
    select price into ref from trade where instrument_id = iid order by created_at desc limit 1;
    if ref is not null and abs(price_param - ref) / ref * 100 > r.price_band_pct then
      raise exception 'risk_price_band: % beyond % pct band of last %', price_param, r.price_band_pct, ref;
    end if;
  end if;
end $$;

-- place_order + risk check (resolves caller's own account from auth.uid()).
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

  perform check_order_risk(iid, side_param, price_param, amount_param);
  perform pg_advisory_xact_lock(iid);
  return process_trade_order(ia, instrument_name_param, order_type_param,
    side_param, price_param, amount_param, time_in_force_param, 0);
end $$;

-- Sensible default band/limits for the demo instrument.
insert into instrument_risk(instrument_id, max_order_amount, max_order_notional, price_band_pct)
select id, 100, 100000, 10 from instrument where name = 'BTC_EUR';
