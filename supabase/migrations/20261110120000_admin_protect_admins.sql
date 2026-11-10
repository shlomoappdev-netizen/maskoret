-- Admins can't act against the main admin (or each other).
--
-- 20261110090000_admin_permissions made appointing admins and changing permissions owner-only, but the user-management
-- functions only checked that an admin doesn't act on themself: an admin with the "users" permission could still delete,
-- block or sign out the main admin's account, or delete / take over the households they are in.
-- Now, when the target is an admin (the main admin included) or a household with an admin in it, only the main admin
-- may do it. Everyone else is unchanged.

create function private.admin_may_touch_user(target uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select private.is_admin_owner() or not exists (select 1 from private.admins where user_id = target);
$$;

create function private.admin_may_touch_household(hid uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select private.is_admin_owner()
      or not exists (select 1 from public.household_members m join private.admins a on a.user_id = m.user_id
                     where m.household_id = hid);
$$;

revoke all on function private.admin_may_touch_user(uuid), private.admin_may_touch_household(uuid) from public;
grant execute on function private.admin_may_touch_user(uuid), private.admin_may_touch_household(uuid) to authenticated;

create or replace function public.admin_delete_user(target uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare r record;
begin
  if not private.admin_can('users') then raise exception 'admins only' using errcode = '42501'; end if;
  if target = auth.uid() then raise exception 'cannot delete yourself here'; end if;
  if not private.admin_may_touch_user(target) then
    raise exception 'only the main admin can do this to an admin' using errcode = '42501';
  end if;
  for r in select household_id from public.household_members where user_id = target loop
    perform private.leave(r.household_id, target);
  end loop;
  delete from auth.users where id = target;
end;
$$;

create or replace function public.admin_set_blocked(target uuid, p_blocked boolean) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not private.admin_can('users') then raise exception 'admins only' using errcode = '42501'; end if;
  if target = auth.uid() then raise exception 'cannot block yourself'; end if;
  if not private.admin_may_touch_user(target) then
    raise exception 'only the main admin can do this to an admin' using errcode = '42501';
  end if;
  update auth.users set banned_until = case when p_blocked then 'infinity'::timestamptz else null end where id = target;
  if p_blocked then delete from auth.sessions where user_id = target; end if;
end;
$$;

create or replace function public.admin_sign_out_user(target uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not (private.admin_can('users') or private.admin_can('support')) then
    raise exception 'admins only' using errcode = '42501';
  end if;
  if not private.admin_may_touch_user(target) then
    raise exception 'only the main admin can do this to an admin' using errcode = '42501';
  end if;
  delete from auth.sessions where user_id = target;
end;
$$;

create or replace function public.admin_delete_household(hid uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not private.admin_can('users') then raise exception 'admins only' using errcode = '42501'; end if;
  if not private.admin_may_touch_household(hid) then
    raise exception 'only the main admin can do this to an admin''s household' using errcode = '42501';
  end if;
  delete from public.households where id = hid;
end;
$$;

create or replace function public.admin_remove_member(hid uuid, member uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not private.admin_can('users') then raise exception 'admins only' using errcode = '42501'; end if;
  if not private.admin_may_touch_household(hid) then
    raise exception 'only the main admin can do this to an admin''s household' using errcode = '42501';
  end if;
  perform private.leave(hid, member);
end;
$$;

create or replace function public.admin_transfer_owner(hid uuid, new_owner uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not private.admin_can('users') then raise exception 'admins only' using errcode = '42501'; end if;
  if not private.admin_may_touch_household(hid) then
    raise exception 'only the main admin can do this to an admin''s household' using errcode = '42501';
  end if;
  if not exists (select 1 from public.household_members where household_id = hid and user_id = new_owner) then
    raise exception 'not a member';
  end if;
  update public.household_members set role = 'member' where household_id = hid and role = 'owner';
  update public.household_members set role = 'owner' where household_id = hid and user_id = new_owner;
end;
$$;
