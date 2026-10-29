-- Admin screen: the app's owner sees every account and household (not their financial data)
-- and can delete an account or a household. Only the verified <admin email> account is an admin.

create function private.is_admin() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from auth.users u
                 where u.id = (select auth.uid())
                   and lower(u.email) = '<admin email>'
                   and u.email_confirmed_at is not null);
$$;
revoke all on function private.is_admin() from public;
grant execute on function private.is_admin() to authenticated;

create function public.am_i_admin() returns boolean
language sql stable security definer set search_path = '' as $$
  select private.is_admin();
$$;

-- Every account with its households, and every household with its size — never the data itself.
create function public.admin_overview() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  if not private.is_admin() then raise exception 'admins only' using errcode = '42501'; end if;
  return jsonb_build_object(
    'users', (select coalesce(jsonb_agg(jsonb_build_object(
        'id', u.id, 'email', u.email,
        'display_name', coalesce(p.display_name, ''),
        'created_at', u.created_at, 'last_sign_in_at', u.last_sign_in_at,
        'confirmed', u.email_confirmed_at is not null,
        'households', (select coalesce(jsonb_agg(jsonb_build_object('id', h.id, 'name', h.name, 'role', m.role)
                                                 order by m.joined_at), '[]'::jsonb)
                       from public.household_members m join public.households h on h.id = m.household_id
                       where m.user_id = u.id))
        order by u.created_at), '[]'::jsonb)
      from auth.users u left join public.profiles p on p.id = u.id),
    'households', (select coalesce(jsonb_agg(jsonb_build_object(
        'id', h.id, 'name', h.name, 'created_at', h.created_at,
        'member_count', (select count(*) from public.household_members x where x.household_id = h.id),
        'revision', h.data_revision, 'updated_at', h.data_updated_at, 'device', h.data_device,
        'size_bytes', (select octet_length(d.data::text) from public.household_data d where d.household_id = h.id))
        order by h.created_at), '[]'::jsonb)
      from public.households h)
  );
end;
$$;

-- Deletes an account (not your own). Its households pass to another member, or are deleted when it was alone.
create function public.admin_delete_user(target uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare r record;
begin
  if not private.is_admin() then raise exception 'admins only' using errcode = '42501'; end if;
  if target = auth.uid() then raise exception 'cannot delete yourself here'; end if;
  for r in select household_id from public.household_members where user_id = target loop
    perform private.leave(r.household_id, target);
  end loop;
  delete from auth.users where id = target;
end;
$$;

create function public.admin_delete_household(hid uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not private.is_admin() then raise exception 'admins only' using errcode = '42501'; end if;
  delete from public.households where id = hid;
end;
$$;

revoke all on function public.am_i_admin(), public.admin_overview(), public.admin_delete_user(uuid),
  public.admin_delete_household(uuid) from public, anon;
grant execute on function public.am_i_admin(), public.admin_overview(), public.admin_delete_user(uuid),
  public.admin_delete_household(uuid) to authenticated;
