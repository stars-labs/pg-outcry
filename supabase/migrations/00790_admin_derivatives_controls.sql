-- Admin controls for the feature surface added after the core back-office:
-- staking pools/config, spot-margin terms, perp market parameters, and manual
-- maintenance job triggers. Kept service_role-only.

create or replace function admin_set_stake_pool(
    currency_param text,
    apr_param numeric,
    unbond_seconds_param int default null)
  returns void
  language plpgsql
  security definer
  set search_path = public, pg_temp
as $$
begin
  if coalesce(trim(currency_param), '') = '' then raise exception 'currency_required'; end if;
  if apr_param is null or apr_param < 0 then raise exception 'invalid_apr'; end if;
  perform 1 from currency where name = currency_param;
  if not found then raise exception 'unknown_currency: %', currency_param; end if;

  if exists (select 1 from stake_pool where currency = currency_param) then
    perform _stake_update_pool(currency_param);
    update stake_pool set apr = apr_param, updated_at = now() where currency = currency_param;
  else
    insert into stake_pool(currency, apr) values (currency_param, apr_param);
  end if;

  if unbond_seconds_param is not null then
    if unbond_seconds_param < 0 then raise exception 'invalid_unbond_seconds'; end if;
    insert into stake_config(id, unbond_seconds) values (1, unbond_seconds_param)
      on conflict (id) do update set unbond_seconds = excluded.unbond_seconds;
  end if;

  insert into admin_audit_log(action, target, detail)
    values ('SET_STAKE_POOL', currency_param,
            jsonb_build_object('apr', apr_param, 'unbond_seconds', unbond_seconds_param));
end $$;

create or replace function admin_set_margin_terms(
    max_leverage_param numeric,
    maintenance_ratio_param numeric,
    borrow_apr_param numeric)
  returns void
  language plpgsql
  security definer
  set search_path = public, pg_temp
as $$
declare e bigint;
begin
  if max_leverage_param is null or max_leverage_param <= 1 then raise exception 'invalid_max_leverage'; end if;
  if maintenance_ratio_param is null or maintenance_ratio_param <= 0 or maintenance_ratio_param >= 1 then
    raise exception 'invalid_maintenance_ratio';
  end if;
  if borrow_apr_param is null or borrow_apr_param < 0 then raise exception 'invalid_borrow_apr'; end if;

  -- Accrue existing loans under the old APR before changing the global term.
  for e in select distinct app_entity_id from margin_loan where principal + accrued > 0 loop
    perform _margin_accrue(e);
  end loop;

  insert into margin_config(id, max_leverage, maintenance_ratio, borrow_apr)
    values (1, max_leverage_param, maintenance_ratio_param, borrow_apr_param)
  on conflict (id) do update
    set max_leverage = excluded.max_leverage,
        maintenance_ratio = excluded.maintenance_ratio,
        borrow_apr = excluded.borrow_apr;

  insert into admin_audit_log(action, target, detail)
    values ('SET_MARGIN_TERMS', 'margin_config',
            jsonb_build_object('max_leverage', max_leverage_param,
                               'maintenance_ratio', maintenance_ratio_param,
                               'borrow_apr', borrow_apr_param));
end $$;

create or replace function admin_set_perp_market(
    symbol_param text,
    index_symbol_param text default null,
    margin_currency_param text default null,
    mark_price_param numeric default null,
    funding_rate_param numeric default null,
    max_leverage_param numeric default null,
    maintenance_ratio_param numeric default null)
  returns void
  language plpgsql
  security definer
  set search_path = public, pg_temp
as $$
declare existing perp_market%rowtype;
begin
  if coalesce(trim(symbol_param), '') = '' then raise exception 'symbol_required'; end if;
  if mark_price_param is not null and mark_price_param <= 0 then raise exception 'invalid_mark_price'; end if;
  if max_leverage_param is not null and max_leverage_param <= 1 then raise exception 'invalid_max_leverage'; end if;
  if maintenance_ratio_param is not null and (maintenance_ratio_param <= 0 or maintenance_ratio_param >= 1) then
    raise exception 'invalid_maintenance_ratio';
  end if;

  select * into existing from perp_market where symbol = symbol_param;
  if not found and coalesce(trim(index_symbol_param), '') = '' then
    raise exception 'index_symbol_required_for_new_market';
  end if;

  if index_symbol_param is not null then
    perform 1 from instrument where name = index_symbol_param;
    if not found then raise exception 'unknown_index_symbol: %', index_symbol_param; end if;
  end if;
  if margin_currency_param is not null then
    perform 1 from currency where name = margin_currency_param;
    if not found then raise exception 'unknown_margin_currency: %', margin_currency_param; end if;
  end if;

  insert into perp_market(symbol, index_symbol, margin_currency, mark_price, funding_rate, max_leverage, maintenance_ratio, updated_at)
    values (symbol_param,
            coalesce(index_symbol_param, existing.index_symbol),
            coalesce(margin_currency_param, existing.margin_currency, 'EUR'),
            mark_price_param,
            coalesce(funding_rate_param, existing.funding_rate, 0),
            coalesce(max_leverage_param, existing.max_leverage, 10),
            coalesce(maintenance_ratio_param, existing.maintenance_ratio, 0.05),
            now())
  on conflict (symbol) do update
    set index_symbol = coalesce(excluded.index_symbol, perp_market.index_symbol),
        margin_currency = coalesce(excluded.margin_currency, perp_market.margin_currency),
        mark_price = coalesce(excluded.mark_price, perp_market.mark_price),
        funding_rate = excluded.funding_rate,
        max_leverage = excluded.max_leverage,
        maintenance_ratio = excluded.maintenance_ratio,
        updated_at = now();

  insert into admin_audit_log(action, target, detail)
    values ('SET_PERP_MARKET', symbol_param,
            jsonb_build_object('index_symbol', index_symbol_param,
                               'margin_currency', margin_currency_param,
                               'mark_price', mark_price_param,
                               'funding_rate', funding_rate_param,
                               'max_leverage', max_leverage_param,
                               'maintenance_ratio', maintenance_ratio_param));
end $$;

create or replace function admin_run_derivative_jobs(
    update_marks boolean default true,
    apply_funding boolean default false,
    check_perps boolean default true,
    check_margin boolean default true,
    process_unbonds boolean default true)
  returns jsonb
  language plpgsql
  security definer
  set search_path = public, pg_temp
as $$
declare
  mark_count int := null;
  funding_count int := null;
  perp_liq_count int := null;
  margin_liq_count int := null;
  unbond_count int := null;
begin
  if update_marks then mark_count := update_perp_mark(); end if;
  if apply_funding then funding_count := apply_perp_funding(); end if;
  if check_perps then perp_liq_count := check_perp_liquidations(); end if;
  if check_margin then margin_liq_count := check_margin_liquidations(); end if;
  if process_unbonds then unbond_count := process_unbonding(); end if;

  insert into admin_audit_log(action, target, detail)
    values ('RUN_DERIVATIVE_JOBS', 'derivatives',
            jsonb_build_object('update_marks', mark_count,
                               'apply_funding', funding_count,
                               'check_perps', perp_liq_count,
                               'check_margin', margin_liq_count,
                               'process_unbonds', unbond_count));

  return jsonb_build_object('update_marks', mark_count,
                            'apply_funding', funding_count,
                            'check_perps', perp_liq_count,
                            'check_margin', margin_liq_count,
                            'process_unbonds', unbond_count);
end $$;

grant execute on function
  admin_set_stake_pool(text,numeric,int),
  admin_set_margin_terms(numeric,numeric,numeric),
  admin_set_perp_market(text,text,text,numeric,numeric,numeric,numeric),
  admin_run_derivative_jobs(boolean,boolean,boolean,boolean,boolean)
  to service_role;

revoke execute on function
  admin_set_stake_pool(text,numeric,int),
  admin_set_margin_terms(numeric,numeric,numeric),
  admin_set_perp_market(text,text,text,numeric,numeric,numeric,numeric),
  admin_run_derivative_jobs(boolean,boolean,boolean,boolean,boolean)
  from public, anon, authenticated;
