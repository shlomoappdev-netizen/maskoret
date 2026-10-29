-- Maskoret: accounts, households and sync.
-- Run once on a new Supabase project (SQL editor, or `supabase db push`).

-- ===== Tables =====
create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null default '' check (char_length(display_name) <= 80),
  email text,
  created_at timestamptz not null default now()
);

create table public.households (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 1 and 80),
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  -- head of the data, small, so Realtime can announce changes without sending the whole document
  data_revision bigint not null default 0,
  data_updated_at timestamptz,
  data_device text
);

create table public.household_members (
  household_id uuid not null references public.households(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null check (role in ('owner', 'member')),
  joined_at timestamptz not null default now(),
  primary key (household_id, user_id)
);
create index household_members_user_idx on public.household_members(user_id);

create table public.household_invites (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households(id) on delete cascade,
  code text not null unique,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '7 days',
  used_by uuid references auth.users(id) on delete set null,
  used_at timestamptz
);
create index household_invites_household_idx on public.household_invites(household_id);
create index household_invites_created_by_idx on public.household_invites(created_by);
create index household_invites_used_by_idx on public.household_invites(used_by);

create table public.household_data (
  household_id uuid primary key references public.households(id) on delete cascade,
  data jsonb not null,
  revision bigint not null default 1,
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id) on delete set null,
  device text
);
create index household_data_updated_by_idx on public.household_data(updated_by);

create table public.household_snapshots (
  id bigint generated always as identity primary key,
  household_id uuid not null references public.households(id) on delete cascade,
  data jsonb not null,
  revision bigint not null,
  saved_at timestamptz not null default now(),
  updated_by uuid references auth.users(id) on delete set null,
  device text
);
create index household_snapshots_household_idx on public.household_snapshots(household_id, revision desc);
create index household_snapshots_updated_by_idx on public.household_snapshots(updated_by);
create index households_created_by_idx on public.households(created_by);

-- ===== Helpers (private schema, not exposed by the API) =====
create schema if not exists private;
grant usage on schema private to authenticated;

create function private.is_member(hid uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.household_members m
                 where m.household_id = hid and m.user_id = (select auth.uid()));
$$;

create function private.is_owner(hid uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.household_members m
                 where m.household_id = hid and m.user_id = (select auth.uid()) and m.role = 'owner');
$$;

create function private.shares_household(other uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.household_members a
                 join public.household_members b on a.household_id = b.household_id
                 where a.user_id = (select auth.uid()) and b.user_id = other);
$$;

revoke all on function private.is_member(uuid), private.is_owner(uuid), private.shares_household(uuid) from public;
grant execute on function private.is_member(uuid), private.is_owner(uuid), private.shares_household(uuid) to authenticated;

-- ===== RLS: reads only; every write goes through the functions below =====
alter table public.profiles enable row level security;
alter table public.households enable row level security;
alter table public.household_members enable row level security;
alter table public.household_invites enable row level security;
alter table public.household_data enable row level security;
alter table public.household_snapshots enable row level security;

revoke all on public.profiles, public.households, public.household_members, public.household_invites,
              public.household_data, public.household_snapshots from anon, authenticated;
grant select on public.profiles, public.households, public.household_members, public.household_invites,
                public.household_data, public.household_snapshots to authenticated;
grant update (display_name) on public.profiles to authenticated;

create policy "profiles: me and my household members" on public.profiles for select to authenticated
  using (id = (select auth.uid()) or private.shares_household(id));
create policy "profiles: update my name" on public.profiles for update to authenticated
  using (id = (select auth.uid())) with check (id = (select auth.uid()));

create policy "households: members read" on public.households for select to authenticated
  using (private.is_member(id));
create policy "members: members read" on public.household_members for select to authenticated
  using (private.is_member(household_id));
create policy "invites: owners read" on public.household_invites for select to authenticated
  using (private.is_owner(household_id));
create policy "data: members read" on public.household_data for select to authenticated
  using (private.is_member(household_id));
create policy "snapshots: members read" on public.household_snapshots for select to authenticated
  using (private.is_member(household_id));

-- ===== New user → profile =====
create function private.handle_new_user() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.profiles (id, display_name, email)
  values (new.id, coalesce(left(new.raw_user_meta_data ->> 'display_name', 80), ''), new.email);
  return new;
end;
$$;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function private.handle_new_user();

-- ===== History: keep the previous version on every save (last 30) =====
create function private.snapshot_household_data() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.household_snapshots (household_id, data, revision, saved_at, updated_by, device)
  values (old.household_id, old.data, old.revision, old.updated_at, old.updated_by, old.device);
  delete from public.household_snapshots s
   where s.household_id = old.household_id
     and s.id not in (select id from public.household_snapshots
                      where household_id = old.household_id order by revision desc limit 30);
  return new;
end;
$$;
create trigger household_data_snapshot before update of data on public.household_data
  for each row execute function private.snapshot_household_data();

-- ===== API functions =====
create function public.my_households() returns jsonb
language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', h.id, 'name', h.name, 'role', m.role,
           'member_count', (select count(*) from public.household_members x where x.household_id = h.id),
           'revision', h.data_revision, 'updated_at', h.data_updated_at, 'device', h.data_device)
         order by m.joined_at), '[]'::jsonb)
  from public.household_members m join public.households h on h.id = m.household_id
  where m.user_id = (select auth.uid());
$$;

create function public.household_members_list(hid uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  if not private.is_member(hid) then raise exception 'not a member' using errcode = '42501'; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object(
            'user_id', m.user_id, 'role', m.role, 'joined_at', m.joined_at,
            'display_name', coalesce(p.display_name, ''), 'email', p.email) order by m.joined_at), '[]'::jsonb)
          from public.household_members m left join public.profiles p on p.id = m.user_id
          where m.household_id = hid);
end;
$$;

create function public.create_household(p_name text, p_data jsonb default '{}'::jsonb, p_device text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); hid uuid;
begin
  if uid is null then raise exception 'not signed in' using errcode = '42501'; end if;
  if (select count(*) from public.household_members where user_id = uid) >= 20 then
    raise exception 'too many households';
  end if;
  insert into public.households (name, created_by, data_revision, data_updated_at, data_device)
  values (left(trim(p_name), 80), uid, 1, now(), left(p_device, 80)) returning id into hid;
  insert into public.household_members (household_id, user_id, role) values (hid, uid, 'owner');
  insert into public.household_data (household_id, data, revision, updated_by, device)
  values (hid, coalesce(p_data, '{}'::jsonb), 1, uid, left(p_device, 80));
  return jsonb_build_object('id', hid, 'revision', 1);
end;
$$;

create function public.rename_household(hid uuid, p_name text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not private.is_owner(hid) then raise exception 'only the owner' using errcode = '42501'; end if;
  update public.households set name = left(trim(p_name), 80) where id = hid;
end;
$$;

create function public.delete_household(hid uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not private.is_owner(hid) then raise exception 'only the owner' using errcode = '42501'; end if;
  delete from public.households where id = hid;
end;
$$;

create function public.save_household_data(hid uuid, p_data jsonb, expected_revision bigint, p_device text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); new_rev bigint; current_rev bigint;
begin
  if not private.is_member(hid) then raise exception 'not a member' using errcode = '42501'; end if;
  if octet_length(p_data::text) > 20 * 1024 * 1024 then raise exception 'data too large'; end if;
  update public.household_data
     set data = p_data, revision = revision + 1, updated_at = now(), updated_by = uid, device = left(p_device, 80)
   where household_id = hid and revision = expected_revision
  returning revision into new_rev;
  if new_rev is null then
    select revision into current_rev from public.household_data where household_id = hid;
    return jsonb_build_object('ok', false, 'revision', current_rev);
  end if;
  update public.households set data_revision = new_rev, data_updated_at = now(), data_device = left(p_device, 80)
   where id = hid;
  return jsonb_build_object('ok', true, 'revision', new_rev);
end;
$$;

create function public.create_invite(hid uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare alphabet text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; c text; b bytea; i int; inv public.household_invites;
begin
  if not private.is_owner(hid) then raise exception 'only the owner' using errcode = '42501'; end if;
  loop
    b := extensions.gen_random_bytes(8);
    c := '';
    for i in 0..7 loop c := c || substr(alphabet, (get_byte(b, i) % 32) + 1, 1); end loop;
    exit when not exists (select 1 from public.household_invites where code = c);
  end loop;
  insert into public.household_invites (household_id, code, created_by) values (hid, c, auth.uid()) returning * into inv;
  return jsonb_build_object('code', inv.code, 'expires_at', inv.expires_at);
end;
$$;

create function public.accept_invite(p_code text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); inv public.household_invites; hname text;
begin
  if uid is null then raise exception 'not signed in' using errcode = '42501'; end if;
  select * into inv from public.household_invites
   where code = upper(regexp_replace(p_code, '[^A-Za-z0-9]', '', 'g'))
     and used_at is null and expires_at > now()
   for update;
  if inv.id is null then raise exception 'invalid or expired code' using errcode = 'P0002'; end if;
  insert into public.household_members (household_id, user_id, role) values (inv.household_id, uid, 'member')
    on conflict do nothing;
  update public.household_invites set used_by = uid, used_at = now() where id = inv.id;
  select name into hname from public.households where id = inv.household_id;
  return jsonb_build_object('id', inv.household_id, 'name', hname);
end;
$$;

-- Leaving: an owner hands the household to the longest-standing member; the last one out deletes it.
create function private.leave(hid uuid, uid uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare next_owner uuid;
begin
  if exists (select 1 from public.household_members where household_id = hid and user_id = uid and role = 'owner') then
    select user_id into next_owner from public.household_members
     where household_id = hid and user_id <> uid order by joined_at limit 1;
    if next_owner is null then
      delete from public.households where id = hid;
      return;
    end if;
    update public.household_members set role = 'owner' where household_id = hid and user_id = next_owner
      and not exists (select 1 from public.household_members where household_id = hid and user_id <> uid and role = 'owner');
  end if;
  delete from public.household_members where household_id = hid and user_id = uid;
end;
$$;
revoke all on function private.leave(uuid, uuid) from public;

create function public.leave_household(hid uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not private.is_member(hid) then raise exception 'not a member' using errcode = '42501'; end if;
  perform private.leave(hid, auth.uid());
end;
$$;

create function public.remove_member(hid uuid, member uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not private.is_owner(hid) then raise exception 'only the owner' using errcode = '42501'; end if;
  if member = auth.uid() then raise exception 'use leave_household'; end if;
  delete from public.household_members where household_id = hid and user_id = member;
end;
$$;

create function public.delete_my_account() returns void
language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); r record;
begin
  if uid is null then raise exception 'not signed in' using errcode = '42501'; end if;
  for r in select household_id from public.household_members where user_id = uid loop
    perform private.leave(r.household_id, uid);
  end loop;
  delete from auth.users where id = uid;
end;
$$;

-- Only signed-in users may call the API functions.
revoke all on function public.my_households(), public.household_members_list(uuid),
  public.create_household(text, jsonb, text), public.rename_household(uuid, text), public.delete_household(uuid),
  public.save_household_data(uuid, jsonb, bigint, text), public.create_invite(uuid), public.accept_invite(text),
  public.leave_household(uuid), public.remove_member(uuid, uuid), public.delete_my_account() from public, anon;
grant execute on function public.my_households(), public.household_members_list(uuid),
  public.create_household(text, jsonb, text), public.rename_household(uuid, text), public.delete_household(uuid),
  public.save_household_data(uuid, jsonb, bigint, text), public.create_invite(uuid), public.accept_invite(text),
  public.leave_household(uuid), public.remove_member(uuid, uuid), public.delete_my_account() to authenticated;

-- ===== Realtime: announce new revisions / renames (the small households row, not the data) =====
alter publication supabase_realtime add table public.households;
