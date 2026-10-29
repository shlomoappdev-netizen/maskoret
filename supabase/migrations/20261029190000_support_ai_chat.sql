-- The admin talks with Claude inside a ticket, and development tasks reach the developer.
--
-- * support_ai_questions: what the admin asks Claude about a ticket (admin only). Asking wakes the agent; its answer is
--   the next proposal (the summary answers the question; options are optional then).
-- * bot_pending_threads also returns the earlier proposals and questions, so Claude keeps the thread of the conversation.
-- * A new development task pings the agent, which shows a notification on the Mac; Claude Code sessions in the project
--   list the open tasks at start (bot_open_dev_tasks, .claude/hooks/dev-tasks.sh).

create table public.support_ai_questions (
  id bigint generated always as identity primary key,
  thread_id uuid not null references public.support_threads(id) on delete cascade,
  body text not null check (char_length(body) between 1 and 2000),
  created_at timestamptz not null default now(),
  answered_at timestamptz
);
create index support_ai_questions_thread_idx on public.support_ai_questions(thread_id, id);
alter table public.support_ai_questions enable row level security;
revoke all on public.support_ai_questions from anon, authenticated;
grant select on public.support_ai_questions to authenticated;
create policy "ai questions: admin" on public.support_ai_questions for select to authenticated
  using ((select private.is_admin()));
alter publication supabase_realtime add table public.support_ai_questions;

alter table public.support_proposals add column answers_question bigint references public.support_ai_questions(id) on delete set null;

alter table public.dev_tasks add column done_at timestamptz;
alter publication supabase_realtime add table public.dev_tasks;

-- ===== Admin =====
create function public.admin_ask_claude(p_thread uuid, p_question text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not private.is_admin() then raise exception 'admins only' using errcode = '42501'; end if;
  if char_length(trim(coalesce(p_question, ''))) = 0 then raise exception 'empty question'; end if;
  insert into public.support_ai_questions (thread_id, body) values (p_thread, left(trim(p_question), 2000));
  update public.support_threads set ai_mode = 'on', ai_pending = true where id = p_thread;
  perform realtime.send('{}'::jsonb, 'work', 'maskoret-support-agent', false);
end;
$$;

create function public.admin_set_dev_task_status(p_task bigint, p_status text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not private.is_admin() then raise exception 'admins only' using errcode = '42501'; end if;
  update public.dev_tasks set status = p_status, done_at = case when p_status = 'open' then null else now() end
   where id = p_task;
end;
$$;

-- ===== Agent =====
create or replace function public.bot_pending_threads(p_token text) returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  if not private.is_support_agent(p_token) then raise exception 'forbidden' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id', t.id, 'subject', t.subject, 'category', t.category, 'status', t.status,
      'created_at', t.created_at, 'app_info', t.app_info,
      'user', jsonb_build_object(
          'member_no', p.member_no, 'email', u.email, 'display_name', p.display_name,
          'created_at', u.created_at, 'last_sign_in_at', u.last_sign_in_at,
          'confirmed', u.email_confirmed_at is not null,
          'providers', coalesce(u.raw_app_meta_data -> 'providers', '[]'::jsonb),
          'households', (select coalesce(jsonb_agg(jsonb_build_object(
              'name', h.name, 'role', m.role, 'revision', h.data_revision, 'updated_at', h.data_updated_at,
              'device', h.data_device,
              'members', (select count(*) from public.household_members x where x.household_id = h.id),
              'versions', (select count(*) from public.household_snapshots s where s.household_id = h.id))), '[]'::jsonb)
            from public.household_members m join public.households h on h.id = m.household_id
            where m.user_id = t.user_id)),
      'messages', (select jsonb_agg(jsonb_build_object(
          'id', m.id, 'from_admin', m.from_admin, 'body', m.body, 'log', m.log, 'created_at', m.created_at)
          order by m.id)
        from public.support_messages m where m.thread_id = t.id),
      'earlier_proposals', (select coalesce(jsonb_agg(jsonb_build_object(
          'at', s.created_at, 'summary', s.summary, 'status', s.status,
          'options', (select jsonb_agg(o ->> 'title') from jsonb_array_elements(s.options) o),
          'chosen', (select o ->> 'title' from jsonb_array_elements(s.options) o where o ->> 'id' = s.chosen_option))
          order by s.id), '[]'::jsonb)
        from public.support_proposals s where s.thread_id = t.id),
      'admin_questions', (select coalesce(jsonb_agg(jsonb_build_object(
          'id', q.id, 'at', q.created_at, 'question', q.body, 'answered', q.answered_at is not null) order by q.id), '[]'::jsonb)
        from public.support_ai_questions q where q.thread_id = t.id))
      order by t.last_message_at)
    from public.support_threads t
    join public.profiles p on p.id = t.user_id
    join auth.users u on u.id = t.user_id
    where t.ai_pending and t.ai_mode = 'on'), '[]'::jsonb);
end;
$$;

create or replace function public.bot_save_proposal(p_token text, p_thread uuid, p_message_id bigint,
                                                    p_summary text, p_options jsonb) returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_question bigint;
begin
  if not private.is_support_agent(p_token) then raise exception 'forbidden' using errcode = '42501'; end if;
  if jsonb_typeof(p_options) <> 'array' or jsonb_array_length(p_options) > 6 then raise exception 'bad options'; end if;
  -- A newer message arrived while the agent was thinking: leave the thread pending for another round.
  if exists (select 1 from public.support_messages where thread_id = p_thread and id > p_message_id and not from_admin) then
    return;
  end if;
  select max(id) into v_question from public.support_ai_questions where thread_id = p_thread and answered_at is null;
  update public.support_ai_questions set answered_at = now() where thread_id = p_thread and answered_at is null;
  update public.support_proposals set status = 'superseded' where thread_id = p_thread and status = 'pending';
  insert into public.support_proposals (thread_id, for_message_id, summary, options, answers_question)
  values (p_thread, p_message_id, left(p_summary, 4000), p_options, v_question);
  update public.support_threads set ai_pending = false where id = p_thread;
end;
$$;

create function public.bot_open_dev_tasks(p_token text) returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  if not private.is_support_agent(p_token) then raise exception 'forbidden' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id', d.id, 'title', d.title, 'details', d.details, 'created_at', d.created_at,
      'thread_id', d.thread_id, 'thread_subject', t.subject) order by d.id)
    from public.dev_tasks d left join public.support_threads t on t.id = d.thread_id
    where d.status = 'open'), '[]'::jsonb);
end;
$$;

-- A new task pings the agent (content-free), which shows a notification on the Mac.
create function private.dev_task_added() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  perform realtime.send('{}'::jsonb, 'dev_task', 'maskoret-support-agent', false);
  return new;
end;
$$;
create trigger dev_task_added after insert on public.dev_tasks
  for each row execute function private.dev_task_added();

revoke all on function public.admin_ask_claude(uuid, text), public.admin_set_dev_task_status(bigint, text),
  public.bot_open_dev_tasks(text) from public;
grant execute on function public.admin_ask_claude(uuid, text), public.admin_set_dev_task_status(bigint, text) to authenticated;
grant execute on function public.bot_open_dev_tasks(text) to anon, authenticated;
