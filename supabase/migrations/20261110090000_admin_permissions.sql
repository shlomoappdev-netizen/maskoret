-- Admins with permissions: the main admin (the owner) appoints other accounts as admins and picks which admin tools
-- each one may use. The server enforces it: every admin function and every admin RLS policy checks the one permission
-- it needs, so a hidden screen is never the only guard.
--
-- Permissions (text keys, shared with the apps):
--   users          subscribers and accounts: search, subscriber card, block, sign out, delete, households
--   support        support tickets: inbox, replies, Claude proposals and questions, agent status
--   dev_tasks      development tasks and the conversation with Claude inside them
--   announcements  messages to all users
-- The owner has every permission, always. Only the owner appoints admins and changes permissions, and nobody can
-- change or remove the owner through the apps (only here, in a migration or the SQL editor).
--
-- After setting up a new project, add the owner once in the SQL editor:
--   insert into private.admins (user_id, is_owner) select id, true from auth.users where email = '<your email>';

alter table private.admins
  add column is_owner boolean not null default false,
  add column permissions text[] not null default '{}',
  add column added_by uuid references auth.users(id) on delete set null;
alter table private.admins add constraint admins_permissions_known
  check (permissions <@ array['users', 'support', 'dev_tasks', 'announcements']::text[]);
create unique index admins_one_owner on private.admins ((true)) where is_owner;

-- Until now there was a single admin: it becomes the owner.
update private.admins set is_owner = true
 where user_id = (select user_id from private.admins order by created_at limit 1)
   and not exists (select 1 from private.admins where is_owner);

-- ===== Checks =====
create function private.admin_can(p text) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from private.admins a join auth.users u on u.id = a.user_id
                 where a.user_id = (select auth.uid()) and u.email_confirmed_at is not null
                   and (a.is_owner or p = any(a.permissions)));
$$;

create function private.is_admin_owner() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from private.admins a join auth.users u on u.id = a.user_id
                 where a.user_id = (select auth.uid()) and u.email_confirmed_at is not null and a.is_owner);
$$;

revoke all on function private.admin_can(text), private.is_admin_owner() from public;
grant execute on function private.admin_can(text), private.is_admin_owner() to authenticated;

-- ===== Every admin function checks its own permission =====
-- private.is_admin() (any admin) stays for admin_stats and am_i_admin: numbers only, no personal data.
do $mig$
declare
  r record;
  def text;
  changed text;
begin
  for r in select * from (values
    ('public.admin_overview()', $c$private.admin_can('users')$c$),
    ('public.admin_search_users(text, text, integer, integer)', $c$private.admin_can('users')$c$),
    ('public.admin_user_detail(uuid)', $c$private.admin_can('users')$c$),
    ('public.admin_delete_user(uuid)', $c$private.admin_can('users')$c$),
    ('public.admin_delete_household(uuid)', $c$private.admin_can('users')$c$),
    ('public.admin_remove_member(uuid, uuid)', $c$private.admin_can('users')$c$),
    ('public.admin_transfer_owner(uuid, uuid)', $c$private.admin_can('users')$c$),
    ('public.admin_set_blocked(uuid, boolean)', $c$private.admin_can('users')$c$),
    -- Also offered as options in a support ticket's proposals.
    ('public.admin_confirm_email(uuid)', $c$(private.admin_can('users') or private.admin_can('support'))$c$),
    ('public.admin_sign_out_user(uuid)', $c$(private.admin_can('users') or private.admin_can('support'))$c$),
    ('public.admin_support_inbox(text, text, integer, integer)', $c$private.admin_can('support')$c$),
    ('public.admin_ask_claude(uuid, text)', $c$private.admin_can('support')$c$),
    ('public.admin_decide_proposal(bigint, text, text)', $c$private.admin_can('support')$c$),
    ('public.admin_set_ai_mode(uuid, text)', $c$private.admin_can('support')$c$),
    ('public.admin_request_proposal(uuid)', $c$private.admin_can('support')$c$),
    ('public.admin_add_dev_task(uuid, text, text)', $c$private.admin_can('support')$c$),
    ('public.support_send(uuid, text, text)', $c$private.admin_can('support')$c$),
    ('public.support_mark_read(uuid)', $c$private.admin_can('support')$c$),
    ('public.support_set_status(uuid, text)', $c$private.admin_can('support')$c$),
    ('public.admin_bot_status()', $c$(private.admin_can('support') or private.admin_can('dev_tasks'))$c$),
    ('public.admin_dev_task_say(bigint, text)', $c$private.admin_can('dev_tasks')$c$),
    ('public.admin_set_dev_task_status(bigint, text)', $c$private.admin_can('dev_tasks')$c$),
    ('public.admin_post_announcement(text, text, integer)', $c$private.admin_can('announcements')$c$),
    ('public.admin_end_announcement(bigint)', $c$private.admin_can('announcements')$c$)
  ) as t(fn, check_expr) loop
    def := pg_get_functiondef(r.fn::regprocedure);
    changed := replace(def, 'private.is_admin()', r.check_expr);
    if changed = def then raise exception 'no admin check found in %', r.fn; end if;
    execute changed;
  end loop;
end
$mig$;

-- ===== RLS: each admin reads only what their permissions cover =====
drop policy "support threads: mine or admin" on public.support_threads;
create policy "support threads: mine or admin" on public.support_threads for select to authenticated
  using (user_id = (select auth.uid()) or (select private.admin_can('support')));

drop policy "support messages: my threads or admin" on public.support_messages;
create policy "support messages: my threads or admin" on public.support_messages for select to authenticated
  using ((select private.admin_can('support'))
         or exists (select 1 from public.support_threads t
                    where t.id = support_messages.thread_id and t.user_id = (select auth.uid())));

drop policy "proposals: admin" on public.support_proposals;
create policy "proposals: admin" on public.support_proposals for select to authenticated
  using ((select private.admin_can('support')));

drop policy "ai questions: admin" on public.support_ai_questions;
create policy "ai questions: admin" on public.support_ai_questions for select to authenticated
  using ((select private.admin_can('support')));

drop policy "dev tasks: admin" on public.dev_tasks;
create policy "dev tasks: admin" on public.dev_tasks for select to authenticated
  using ((select private.admin_can('dev_tasks')));

drop policy "dev task messages: admin" on public.dev_task_messages;
create policy "dev task messages: admin" on public.dev_task_messages for select to authenticated
  using ((select private.admin_can('dev_tasks')));

drop policy "announcements: admin reads all" on public.announcements;
create policy "announcements: admin reads all" on public.announcements for select to authenticated
  using ((select private.admin_can('announcements')));

-- ===== What the apps show =====
-- {admin, owner, permissions}: the owner gets every permission.
create function public.my_admin_access() returns jsonb
language sql stable security definer set search_path = '' as $$
  select coalesce(
    (select jsonb_build_object(
        'admin', true, 'owner', a.is_owner,
        'permissions', to_jsonb(case when a.is_owner
                                     then array['users', 'support', 'dev_tasks', 'announcements']::text[]
                                     else a.permissions end))
       from private.admins a join auth.users u on u.id = a.user_id
      where a.user_id = (select auth.uid()) and u.email_confirmed_at is not null),
    jsonb_build_object('admin', false, 'owner', false, 'permissions', '[]'::jsonb));
$$;

-- ===== The owner manages admins =====
create function public.admin_list_admins() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  if not private.is_admin_owner() then raise exception 'owner only' using errcode = '42501'; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object(
      'user_id', a.user_id, 'email', u.email, 'display_name', coalesce(p.display_name, ''),
      'owner', a.is_owner, 'permissions', to_jsonb(a.permissions), 'created_at', a.created_at,
      'confirmed', u.email_confirmed_at is not null)
      order by a.is_owner desc, a.created_at), '[]'::jsonb)
    from private.admins a join auth.users u on u.id = a.user_id left join public.profiles p on p.id = a.user_id);
end;
$$;

-- Appoints an account as an admin, or changes an admin's permissions. Never the owner.
create function public.admin_set_admin(target uuid, p_permissions text[]) returns void
language plpgsql security definer set search_path = '' as $$
declare perms text[];
begin
  if not private.is_admin_owner() then raise exception 'owner only' using errcode = '42501'; end if;
  if target = auth.uid() or exists (select 1 from private.admins where user_id = target and is_owner) then
    raise exception 'the owner''s permissions cannot be changed' using errcode = '42501';
  end if;
  if not exists (select 1 from auth.users where id = target) then raise exception 'no such user'; end if;
  perms := array(select distinct x from unnest(coalesce(p_permissions, '{}')) x order by x);
  if not perms <@ array['users', 'support', 'dev_tasks', 'announcements']::text[] then
    raise exception 'unknown permission';
  end if;
  insert into private.admins (user_id, permissions, added_by) values (target, perms, auth.uid())
  on conflict (user_id) do update set permissions = excluded.permissions;
end;
$$;

-- The same, by the account's email (what the owner types in the admins screen). Returns the account id.
create function public.admin_add_admin_by_email(p_email text, p_permissions text[]) returns uuid
language plpgsql security definer set search_path = '' as $$
declare target uuid;
begin
  if not private.is_admin_owner() then raise exception 'owner only' using errcode = '42501'; end if;
  select id into target from auth.users where lower(email) = lower(trim(coalesce(p_email, ''))) limit 1;
  if target is null then raise exception 'no such user'; end if;
  perform public.admin_set_admin(target, p_permissions);
  return target;
end;
$$;

create function public.admin_remove_admin(target uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not private.is_admin_owner() then raise exception 'owner only' using errcode = '42501'; end if;
  if exists (select 1 from private.admins where user_id = target and is_owner) then
    raise exception 'the owner cannot be removed' using errcode = '42501';
  end if;
  delete from private.admins where user_id = target;
end;
$$;

revoke all on function public.my_admin_access(), public.admin_list_admins(), public.admin_set_admin(uuid, text[]),
  public.admin_add_admin_by_email(text, text[]), public.admin_remove_admin(uuid) from public, anon;
grant execute on function public.my_admin_access(), public.admin_list_admins(), public.admin_set_admin(uuid, text[]),
  public.admin_add_admin_by_email(text, text[]), public.admin_remove_admin(uuid) to authenticated;
