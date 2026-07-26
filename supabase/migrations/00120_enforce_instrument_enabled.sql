-- Actually enforce instrument.enabled.
--
-- Retiring a pair by setting `enabled = false` only removed it from the symbol
-- picker: nothing on the write path consulted the flag, so a delisted instrument
-- still accepted orders from anyone calling the API directly. Verified before this
-- migration — an order on the disabled BTC_EUR was accepted.
--
-- A BEFORE INSERT trigger on trade_order covers every entry point at once
-- (place_order, submit_order, submit_orders and the engine's internal paths)
-- without redefining the order functions.

create or replace function reject_order_on_disabled_instrument()
  returns trigger
  language plpgsql
  set search_path = public, pg_temp
as $$
declare nm text;
begin
  select i.name into nm from instrument i
   where i.id = new.instrument_id and i.enabled is not true;
  if nm is not null then
    raise exception 'instrument_not_enabled: %', nm
      using hint = 'This pair has been delisted; trading is closed.';
  end if;
  return new;
end $$;

drop trigger if exists trg_reject_disabled_instrument on trade_order;
create trigger trg_reject_disabled_instrument
  before insert on trade_order
  for each row execute function reject_order_on_disabled_instrument();

revoke execute on function reject_order_on_disabled_instrument() from public, anon, authenticated;
