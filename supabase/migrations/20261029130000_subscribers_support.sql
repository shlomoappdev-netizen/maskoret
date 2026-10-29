-- Subscribers and support, built to stay fast with thousands of accounts:
--   * every account gets a short subscriber number (member_no) that users can quote in a report
--   * the admin screen searches on the server, one page at a time, and opens a card per subscriber
--   * a support chat (threads + messages) with optional diagnostic logs, live through Realtime

-- ===== Subscriber number =====
create sequence private.member_no_seq start 100001;
alter table public.profiles add column member_no bigint unique default nextval('private.member_no_seq');
update public.profiles set member_no = nextval('private.member_no_seq') where member_no is null;
alter table public.profiles alter column member_no set not null;

-- ===== Search indexes =====
create extension if not exists pg_trgm with schema extensions;
create index profiles_email_trgm on public.profiles using gin (lower(email) extensions.gin_trgm_ops);
create index profiles_name_trgm on public.profiles using gin (lower(display_name) extensions.gin_trgm_ops);
create index households_name_trgm on public.households using gin (lower(name) extensions.gin_trgm_ops);

-- ===== Support tables =====
create table public.support_threads (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  subject text not null check (char_length(subject) between 1 and 120),
  category text not null default 'bug' check (category in ('bug', 'question', 'idea', 'other')),
  status text not null default 'open' check (status in ('open', 'closed')),
  app_info jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  last_message_at timestamptz not null default now(),
  user_unread int not null default 0,
  admin_unread int not null default 0
);
create index support_threads_user_idx on public.support_threads(user_id, last_message_at desc);
create index support_threads_inbox_idx on public.support_threads(status, last_message_at desc);

create table public.support_messages (
  id bigint generated always as identity primary key,
  thread_id uuid not null references public.support_threads(id) on delete cascade,
  sender uuid references auth.users(id) on delete set null,
  from_admin boolean not null default false,
  body text not null check (char_length(body) between 1 and 5000),
  log text check (octet_length(log) <= 400000),
  created_at timestamptz not null default now()
);
create index support_messages_thread_idx on public.support_messages(thread_id, id);
create index support_messages_sender_idx on public.support_messages(sender);

alter table public.support_threads enable row level security;
alter table public.support_messages enable row level security;
revoke all on public.support_threads, public.support_messages from anon, authenticated;
grant select on public.support_threads, public.support_messages to authenticated;

create policy "support threads: mine or admin" on public.support_threads for select to authenticated
  using (user_id = (select auth.uid()) or (select private.is_admin()));
create policy "support messages: my threads or admin" on public.support_messages for select to authenticated
  using ((select private.is_admin())
         or exists (select 1 from public.support_threads t where t.id = thread_id and t.user_id = (select auth.uid())));

alter publication supabase_realtime add table public.support_threads, public.support_messages;

-- ===== Me =====
create function public.my_profile() returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('member_no', p.member_no, 'display_name', p.display_name, 'email', p.email)
  from public.profiles p where p.id = (select auth.uid());
$$;

-- ===== Support: user side =====
create function public.support_open_thread(p_subject text, p_category text, p_body text,
                                           p_log text default null, p_app_info jsonb default '{}'::jsonb)
returns uuid
language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); tid uuid;
begin
  if uid is null then raise exception 'not signed in' using errcode = '42501'; end if;
  if (select count(*) from public.support_threads where user_id = uid and created_at > now() - interval '1 day') >= 10 then
    raise exception 'too many reports' using errcode = '54000';
  end if;
  insert into public.support_threads (user_id, subject, category, app_info, admin_unread)
  values (uid, left(trim(p_subject), 120), p_category, coalesce(p_app_info, '{}'::jsonb), 1)
  returning id into tid;
  insert into public.support_messages (thread_id, sender, from_admin, body, log)
  values (tid, uid, false, p_body, nullif(p_log, ''));
  return tid;
end;
$$;

-- Users write in their own threads (and reopen them); the admin writes in any thread.
create function public.support_send(p_thread uuid, p_body text, p_log text default null) returns void
language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); owner uuid; admin boolean := private.is_admin();
begin
  select user_id into owner from public.support_threads where id = p_thread;
  if owner is null then raise exception 'thread not found'; end if;
  if owner <> uid and not admin then raise exception 'not your thread' using errcode = '42501'; end if;
  if not admin and (select count(*) from public.support_messages
                    where sender = uid and created_at > now() - interval '1 hour') >= 60 then
    raise exception 'too many messages' using errcode = '54000';
  end if;
  insert into public.support_messages (thread_id, sender, from_admin, body, log)
  values (p_thread, uid, owner <> uid, p_body, nullif(p_log, ''));
  if owner <> uid then
    update public.support_threads set last_message_at = now(), user_unread = user_unread + 1 where id = p_thread;
  else
    update public.support_threads set last_message_at = now(), admin_unread = admin_unread + 1, status = 'open'
     where id = p_thread;
  end if;
end;
$$;

create function public.support_mark_read(p_thread uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  update public.support_threads set user_unread = 0 where id = p_thread and user_id = auth.uid();
  if private.is_admin() then
    update public.support_threads set admin_unread = 0 where id = p_thread;
  end if;
end;
$$;

create function public.support_set_status(p_thread uuid, p_status text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  update public.support_threads set status = p_status
   where id = p_thread and (user_id = auth.uid() or private.is_admin());
end;
$$;

-- ===== Admin: dashboard numbers =====
create function public.admin_stats() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  if not private.is_admin() then raise exception 'admins only' using errcode = '42501'; end if;
  return jsonb_build_object(
    'users', (select count(*) from auth.users),
    'new_7d', (select count(*) from auth.users where created_at > now() - interval '7 days'),
    'active_7d', (select count(*) from auth.users where last_sign_in_at > now() - interval '7 days'),
    'households', (select count(*) from public.households),
    'open_threads', (select count(*) from public.support_threads where status = 'open'),
    'unread_threads', (select count(*) from public.support_threads where admin_unread > 0));
end;
$$;

-- ===== Admin: search (one page at a time) =====
-- Matches the subscriber number, account id, email, name, or the name of a household they belong to.
create function public.admin_search_users(q text default '', p_filter text default 'all',
                                          p_limit int default 50, p_offset int default 0)
returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare term text := lower(trim(coalesce(q, ''))); res jsonb;
begin
  if not private.is_admin() then raise exception 'admins only' using errcode = '42501'; end if;
  with matched as (
    select u.id, u.email, u.created_at, u.last_sign_in_at, u.email_confirmed_at, u.banned_until,
           u.raw_app_meta_data, p.display_name, p.member_no
      from auth.users u join public.profiles p on p.id = u.id
     where (term = ''
            or p.member_no::text = term
            or u.id::text = term
            or lower(u.email) like '%' || term || '%'
            or lower(p.display_name) like '%' || term || '%'
            or exists (select 1 from public.household_members m join public.households h on h.id = m.household_id
                        where m.user_id = u.id and lower(h.name) like '%' || term || '%'))
       and (p_filter = 'all'
            or (p_filter = 'unconfirmed' and u.email_confirmed_at is null)
            or (p_filter = 'blocked' and u.banned_until > now())
            or (p_filter = 'open_threads' and exists (select 1 from public.support_threads t
                                                       where t.user_id = u.id and t.status = 'open')))
  ), page as (
    select * from matched order by created_at desc limit least(greatest(p_limit, 1), 200) offset greatest(p_offset, 0)
  )
  select jsonb_build_object(
    'total', (select count(*) from matched),
    'users', coalesce((select jsonb_agg(jsonb_build_object(
        'id', x.id, 'member_no', x.member_no, 'email', x.email, 'display_name', x.display_name,
        'created_at', x.created_at, 'last_sign_in_at', x.last_sign_in_at,
        'confirmed', x.email_confirmed_at is not null,
        'blocked', coalesce(x.banned_until > now(), false),
        'providers', coalesce(x.raw_app_meta_data -> 'providers', '[]'::jsonb),
        'owned', (select count(*) from public.household_members m where m.user_id = x.id and m.role = 'owner'),
        'shared', (select count(*) from public.household_members m where m.user_id = x.id and m.role <> 'owner'),
        'open_threads', (select count(*) from public.support_threads t where t.user_id = x.id and t.status = 'open'))
        order by x.created_at desc) from page x), '[]'::jsonb))
  into res;
  return res;
end;
$$;

-- ===== Admin: one subscriber's card =====
create function public.admin_user_detail(target uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare res jsonb;
begin
  if not private.is_admin() then raise exception 'admins only' using errcode = '42501'; end if;
  select jsonb_build_object(
    'id', u.id, 'member_no', p.member_no, 'email', u.email, 'display_name', p.display_name,
    'created_at', u.created_at, 'last_sign_in_at', u.last_sign_in_at,
    'confirmed', u.email_confirmed_at is not null,
    'blocked', coalesce(u.banned_until > now(), false),
    'providers', coalesce(u.raw_app_meta_data -> 'providers', '[]'::jsonb),
    'sessions', (select count(*) from auth.sessions s where s.user_id = u.id),
    'households', (select coalesce(jsonb_agg(jsonb_build_object(
        'id', h.id, 'name', h.name, 'role', m.role, 'created_at', h.created_at,
        'revision', h.data_revision, 'updated_at', h.data_updated_at, 'device', h.data_device,
        'size_bytes', (select octet_length(d.data::text) from public.household_data d where d.household_id = h.id),
        'versions', (select count(*) from public.household_snapshots s where s.household_id = h.id),
        'members', (select coalesce(jsonb_agg(jsonb_build_object(
            'id', mm.user_id, 'role', mm.role, 'joined_at', mm.joined_at,
            'email', pp.email, 'display_name', pp.display_name, 'member_no', pp.member_no)
            order by mm.role = 'owner' desc, mm.joined_at), '[]'::jsonb)
          from public.household_members mm join public.profiles pp on pp.id = mm.user_id
          where mm.household_id = h.id))
        order by m.role = 'owner' desc, m.joined_at), '[]'::jsonb)
      from public.household_members m join public.households h on h.id = m.household_id
      where m.user_id = u.id),
    'threads', (select coalesce(jsonb_agg(jsonb_build_object(
        'id', t.id, 'subject', t.subject, 'category', t.category, 'status', t.status,
        'created_at', t.created_at, 'last_message_at', t.last_message_at, 'admin_unread', t.admin_unread)
        order by t.last_message_at desc), '[]'::jsonb)
      from public.support_threads t where t.user_id = u.id))
  into res
  from auth.users u join public.profiles p on p.id = u.id
  where u.id = target;
  if res is null then raise exception 'user not found'; end if;
  return res;
end;
$$;

-- ===== Admin: support inbox =====
create function public.admin_support_inbox(p_status text default 'open', q text default '',
                                           p_limit int default 50, p_offset int default 0)
returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare term text := lower(trim(coalesce(q, ''))); res jsonb;
begin
  if not private.is_admin() then raise exception 'admins only' using errcode = '42501'; end if;
  with matched as (
    select t.*, p.email, p.display_name, p.member_no
      from public.support_threads t join public.profiles p on p.id = t.user_id
     where (p_status = 'all' or t.status = p_status)
       and (term = '' or p.member_no::text = term or lower(p.email) like '%' || term || '%'
            or lower(p.display_name) like '%' || term || '%' or lower(t.subject) like '%' || term || '%')
  ), page as (
    select * from matched order by last_message_at desc limit least(greatest(p_limit, 1), 200) offset greatest(p_offset, 0)
  )
  select jsonb_build_object(
    'total', (select count(*) from matched),
    'threads', coalesce((select jsonb_agg(jsonb_build_object(
        'id', x.id, 'user_id', x.user_id, 'subject', x.subject, 'category', x.category, 'status', x.status,
        'created_at', x.created_at, 'last_message_at', x.last_message_at,
        'admin_unread', x.admin_unread, 'user_unread', x.user_unread, 'app_info', x.app_info,
        'email', x.email, 'display_name', x.display_name, 'member_no', x.member_no,
        'preview', (select left(m.body, 140) from public.support_messages m where m.thread_id = x.id
                    order by m.id desc limit 1))
        order by x.last_message_at desc) from page x), '[]'::jsonb))
  into res;
  return res;
end;
$$;

-- ===== Admin: actions on a subscriber =====
create function public.admin_set_blocked(target uuid, p_blocked boolean) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not private.is_admin() then raise exception 'admins only' using errcode = '42501'; end if;
  if target = auth.uid() then raise exception 'cannot block yourself'; end if;
  update auth.users set banned_until = case when p_blocked then 'infinity'::timestamptz else null end where id = target;
  if p_blocked then delete from auth.sessions where user_id = target; end if;
end;
$$;

create function public.admin_sign_out_user(target uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not private.is_admin() then raise exception 'admins only' using errcode = '42501'; end if;
  delete from auth.sessions where user_id = target;
end;
$$;

-- For a user whose verification code never arrived.
create function public.admin_confirm_email(target uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not private.is_admin() then raise exception 'admins only' using errcode = '42501'; end if;
  update auth.users set email_confirmed_at = coalesce(email_confirmed_at, now()) where id = target;
end;
$$;

create function public.admin_remove_member(hid uuid, member uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not private.is_admin() then raise exception 'admins only' using errcode = '42501'; end if;
  perform private.leave(hid, member);
end;
$$;

-- A household has exactly one owner: the new one takes over, the old one stays with access.
create function public.admin_transfer_owner(hid uuid, new_owner uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not private.is_admin() then raise exception 'admins only' using errcode = '42501'; end if;
  if not exists (select 1 from public.household_members where household_id = hid and user_id = new_owner) then
    raise exception 'not a member';
  end if;
  update public.household_members set role = 'member' where household_id = hid and role = 'owner';
  update public.household_members set role = 'owner' where household_id = hid and user_id = new_owner;
end;
$$;

-- ===== Permissions =====
revoke all on function public.my_profile(), public.support_open_thread(text, text, text, text, jsonb),
  public.support_send(uuid, text, text), public.support_mark_read(uuid), public.support_set_status(uuid, text),
  public.admin_stats(), public.admin_search_users(text, text, int, int), public.admin_user_detail(uuid),
  public.admin_support_inbox(text, text, int, int), public.admin_set_blocked(uuid, boolean),
  public.admin_sign_out_user(uuid), public.admin_confirm_email(uuid), public.admin_remove_member(uuid, uuid),
  public.admin_transfer_owner(uuid, uuid) from public, anon;
grant execute on function public.my_profile(), public.support_open_thread(text, text, text, text, jsonb),
  public.support_send(uuid, text, text), public.support_mark_read(uuid), public.support_set_status(uuid, text),
  public.admin_stats(), public.admin_search_users(text, text, int, int), public.admin_user_detail(uuid),
  public.admin_support_inbox(text, text, int, int), public.admin_set_blocked(uuid, boolean),
  public.admin_sign_out_user(uuid), public.admin_confirm_email(uuid), public.admin_remove_member(uuid, uuid),
  public.admin_transfer_owner(uuid, uuid) to authenticated;
