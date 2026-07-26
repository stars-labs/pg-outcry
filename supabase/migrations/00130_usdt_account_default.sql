-- Every account gets a USDT wallet.
--
-- The vendored engine's create_app_entity opens an EUR currency account, which was
-- right when the venue quoted EUR. Now that everything settles in USDT, a fresh
-- account had no USDT wallet and any funding or trade failed. Rather than editing
-- the generated engine file, attach the USDT account on app_entity insert — that
-- covers both auth signups and engine-created entities.

create or replace function ensure_usdt_account()
  returns trigger
  language plpgsql
  security definer
  set search_path = public, pg_temp
as $$
begin
  begin
    perform create_currency_account(new.pub_id, 'USDT');
  exception when others then null;   -- already exists, or currency not seeded yet
  end;
  return new;
end $$;

drop trigger if exists trg_ensure_usdt_account on app_entity;
create trigger trg_ensure_usdt_account
  after insert on app_entity
  for each row execute function ensure_usdt_account();

revoke execute on function ensure_usdt_account() from public, anon, authenticated;

-- backfill existing entities
do $$
declare e record;
begin
  for e in select pub_id from app_entity loop
    begin perform create_currency_account(e.pub_id, 'USDT'); exception when others then null; end;
  end loop;
end $$;
