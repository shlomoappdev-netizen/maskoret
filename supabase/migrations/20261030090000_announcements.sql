-- Announcements: the admin writes a message that every user sees at the top of the main screen until they close it
-- (closing is remembered on the device). Readable without an account, so users in local mode see it too.

create table public.announcements (
  id bigint generated always as identity primary key,
  title text not null check (char_length(title) between 1 and 120),
  body text not null default '' check (char_length(body) <= 2000),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  expires_at timestamptz
);
create index announcements_active_idx on public.announcements(id desc) where active;

alter table public.announcements enable row level security;
revoke all on public.announcements from anon, authenticated;
grant select on public.announcements to anon, authenticated;
create policy "announcements: everyone reads the active ones" on public.announcements for select to anon, authenticated
  using (active and (expires_at is null or expires_at > now()));
-- Separate, because anon may not call private.is_admin().
create policy "announcements: admin reads all" on public.announcements for select to authenticated
  using ((select private.is_admin()));
alter publication supabase_realtime add table public.announcements;

create function public.admin_post_announcement(p_title text, p_body text, p_days int default null) returns bigint
language plpgsql security definer set search_path = '' as $$
declare
  v_id bigint;
begin
  if not private.is_admin() then raise exception 'admins only' using errcode = '42501'; end if;
  insert into public.announcements (title, body, expires_at)
  values (left(trim(p_title), 120), left(trim(coalesce(p_body, '')), 2000),
          case when p_days is null then null else now() + make_interval(days => p_days) end)
  returning id into v_id;
  return v_id;
end;
$$;

create function public.admin_end_announcement(p_id bigint) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not private.is_admin() then raise exception 'admins only' using errcode = '42501'; end if;
  update public.announcements set active = false where id = p_id;
end;
$$;

revoke all on function public.admin_post_announcement(text, text, int), public.admin_end_announcement(bigint) from public;
grant execute on function public.admin_post_announcement(text, text, int), public.admin_end_announcement(bigint) to authenticated;
