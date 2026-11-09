-- Development tasks get a conversation with Claude, and the admin sees whether the support agent is alive.
--
-- * dev_task_messages: the admin writes to Claude inside a development task ("is this still needed?", "close it if it's
--   already in the code"); the agent answers read-only from the code, and may close the task when the admin asked for it.
-- * bot_status: one row the agent touches on every pass and every few minutes (heartbeat). admin_bot_status() shows the
--   admin when it was last seen and where it runs, so a stopped agent is visible instead of an endless spinner.

-- ===== Agent heartbeat =====
create table public.bot_status (
  id boolean primary key default true check (id),
  last_poll_at timestamptz not null default now(),
  host text
);
alter table public.bot_status enable row level security;
revoke all on public.bot_status from anon, authenticated;

create function private.bot_seen(p_host text) returns void
language sql security definer set search_path = '' as $$
  insert into public.bot_status (id, last_poll_at, host) values (true, now(), nullif(left(trim(coalesce(p_host, '')), 80), ''))
  on conflict (id) do update set last_poll_at = now(), host = coalesce(excluded.host, public.bot_status.host);
$$;

create function public.bot_heartbeat(p_token text, p_host text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not private.is_support_agent(p_token) then raise exception 'forbidden' using errcode = '42501'; end if;
  perform private.bot_seen(p_host);
end;
$$;

create function public.admin_bot_status() returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  if not private.is_admin() then raise exception 'admins only' using errcode = '42501'; end if;
  return (select jsonb_build_object('last_poll_at', s.last_poll_at, 'host', s.host) from public.bot_status s);
end;
$$;

-- Older agents don't send a heartbeat; their regular calls count as one.
do $$
declare
  v_name text;
  v_def text;
begin
  foreach v_name in array array['public.bot_pending_threads(text)', 'public.bot_open_dev_tasks(text)'] loop
    select pg_get_functiondef(v_name::regprocedure) into v_def;
    v_def := replace(v_def,
      'if not private.is_support_agent(p_token) then raise exception ''forbidden'' using errcode = ''42501''; end if;',
      'if not private.is_support_agent(p_token) then raise exception ''forbidden'' using errcode = ''42501''; end if;
  perform private.bot_seen(null);');
    execute v_def;
  end loop;
end;
$$;

-- ===== Talking with Claude inside a development task =====
create table public.dev_task_messages (
  id bigint generated always as identity primary key,
  task_id bigint not null references public.dev_tasks(id) on delete cascade,
  from_admin boolean not null,
  body text not null check (char_length(body) between 1 and 8000),
  created_at timestamptz not null default now()
);
create index dev_task_messages_task_idx on public.dev_task_messages(task_id, id);
alter table public.dev_task_messages enable row level security;
revoke all on public.dev_task_messages from anon, authenticated;
grant select on public.dev_task_messages to authenticated;
create policy "dev task messages: admin" on public.dev_task_messages for select to authenticated
  using ((select private.is_admin()));
alter publication supabase_realtime add table public.dev_task_messages;

-- Claude owes an answer in this task.
alter table public.dev_tasks add column ai_pending boolean not null default false;

create function public.admin_dev_task_say(p_task bigint, p_body text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not private.is_admin() then raise exception 'admins only' using errcode = '42501'; end if;
  if char_length(trim(coalesce(p_body, ''))) = 0 then raise exception 'empty message'; end if;
  if not exists (select 1 from public.dev_tasks where id = p_task) then raise exception 'no such task'; end if;
  insert into public.dev_task_messages (task_id, from_admin, body) values (p_task, true, left(trim(p_body), 4000));
  update public.dev_tasks set ai_pending = true where id = p_task;
  perform realtime.send('{}'::jsonb, 'work', 'maskoret-support-agent', false);
end;
$$;

create function public.bot_pending_dev_tasks(p_token text) returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  if not private.is_support_agent(p_token) then raise exception 'forbidden' using errcode = '42501'; end if;
  perform private.bot_seen(null);
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id', d.id, 'title', d.title, 'details', d.details, 'status', d.status, 'created_at', d.created_at,
      'thread_subject', t.subject,
      'messages', (select coalesce(jsonb_agg(jsonb_build_object(
          'id', m.id, 'from_admin', m.from_admin, 'body', m.body, 'at', m.created_at) order by m.id), '[]'::jsonb)
        from public.dev_task_messages m where m.task_id = d.id),
      -- Other open tasks, so Claude can spot a duplicate.
      'other_open_tasks', (select coalesce(jsonb_agg(jsonb_build_object('id', o.id, 'title', o.title) order by o.id), '[]'::jsonb)
        from public.dev_tasks o where o.status = 'open' and o.id <> d.id))
      order by d.id)
    from public.dev_tasks d left join public.support_threads t on t.id = d.thread_id
    where d.ai_pending), '[]'::jsonb);
end;
$$;

-- Claude's answer. p_status ('done' / 'dropped') closes the task — the agent only sends it when the admin asked to close.
create function public.bot_dev_task_reply(p_token text, p_task bigint, p_after bigint, p_body text, p_status text)
returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not private.is_support_agent(p_token) then raise exception 'forbidden' using errcode = '42501'; end if;
  -- The admin wrote again while Claude was thinking: answer the newer message on the next pass.
  if exists (select 1 from public.dev_task_messages where task_id = p_task and from_admin and id > p_after) then
    return;
  end if;
  insert into public.dev_task_messages (task_id, from_admin, body) values (p_task, false, left(p_body, 8000));
  update public.dev_tasks set ai_pending = false,
         status = case when p_status in ('done', 'dropped') then p_status else status end,
         done_at = case when p_status in ('done', 'dropped') then now() else done_at end
   where id = p_task;
end;
$$;

revoke all on function public.bot_heartbeat(text, text), public.admin_bot_status(), public.admin_dev_task_say(bigint, text),
  public.bot_pending_dev_tasks(text), public.bot_dev_task_reply(text, bigint, bigint, text, text) from public;
grant execute on function public.admin_bot_status(), public.admin_dev_task_say(bigint, text) to authenticated;
grant execute on function public.bot_heartbeat(text, text), public.bot_pending_dev_tasks(text),
  public.bot_dev_task_reply(text, bigint, bigint, text, text) to anon, authenticated;
revoke all on function private.bot_seen(text) from public;
