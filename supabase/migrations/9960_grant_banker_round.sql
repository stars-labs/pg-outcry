-- Fixes found driving the live demo: a logged-in user could stake / open a perp
-- (the writes succeeded — balances moved) but their position views came back empty
-- or errored. Two distinct causes, both in the derivative migrations:
--
-- 1) banker_round() EXECUTE. 9900_lockdown revokes EXECUTE on every public function
--    from anon/authenticated and re-grants only a whitelist; banker_round() was left
--    off it. my_stakes is security_invoker and calls banker_round() to show the live
--    pending reward, so reading it raised "permission denied for function
--    banker_round". It is an IMMUTABLE pure rounding helper that reads nothing, so
--    granting EXECUTE is safe.
--
-- 2) Public market tables had RLS enabled with NO policy. stake_pool and perp_market
--    hold public market data (APR / total staked / mark price / funding) and are
--    joined by the security_invoker views my_stakes and my_perp. With RLS on and no
--    SELECT policy, those joins returned zero rows for authenticated, so positions
--    never showed even though stake_position / perp_position had the row. (The
--    stake_pools / perp_markets *views* worked because they're security-definer and
--    bypass RLS.) Add public read policies. margin_config is read only via
--    security-definer views (margin_terms / my_margin_health), so it needs no policy.
--
-- Numbered >9900 so the lockdown's revoke loop has already run.

grant execute on function banker_round(numeric, integer) to anon, authenticated;

drop policy if exists read_stake_pool on stake_pool;
create policy read_stake_pool on stake_pool for select to anon, authenticated using (true);

drop policy if exists read_perp_market on perp_market;
create policy read_perp_market on perp_market for select to anon, authenticated using (true);
