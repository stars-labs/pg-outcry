-- House market maker, anchored to Binance.
--
-- A house account (HOUSE_MM, type='MASTER') holds its own float and keeps a
-- two-sided ladder around the Binance book for each configured pair. Anchoring
-- works through the book itself:
--
--   * Quotes are re-centred on the Binance mid every tick, so the best bid/ask
--     always bracket the external price.
--   * A user order priced through the anchor (a bid above our ask, an ask below
--     our bid) is filled by our requote — the engine matches the new quote
--     against it — so the local price cannot drift away from Binance for longer
--     than one tick while the maker has float.
--   * The reference also becomes the pre-trade price-band centre, the perp index
--     and the margin valuation, so every price the venue uses agrees.
--
-- Inventory control: the maker aims to hold `target_base`. As its base balance
-- drifts, quotes are skewed (reservation price shifted by up to `skew_bps`) so
-- fills pull it back, and at `max_skew_base` the side that would add to the
-- position stops quoting. There is no hedge on Binance: the float is the risk.
--
-- Safety: a stale reference (older than max_ref_age_s) or a jump larger than
-- max_ref_move_pct between consecutive fetches cancels all quotes for that tick.
-- Disabling a pair cancels its quotes at once.
--
-- The demo maker (DEMO_MM_A/B, random-walk mid) is removed; this replaces it.
-- `demo_prints` optionally lets a second house account take the maker's quote so
-- an otherwise idle demo still prints trades. That is synthetic volume: it must
-- stay off on a venue with real customers.

-- ── remove the random-walk demo maker ───────────────────────────────────────
do $$ begin perform cron.unschedule('demo-market-tick');  exception when others then null; end $$;
do $$ begin perform cron.unschedule('demo-market-prune'); exception when others then null; end $$;
drop function if exists demo_market_tick();
drop function if exists demo_market_prune();
drop function if exists demo_enable_liquidity();
drop function if exists demo_disable_liquidity();
drop function if exists demo_maker_account(text);

-- cancel the old makers' orders and return their float to MASTER
do $$
declare r record;
begin
  for r in
    select o.pub_id from trade_order o
    join instrument_account ia on ia.id = o.instrument_account_id
    join app_entity e on e.id = ia.app_entity_id
    where e.pub_id in ('DEMO_MM_A','DEMO_MM_B') and o.status in ('OPEN','PARTIALLY_FILLED')
  loop
    perform submit_cancel(r.pub_id);
  end loop;
  for r in
    select e.pub_id, ca.currency_name, ca.amount from currency_account ca
    join app_entity e on e.id = ca.app_entity_id
    where e.pub_id in ('DEMO_MM_A','DEMO_MM_B') and ca.amount > 0
  loop
    perform process_transfer('WITHDRAWAL', r.pub_id, r.amount, r.currency_name, 'MASTER',
                             'demo maker retired', 'return house float', null);
  end loop;
end $$;

-- ── configuration and state ─────────────────────────────────────────────────
create table if not exists mm_config (
  instrument        text primary key references instrument(name),
  ref_url           text    not null,                  -- Binance bookTicker endpoint
  enabled           boolean not null default false,
  demo_prints       boolean not null default false,    -- synthetic trades; demo only
  half_spread_bps   numeric not null default 5   check (half_spread_bps > 0),
  level_step_bps    numeric not null default 5   check (level_step_bps > 0),
  levels            int     not null default 5   check (levels between 1 and 20),
  level_size        numeric not null default 0.01 check (level_size > 0),  -- base, first level
  size_growth       numeric not null default 0.5 check (size_growth >= 0), -- +50% per level
  target_base       numeric not null default 1   check (target_base >= 0),
  max_skew_base     numeric not null default 0.5 check (max_skew_base > 0),
  skew_bps          numeric not null default 10  check (skew_bps >= 0),
  max_ref_age_s     int     not null default 30  check (max_ref_age_s > 0),
  max_ref_move_pct  numeric not null default 2   check (max_ref_move_pct > 0),
  price_decimals    int     not null default 2,
  amount_decimals   int     not null default 5,
  updated_at        timestamptz not null default now()
);

create table if not exists mm_state (
  instrument  text primary key references mm_config(instrument) on delete cascade,
  ref_bid     numeric,
  ref_ask     numeric,
  ref_at      timestamptz,
  status      text not null default 'idle',   -- idle | quoting | paused | disabled
  reason      text,
  quoted_bid  numeric,
  quoted_ask  numeric,
  base_free   numeric,
  quote_free  numeric,
  updated_at  timestamptz not null default now()
);

-- internal tables: service_role and security-definer functions only
alter table mm_config enable row level security;
alter table mm_state  enable row level security;
revoke all on mm_config, mm_state from public, anon, authenticated;

insert into mm_config (instrument, ref_url)
select 'BTC_USDT', 'https://data-api.binance.vision/api/v3/ticker/bookTicker?symbol=BTCUSDT'
where exists (select 1 from instrument where name = 'BTC_USDT')
on conflict (instrument) do nothing;
insert into mm_state (instrument) select instrument from mm_config on conflict do nothing;

-- ── house accounts ──────────────────────────────────────────────────────────
-- type='MASTER' so the float is house money, not customer funding: reconcile()
-- and custody_funding_exposure stay clean. The taker exists only because the
-- engine refuses self-trades.
do $$
declare mk text; cur text;
begin
  foreach mk in array array['HOUSE_MM','HOUSE_MM_TAKER'] loop
    if not exists (select 1 from app_entity where pub_id = mk) then
      insert into app_entity(pub_id, external_id, type, status) values (mk, mk, 'MASTER', 'ACTIVE');
    end if;
    foreach cur in array array['USDT','BTC'] loop
      if not exists (select 1 from currency_account ca join app_entity e on e.id = ca.app_entity_id
                     where e.pub_id = mk and ca.currency_name = cur) then
        perform create_currency_account(mk, cur);
      end if;
    end loop;
    if not exists (select 1 from instrument_account ia join app_entity e on e.id = ia.app_entity_id
                   where e.pub_id = mk) then
      insert into instrument_account(app_entity_id) select id from app_entity where pub_id = mk;
    end if;
  end loop;
end $$;

create or replace function mm_account(maker_param text) returns text
  language sql stable security definer set search_path = public, pg_temp as $$
  select ia.pub_id from instrument_account ia join app_entity e on e.id = ia.app_entity_id
  where e.pub_id = maker_param limit 1;
$$;

create or replace function mm_free_balance(maker_param text, currency_param text) returns numeric
  language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((select ca.amount - ca.amount_reserved from currency_account ca
                   join app_entity e on e.id = ca.app_entity_id
                   where e.pub_id = maker_param and ca.currency_name = currency_param), 0);
$$;

-- ── reference price ─────────────────────────────────────────────────────────
-- Binance /api/v3/ticker/bookTicker -> (bid, ask); null unless it is a sane book.
create or replace function mm_decode_book_ticker(resp jsonb)
  returns table(bid numeric, ask numeric)
  language sql immutable as $$
  select b, a from (select (resp->>'bidPrice')::numeric b, (resp->>'askPrice')::numeric a) x
  where b > 0 and a >= b;
$$;

-- Record a new reference. A jump beyond max_ref_move_pct is stored but flagged,
-- so one outlier pauses quoting for a tick and a real move is accepted on the next.
create or replace function mm_set_reference(instrument_param text, bid_param numeric, ask_param numeric)
  returns text
  language plpgsql security definer set search_path = public, pg_temp as $$
declare cfg mm_config%rowtype; st mm_state%rowtype; move_pct numeric;
begin
  select * into cfg from mm_config where instrument = instrument_param;
  if not found then raise exception 'mm_not_configured: %', instrument_param; end if;
  if bid_param is null or ask_param is null or bid_param <= 0 or ask_param < bid_param then
    raise exception 'mm_bad_reference: bid % ask %', bid_param, ask_param;
  end if;
  select * into st from mm_state where instrument = instrument_param for update;
  if st.ref_bid is not null then
    move_pct := abs((bid_param + ask_param) - (st.ref_bid + st.ref_ask)) / (st.ref_bid + st.ref_ask) * 100;
  end if;
  update mm_state set ref_bid = bid_param, ref_ask = ask_param, ref_at = now(),
         reason = case when move_pct > cfg.max_ref_move_pct
                       then format('reference_jump %s%%', round(move_pct, 2)) end,
         updated_at = now()
   where instrument = instrument_param;
  return case when move_pct > cfg.max_ref_move_pct then 'jump' else 'ok' end;
end $$;

-- Fetch the Binance book over HTTP (the `http` extension, see 00060).
create or replace function mm_fetch_reference(instrument_param text) returns text
  language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare url text; resp extensions.http_response; b numeric; a numeric;
begin
  select ref_url into url from mm_config where instrument = instrument_param;
  perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '2000');
  resp := extensions.http_get(url);
  if resp.status <> 200 then raise exception 'http %', resp.status; end if;
  select bid, ask into b, a from mm_decode_book_ticker(resp.content::jsonb);
  return mm_set_reference(instrument_param, b, a);
exception when others then
  update mm_state set reason = 'fetch_failed: ' || left(sqlerrm, 200), updated_at = now()
   where instrument = instrument_param;
  return 'failed';
end $$;

-- Fresh anchor mid for an instrument, else its last trade. Used by the price band,
-- the perp index and margin valuation so the whole venue agrees on one price.
create or replace function reference_price(instrument_param text) returns numeric
  language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(
    (select (s.ref_bid + s.ref_ask) / 2 from mm_state s join mm_config c using (instrument)
      where s.instrument = instrument_param and c.enabled
        and s.ref_at > now() - make_interval(secs => c.max_ref_age_s)),
    (select t.price from trade t join instrument i on i.id = t.instrument_id
      where i.name = instrument_param order by t.created_at desc limit 1));
$$;

-- ── quoting ─────────────────────────────────────────────────────────────────
create or replace function mm_cancel_quotes(instrument_param text, maker_param text default 'HOUSE_MM')
  returns int
  language plpgsql security definer set search_path = public, pg_temp as $$
declare r record; n int := 0;
begin
  for r in
    select o.pub_id from trade_order o
    join instrument i on i.id = o.instrument_id
    join instrument_account ia on ia.id = o.instrument_account_id
    join app_entity e on e.id = ia.app_entity_id
    where e.pub_id = maker_param and i.name = instrument_param
      and o.status in ('OPEN','PARTIALLY_FILLED')
  loop
    perform submit_cancel(r.pub_id); n := n + 1;
  end loop;
  return n;
end $$;

-- Cancel-and-replace the ladder around the stored reference. Returns the status.
create or replace function mm_quote(instrument_param text) returns text
  language plpgsql security definer set search_path = public, pg_temp as $$
declare
  cfg mm_config%rowtype; st mm_state%rowtype; inst instrument%rowtype;
  acct text := mm_account('HOUSE_MM');
  mid numeric; res numeric; skew numeric; off numeric; px numeric; sz numeric; budget numeric;
  bids jsonb := '[]'; asks jsonb := '[]'; i int;
begin
  select * into cfg from mm_config where instrument = instrument_param;
  if not found then raise exception 'mm_not_configured: %', instrument_param; end if;
  select * into inst from instrument where name = instrument_param;
  perform mm_cancel_quotes(instrument_param);
  select * into st from mm_state where instrument = instrument_param for update;

  if not cfg.enabled or not inst.enabled then
    update mm_state set status = 'disabled', quoted_bid = null, quoted_ask = null, updated_at = now()
     where instrument = instrument_param;
    return 'disabled';
  end if;
  if st.ref_at is null or st.ref_at < now() - make_interval(secs => cfg.max_ref_age_s) then
    update mm_state set status = 'paused', reason = coalesce(reason, 'reference_stale'),
           quoted_bid = null, quoted_ask = null, updated_at = now()
     where instrument = instrument_param;
    return 'paused';
  end if;
  if st.reason like 'reference_jump%' then
    update mm_state set status = 'paused', quoted_bid = null, quoted_ask = null, updated_at = now()
     where instrument = instrument_param;
    return 'paused';
  end if;

  -- inventory skew: long -> shift quotes down to sell, short -> up to buy
  skew := greatest(-1, least(1,
            (mm_free_balance('HOUSE_MM', inst.base_currency) - cfg.target_base) / cfg.max_skew_base));
  mid := (st.ref_bid + st.ref_ask) / 2;
  res := mid * (1 - skew * cfg.skew_bps / 10000);

  budget := mm_free_balance('HOUSE_MM', inst.quote_currency);
  if skew < 1 then
    for i in 0 .. cfg.levels - 1 loop
      off := (cfg.half_spread_bps + i * cfg.level_step_bps) / 10000;
      px  := trunc(res * (1 - off), cfg.price_decimals);
      sz  := round(cfg.level_size * (1 + i * cfg.size_growth), cfg.amount_decimals);
      exit when px <= 0 or px * sz > budget;
      budget := budget - px * sz;
      bids := bids || jsonb_build_object('type','LIMIT','side','BUY','price',px,'amount',sz,'tif','GTC');
    end loop;
    -- a bid through a mispriced user ask fills here: that is the arbitrage leg
    if jsonb_array_length(bids) > 0 then perform submit_orders(acct, instrument_param, bids); end if;
  end if;

  budget := mm_free_balance('HOUSE_MM', inst.base_currency);
  if skew > -1 then
    for i in 0 .. cfg.levels - 1 loop
      off := (cfg.half_spread_bps + i * cfg.level_step_bps) / 10000;
      px  := round(ceil(res * (1 + off) * power(10::numeric, cfg.price_decimals)) / power(10::numeric, cfg.price_decimals),
                   cfg.price_decimals);
      sz  := round(cfg.level_size * (1 + i * cfg.size_growth), cfg.amount_decimals);
      exit when sz > budget;
      budget := budget - sz;
      asks := asks || jsonb_build_object('type','LIMIT','side','SELL','price',px,'amount',sz,'tif','GTC');
    end loop;
    if jsonb_array_length(asks) > 0 then perform submit_orders(acct, instrument_param, asks); end if;
  end if;

  update mm_state set
    status     = case when jsonb_array_length(bids) + jsonb_array_length(asks) > 0 then 'quoting' else 'paused' end,
    reason     = case when jsonb_array_length(bids) + jsonb_array_length(asks) > 0 then null else 'no_float' end,
    quoted_bid = (bids->0->>'price')::numeric,
    quoted_ask = (asks->0->>'price')::numeric,
    base_free  = mm_free_balance('HOUSE_MM', inst.base_currency) + coalesce((select sum((a->>'amount')::numeric) from jsonb_array_elements(asks) a), 0),
    quote_free = mm_free_balance('HOUSE_MM', inst.quote_currency) + coalesce((select sum((b->>'amount')::numeric * (b->>'price')::numeric) from jsonb_array_elements(bids) b), 0),
    updated_at = now()
  where instrument = instrument_param;
  return case when jsonb_array_length(bids) + jsonb_array_length(asks) > 0 then 'quoting' else 'paused' end;
end $$;

-- Demo only: the taker account takes a small slice of the maker's best quote.
create or replace function mm_demo_print(instrument_param text) returns boolean
  language plpgsql security definer set search_path = public, pg_temp as $$
declare st mm_state%rowtype; cfg mm_config%rowtype; buy boolean := random() < 0.5; sz numeric;
begin
  select * into cfg from mm_config where instrument = instrument_param;
  select * into st from mm_state where instrument = instrument_param;
  if st.status <> 'quoting' or (buy and st.quoted_ask is null) or (not buy and st.quoted_bid is null) then
    return false;
  end if;
  sz := round(cfg.level_size * (0.1 + random() * 0.4), cfg.amount_decimals);
  perform submit_orders(mm_account('HOUSE_MM_TAKER'), instrument_param, jsonb_build_array(jsonb_build_object(
    'type','LIMIT','side', case when buy then 'BUY' else 'SELL' end,
    'price', case when buy then st.quoted_ask else st.quoted_bid end,
    'amount', sz, 'tif','IOC')));
  return true;
exception when others then
  return false;   -- taker out of float: skip the print, the maker is unaffected
end $$;

-- One pass over every configured pair; pg_cron runs it every 5 seconds.
create or replace function mm_tick() returns int
  language plpgsql security definer set search_path = public, pg_temp as $$
declare c mm_config%rowtype; n int := 0;
begin
  if not pg_try_advisory_xact_lock(hashtext('mm_tick')) then return 0; end if;
  for c in select * from mm_config order by instrument loop
    begin
      if c.enabled then perform mm_fetch_reference(c.instrument); end if;
      if mm_quote(c.instrument) = 'quoting' then
        n := n + 1;
        if c.demo_prints and random() < 0.3 then perform mm_demo_print(c.instrument); end if;
      end if;
    exception when others then
      -- the failed pass rolled back its cancels too: pull the old quotes explicitly
      -- rather than leave them resting around an old price
      begin perform mm_cancel_quotes(c.instrument); exception when others then null; end;
      update mm_state set status = 'paused', reason = 'quote_failed: ' || left(sqlerrm, 200),
             quoted_bid = null, quoted_ask = null, updated_at = now() where instrument = c.instrument;
    end;
  end loop;
  return n;
end $$;

-- ── point the venue's prices at the anchor ──────────────────────────────────
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
    select reference_price(name) into ref from instrument where id = iid;
    if ref is not null and abs(price_param - ref) / ref * 100 > r.price_band_pct then
      raise exception 'risk_price_band: % beyond % pct band of reference %', price_param, r.price_band_pct, ref;
    end if;
  end if;
end $$;

create or replace function _margin_price(cur text) returns numeric
  language sql stable security definer set search_path = public, pg_temp as $$
  select case when cur = 'USDT' then 1 else coalesce(reference_price(cur || '_USDT'), 0) end;
$$;

create or replace function update_perp_mark() returns int
  language plpgsql security definer set search_path = public, pg_temp as $$
declare m perp_market%rowtype; px numeric; n int := 0;
begin
  for m in select * from perp_market loop
    px := reference_price(m.index_symbol);
    if px is not null then
      update perp_market set mark_price = px, updated_at = now() where symbol = m.symbol; n := n + 1;
    end if;
  end loop;
  return n;
end $$;

-- ── operator controls (back-office, RBAC) ───────────────────────────────────
-- The cron job is armed while any pair is enabled, so CI and self-hosts that never
-- enable the maker have no background trading.
create or replace function _mm_sync_schedule() returns void
  language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if exists (select 1 from mm_config where enabled) then
    perform cron.schedule('mm-tick', '5 seconds', 'select mm_tick()');
  else
    begin perform cron.unschedule('mm-tick'); exception when others then null; end;
  end if;
exception when undefined_function or invalid_schema_name then
  raise warning 'pg_cron unavailable: market maker will not tick on its own';
end $$;

create or replace function admin_mm_set_enabled(
    instrument_param text, enabled_param boolean, demo_prints_param boolean default false)
  returns void language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform require_admin_permission('market.write');
  update mm_config set enabled = enabled_param, demo_prints = enabled_param and demo_prints_param,
         updated_at = now() where instrument = instrument_param;
  if not found then raise exception 'mm_not_configured: %', instrument_param; end if;
  if not enabled_param then perform mm_quote(instrument_param); end if;   -- pull quotes now
  perform _mm_sync_schedule();
  insert into admin_audit_log(action, target, detail)
    values ('MM_SET_ENABLED', instrument_param,
            jsonb_build_object('enabled', enabled_param, 'demo_prints', enabled_param and demo_prints_param));
end $$;

create or replace function admin_mm_configure(instrument_param text, settings jsonb)
  returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare k text;
begin
  perform require_admin_permission('market.write');
  for k in select jsonb_object_keys(settings) loop
    if k not in ('half_spread_bps','level_step_bps','levels','level_size','size_growth','target_base',
                 'max_skew_base','skew_bps','max_ref_age_s','max_ref_move_pct') then
      raise exception 'mm_unknown_setting: %', k;
    end if;
  end loop;
  update mm_config c set
    half_spread_bps  = coalesce((settings->>'half_spread_bps')::numeric,  c.half_spread_bps),
    level_step_bps   = coalesce((settings->>'level_step_bps')::numeric,   c.level_step_bps),
    levels           = coalesce((settings->>'levels')::int,               c.levels),
    level_size       = coalesce((settings->>'level_size')::numeric,       c.level_size),
    size_growth      = coalesce((settings->>'size_growth')::numeric,      c.size_growth),
    target_base      = coalesce((settings->>'target_base')::numeric,      c.target_base),
    max_skew_base    = coalesce((settings->>'max_skew_base')::numeric,    c.max_skew_base),
    skew_bps         = coalesce((settings->>'skew_bps')::numeric,         c.skew_bps),
    max_ref_age_s    = coalesce((settings->>'max_ref_age_s')::int,        c.max_ref_age_s),
    max_ref_move_pct = coalesce((settings->>'max_ref_move_pct')::numeric, c.max_ref_move_pct),
    updated_at = now()
  where c.instrument = instrument_param;
  if not found then raise exception 'mm_not_configured: %', instrument_param; end if;
  insert into admin_audit_log(action, target, detail) values ('MM_CONFIGURE', instrument_param, settings);
end $$;

-- Move house money into (amount > 0) or out of (amount < 0) a house float.
create or replace function admin_mm_fund(
    currency_param text, amount_param numeric, account_param text default 'HOUSE_MM')
  returns numeric language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform require_admin_permission('market.write');
  if account_param not in ('HOUSE_MM','HOUSE_MM_TAKER') then raise exception 'mm_unknown_account: %', account_param; end if;
  if amount_param is null or amount_param = 0 then raise exception 'mm_fund_amount_required'; end if;
  if amount_param > 0 then
    perform process_transfer('DEPOSIT', 'MASTER', amount_param, currency_param, account_param,
                             'mm float', 'fund house market maker', null);
  else
    if -amount_param > mm_free_balance(account_param, currency_param) then
      raise exception 'mm_fund_exceeds_free_float: disable the maker first to release quotes';
    end if;
    perform process_transfer('WITHDRAWAL', account_param, -amount_param, currency_param, 'MASTER',
                             'mm float', 'defund house market maker', null);
  end if;
  insert into admin_audit_log(action, target, detail)
    values ('MM_FUND', account_param, jsonb_build_object('currency', currency_param, 'amount', amount_param));
  return mm_free_balance(account_param, currency_param);
end $$;

create or replace function admin_mm_status() returns jsonb
  language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform require_admin_permission('market.read');
  return coalesce((select jsonb_agg(to_jsonb(c) || jsonb_build_object(
      'ref_bid', s.ref_bid, 'ref_ask', s.ref_ask, 'ref_at', s.ref_at, 'status', s.status,
      'reason', s.reason, 'quoted_bid', s.quoted_bid, 'quoted_ask', s.quoted_ask,
      'base_free', s.base_free, 'quote_free', s.quote_free, 'state_at', s.updated_at)
      order by c.instrument)
    from mm_config c join mm_state s using (instrument)), '[]'::jsonb);
end $$;

revoke execute on function mm_account(text), mm_free_balance(text,text), mm_decode_book_ticker(jsonb),
  mm_set_reference(text,numeric,numeric), mm_fetch_reference(text), mm_cancel_quotes(text,text),
  mm_quote(text), mm_demo_print(text), mm_tick(), _mm_sync_schedule(), reference_price(text)
  from public, anon, authenticated;
grant execute on function mm_account(text), mm_free_balance(text,text), mm_decode_book_ticker(jsonb),
  mm_set_reference(text,numeric,numeric), mm_fetch_reference(text), mm_cancel_quotes(text,text),
  mm_quote(text), mm_demo_print(text), mm_tick(), reference_price(text)
  to service_role;
revoke execute on function admin_mm_set_enabled(text,boolean,boolean), admin_mm_configure(text,jsonb),
  admin_mm_fund(text,numeric,text), admin_mm_status() from public, anon;
grant execute on function admin_mm_set_enabled(text,boolean,boolean), admin_mm_configure(text,jsonb),
  admin_mm_fund(text,numeric,text), admin_mm_status() to authenticated, service_role;
