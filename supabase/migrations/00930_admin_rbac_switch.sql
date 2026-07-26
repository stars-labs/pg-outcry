-- Put the back-office "test-open" behaviour behind a config flag.
--
-- 00890_admin_rbac shipped an intentionally open console: every signed-in user
-- got every permission, and the role tables were decorative. That is fine for a
-- public demo and unacceptable for anything holding real value. Tightening it
-- should be a one-row config change, not a function rewrite — so the open path
-- now lives behind admin_config.open_access, and the closed path resolves
-- permissions through admin_operator_role -> admin_role_permission for real.
--
-- Default stays OPEN so the hosted demo keeps working; flip with
--   select admin_set_open_access(false);
-- Bootstrap an operator BEFORE closing (while open, any signed-in user may grant;
-- service_role can always grant):
--   select admin_grant_operator_role_by_email('ops@example.com', 'super_admin');

create table if not exists admin_config (
  id          boolean primary key default true check (id),
  open_access boolean not null default true,
  updated_at  timestamptz not null default now()
);
insert into admin_config default values on conflict do nothing;

alter table admin_config enable row level security;
drop policy if exists read_admin_config on admin_config;
create policy read_admin_config on admin_config for select to authenticated using (true);
grant select on admin_config to authenticated, service_role;

create or replace function admin_open_access()
  returns boolean
  language sql
  stable
  security definer
  set search_path = public, pg_temp
as $$
  select coalesce((select open_access from admin_config where id), true)
$$;

-- Real permission resolution: service_role is root; otherwise the caller's granted
-- roles decide, unless the deployment is still in open (demo) mode.
create or replace function admin_has_permission(permission_param text)
  returns boolean
  language plpgsql
  stable
  security definer
  set search_path = public, auth, pg_temp
as $$
begin
  if auth.role() = 'service_role' then
    return true;
  end if;
  if auth.uid() is null then
    return false;
  end if;
  if admin_open_access() then
    -- demo mode: any signed-in user gets any defined permission
    return exists (select 1 from admin_permission where name = permission_param);
  end if;
  return exists (
    select 1
    from admin_operator_role o
    join admin_role_permission rp on rp.role = o.role
    where o.user_id = auth.uid()
      and rp.permission = permission_param);
end $$;

create or replace function admin_has_any_permission(permissions text[])
  returns boolean
  language sql
  stable
  security definer
  set search_path = public, auth, pg_temp
as $$
  select case
    when auth.role() = 'service_role' then true
    when auth.uid() is null then false
    when admin_open_access() then
      exists (select 1 from admin_permission where name = any(permissions))
    else exists (
      select 1 from admin_operator_role o
      join admin_role_permission rp on rp.role = o.role
      where o.user_id = auth.uid() and rp.permission = any(permissions))
  end
$$;

create or replace function current_admin_permissions()
  returns text[]
  language sql
  stable
  security definer
  set search_path = public, auth, pg_temp
as $$
  select case
    when auth.role() = 'service_role' or (auth.uid() is not null and admin_open_access())
      then coalesce((select array_agg(name order by name) from admin_permission), '{}'::text[])
    when auth.uid() is null then '{}'::text[]
    else coalesce((
      select array_agg(distinct rp.permission order by rp.permission)
      from admin_operator_role o
      join admin_role_permission rp on rp.role = o.role
      where o.user_id = auth.uid()), '{}'::text[])
  end
$$;

-- Roles reported in the audit trail must match the effective model too.
create or replace function admin_actor_roles()
  returns text[]
  language sql
  stable
  security definer
  set search_path = public, auth, pg_temp
as $$
  with explicit as (
    select array_agg(role order by role) as roles
    from admin_operator_role
    where user_id = auth.uid()
  )
  select case
    when auth.role() = 'service_role' then array['service_role']::text[]
    when auth.uid() is null then '{}'::text[]
    else coalesce((select roles from explicit),
                  case when admin_open_access() then array['open_access']::text[]
                       else '{}'::text[] end)
  end
$$;

create or replace function admin_set_open_access(open_param boolean)
  returns boolean
  language plpgsql
  security definer
  set search_path = public, pg_temp
as $$
begin
  perform require_admin_permission('rbac.write');
  update admin_config set open_access = open_param, updated_at = now() where id;
  insert into admin_audit_log(action, target, detail)
    values ('SET_ADMIN_OPEN_ACCESS', 'admin_config',
            jsonb_build_object('open_access', open_param));
  return open_param;
end $$;

revoke execute on function
  admin_open_access(), admin_has_permission(text), admin_has_any_permission(text[]),
  current_admin_permissions(), admin_actor_roles(), admin_set_open_access(boolean)
  from public, anon;
grant execute on function
  admin_open_access(), admin_has_permission(text), admin_has_any_permission(text[]),
  current_admin_permissions(), admin_actor_roles(), admin_set_open_access(boolean)
  to authenticated, service_role;

comment on table admin_config is
  'Back-office switches. open_access=true means any signed-in user has full admin permissions (demo mode); false enforces admin_operator_role-based RBAC.';
