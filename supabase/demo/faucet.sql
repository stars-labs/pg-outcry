-- DEMO ONLY — not part of the product migrations. Lets a logged-in demo user
-- self-credit play funds so they can trade on a public demo. Do NOT apply to a
-- real deployment. Apply manually: psql "$DB_URL" -f supabase/demo/faucet.sql
create or replace function demo_faucet()
  returns text language plpgsql security definer set search_path = public, pg_temp
as $$
declare eid bigint := current_app_entity_id(); pub text;
begin
  if eid is null then raise exception 'not_authenticated'; end if;
  select pub_id into pub from app_entity where id = eid;
  begin perform create_currency_account(pub, 'BTC'); exception when others then null; end;
  if (select coalesce(max(amount),0) from currency_account where app_entity_id=eid and currency_name='EUR') < 1000 then
    perform process_transfer('DEPOSIT','MASTER',100000,'EUR',pub,'demo','faucet',null);
  end if;
  if (select coalesce(max(amount),0) from currency_account where app_entity_id=eid and currency_name='BTC') < 10 then
    perform process_transfer('DEPOSIT','MASTER',1000,'BTC',pub,'demo','faucet',null);
  end if;
  return 'funded';
end $$;
revoke execute on function demo_faucet() from public, anon;
grant execute on function demo_faucet() to authenticated;
