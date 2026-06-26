-- Public market/reference data is readable by anyone (anon + authenticated).
--
-- Hosted Supabase enables RLS on public tables by default; locally RLS was off,
-- so these read fine locally but returned empty over the API on hosted. Make both
-- environments consistent: RLS ON + an explicit permissive SELECT policy, so the
-- order book / tape / instrument list are publicly readable either way (and the
-- Supabase linter stays happy — no RLS-disabled public tables).
--
-- Runs after 9640 (which recreates `trade` as partitioned) so the policy sticks.

do $$
declare t text;
begin
  foreach t in array array['price_level','trade','instrument','currency','fee'] loop
    execute format('alter table %I enable row level security', t);
    execute format('drop policy if exists public_read on %I', t);
    execute format('create policy public_read on %I for select to anon, authenticated using (true)', t);
  end loop;
end $$;
