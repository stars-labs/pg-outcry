-- Per-user API keys (pure-SQL, for bots / market-makers).
--
-- A client creates a key while logged in (gets the plaintext secret ONCE), then
-- exchanges (key_id, secret) for a short-lived Supabase JWT minted in-DB with
-- pgcrypto HMAC. The bot uses that JWT as a normal bearer token, so every
-- existing RLS policy and RPC works unchanged — no separate auth plane.
--
-- Numbered >9900 so 9900_lockdown (which revokes+regrants all functions) does
-- not strip these grants.

create table if not exists api_key (
  id            bigint generated always as identity primary key,
  app_entity_id bigint not null references app_entity(id) on delete cascade,
  key_id        text unique not null default ('ock_' || encode(extensions.gen_random_bytes(9), 'hex')),
  secret_hash   text not null,                      -- sha256(hex) of the plaintext secret
  label         text,
  scopes        text[] not null default '{trade}',  -- informational (read/trade/withdraw)
  created_at    timestamptz not null default now(),
  last_used_at  timestamptz,
  revoked_at    timestamptz
);
create index if not exists api_key_entity_idx on api_key(app_entity_id);

alter table api_key enable row level security;
drop policy if exists own_api_key on api_key;
create policy own_api_key on api_key for select to authenticated
  using (app_entity_id = current_app_entity_id());

-- own keys without the secret hash
create or replace view api_keys as
  select key_id, label, scopes, created_at, last_used_at, revoked_at
  from api_key;
alter view api_keys set (security_invoker = on);

-- base64url(bytea): + -> -, / -> _, strip '=' and any newline encode() inserts
create or replace function _b64url(data bytea) returns text
  language sql immutable as $$ select translate(encode(data, 'base64'), E'+/=\n', '-_'); $$;

-- create a key; returns the plaintext secret ONCE (never retrievable again)
create or replace function create_api_key(label_param text default null,
                                          scopes_param text[] default '{trade}')
  returns json language plpgsql security definer set search_path = public, pg_temp
as $$
declare eid bigint := current_app_entity_id(); secret text; r api_key%rowtype;
begin
  if eid is null then raise exception 'not_authenticated'; end if;
  secret := 'ocs_' || encode(extensions.gen_random_bytes(24), 'hex');
  insert into api_key(app_entity_id, secret_hash, label, scopes)
    values (eid, encode(extensions.digest(secret, 'sha256'), 'hex'), label_param, scopes_param)
    returning * into r;
  return json_build_object('key_id', r.key_id, 'secret', secret, 'scopes', r.scopes,
    'note', 'store the secret now — it is not retrievable later');
end $$;

create or replace function revoke_api_key(key_id_param text)
  returns boolean language plpgsql security definer set search_path = public, pg_temp
as $$
declare eid bigint := current_app_entity_id(); n int;
begin
  if eid is null then raise exception 'not_authenticated'; end if;
  update api_key set revoked_at = now()
    where key_id = key_id_param and app_entity_id = eid and revoked_at is null;
  get diagnostics n = row_count;
  return n > 0;
end $$;

-- exchange (key_id, secret) for a short-lived JWT (HS256, signed with the
-- project jwt secret). Callable by anon: the bot starts from the anon key.
create or replace function api_key_login(key_id_param text, secret_param text,
                                         ttl_seconds int default 900)
  returns json language plpgsql security definer set search_path = public, pg_temp
as $$
declare
  k api_key%rowtype; uid uuid; jwt_secret text;
  header text; payload text; body text; sig text; jwt text; iat bigint; exp bigint;
begin
  select * into k from api_key where key_id = key_id_param and revoked_at is null;
  if not found or k.secret_hash <> encode(extensions.digest(secret_param, 'sha256'), 'hex') then
    raise exception 'invalid_api_key';
  end if;
  select user_id into uid from app_user where app_entity_id = k.app_entity_id limit 1;
  if uid is null then raise exception 'no_user_for_key'; end if;

  jwt_secret := current_setting('app.settings.jwt_secret', true);
  if jwt_secret is null or jwt_secret = '' then raise exception 'jwt_secret_unavailable'; end if;
  ttl_seconds := least(greatest(ttl_seconds, 60), 86400);   -- clamp 1min..1day
  iat := extract(epoch from now())::bigint;
  exp := iat + ttl_seconds;

  header  := _b64url(convert_to('{"alg":"HS256","typ":"JWT"}', 'utf8'));
  payload := _b64url(convert_to(json_build_object(
               'role', 'authenticated', 'aud', 'authenticated',
               'sub', uid::text, 'iat', iat, 'exp', exp)::text, 'utf8'));
  body := header || '.' || payload;
  sig  := _b64url(extensions.hmac(body, jwt_secret, 'sha256'));
  jwt  := body || '.' || sig;

  update api_key set last_used_at = now() where id = k.id;
  return json_build_object('access_token', jwt, 'token_type', 'bearer', 'expires_in', ttl_seconds);
end $$;

grant select on api_keys to authenticated;
grant execute on function create_api_key(text, text[]), revoke_api_key(text) to authenticated;
grant execute on function api_key_login(text, text, int) to anon, authenticated;
-- Supabase default privileges auto-grant new public functions to anon; revoke the
-- ones that must be authenticated-only (api_key_login stays anon-callable by design).
revoke execute on function create_api_key(text, text[]), revoke_api_key(text) from public, anon;
