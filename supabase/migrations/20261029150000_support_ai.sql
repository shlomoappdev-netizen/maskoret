-- AI help for support: every new message from a subscriber wakes the support agent on the owner's Mac
-- (tools/support-agent). The agent only reads and proposes; the proposals are visible to the admin alone,
-- and nothing happens until the admin picks an option in the app.
--
-- The agent signs in with a long random token (only its SHA-256 is stored here), so it needs no user account.
-- It is woken by a content-free Realtime broadcast ("ping") and then asks for the work through bot_* functions.

create extension if not exists pgcrypto with schema extensions;

-- ===== Agent token =====
create table private.support_agent_tokens (
  token_hash text primary key,
  created_at timestamptz not null default now(),
  last_used_at timestamptz
);

create function private.is_support_agent(p_token text) returns boolean
language plpgsql security definer set search_path = '' as $$
declare h text := encode(extensions.digest(coalesce(p_token, ''), 'sha256'), 'hex');
begin
  update private.support_agent_tokens set last_used_at = now() where token_hash = h;
  return found;
end;
$$;

-- ===== Thread state =====
alter table public.support_threads
  add column ai_mode text not null default 'on' check (ai_mode in ('on', 'off')),
  add column ai_pending boolean not null default false;

-- ===== Proposals and development tasks (admin only) =====
create table public.support_proposals (
  id bigint generated always as identity primary key,
  thread_id uuid not null references public.support_threads(id) on delete cascade,
  for_message_id bigint not null,
  summary text not null check (char_length(summary) <= 4000),
  options jsonb not null default '[]'::jsonb,
  status text not null default 'pending' check (status in ('pending', 'chosen', 'dismissed', 'superseded')),
  chosen_option text,
  created_at timestamptz not null default now(),
  decided_at timestamptz
);
create index support_proposals_thread_idx on public.support_proposals(thread_id, id desc);

create table public.dev_tasks (
  id bigint generated always as identity primary key,
  thread_id uuid references public.support_threads(id) on delete set null,
  title text not null check (char_length(title) between 1 and 200),
  details text not null default '' check (char_length(details) <= 8000),
  status text not null default 'open' check (status in ('open', 'done', 'dropped')),
  created_at timestamptz not null default now()
);
create index dev_tasks_thread_idx on public.dev_tasks(thread_id);

alter table public.support_proposals enable row level security;
alter table public.dev_tasks enable row level security;
revoke all on public.support_proposals, public.dev_tasks from anon, authenticated;
grant select on public.support_proposals, public.dev_tasks to authenticated;
create policy "proposals: admin" on public.support_proposals for select to authenticated
  using ((select private.is_admin()));
create policy "dev tasks: admin" on public.dev_tasks for select to authenticated
  using ((select private.is_admin()));
alter publication supabase_realtime add table public.support_proposals;

-- ===== Wake the agent on a subscriber's message =====
create function private.support_message_added() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if not new.from_admin then
    update public.support_threads set ai_pending = true where id = new.thread_id and ai_mode = 'on';
    if found then
      -- Public, content-free ping: it only tells the agent to ask (with its token) whether there is work.
      perform realtime.send('{}'::jsonb, 'work', 'maskoret-support-agent', false);
    end if;
  else
    -- The admin answered: earlier proposals no longer apply.
    update public.support_proposals set status = 'superseded'
     where thread_id = new.thread_id and status = 'pending';
    update public.support_threads set ai_pending = false where id = new.thread_id;
  end if;
  return new;
end;
$$;
create trigger support_message_added after insert on public.support_messages
  for each row execute function private.support_message_added();

-- ===== Agent functions (token, callable without an account) =====
-- Threads waiting for a proposal, with what the agent needs to understand them — never financial data.
create function public.bot_pending_threads(p_token text) returns jsonb
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
        from public.support_messages m where m.thread_id = t.id))
      order by t.last_message_at)
    from public.support_threads t
    join public.profiles p on p.id = t.user_id
    join auth.users u on u.id = t.user_id
    where t.ai_pending and t.ai_mode = 'on'), '[]'::jsonb);
end;
$$;

create function public.bot_save_proposal(p_token text, p_thread uuid, p_message_id bigint,
                                         p_summary text, p_options jsonb) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not private.is_support_agent(p_token) then raise exception 'forbidden' using errcode = '42501'; end if;
  if jsonb_typeof(p_options) <> 'array' or jsonb_array_length(p_options) > 6 then raise exception 'bad options'; end if;
  -- A newer message arrived while the agent was thinking: leave the thread pending for another round.
  if exists (select 1 from public.support_messages where thread_id = p_thread and id > p_message_id and not from_admin) then
    return;
  end if;
  update public.support_proposals set status = 'superseded' where thread_id = p_thread and status = 'pending';
  insert into public.support_proposals (thread_id, for_message_id, summary, options)
  values (p_thread, p_message_id, left(p_summary, 4000), p_options);
  update public.support_threads set ai_pending = false where id = p_thread;
end;
$$;

-- ===== Admin decisions =====
create function public.admin_decide_proposal(p_proposal bigint, p_status text, p_option text default null) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not private.is_admin() then raise exception 'admins only' using errcode = '42501'; end if;
  update public.support_proposals set status = p_status, chosen_option = p_option, decided_at = now()
   where id = p_proposal and status = 'pending';
end;
$$;

create function public.admin_set_ai_mode(p_thread uuid, p_mode text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not private.is_admin() then raise exception 'admins only' using errcode = '42501'; end if;
  update public.support_threads set ai_mode = p_mode, ai_pending = false where id = p_thread;
  if p_mode = 'off' then
    update public.support_proposals set status = 'dismissed', decided_at = now()
     where thread_id = p_thread and status = 'pending';
  end if;
end;
$$;

-- Asks for a (new) proposal now, e.g. after turning AI back on.
create function public.admin_request_proposal(p_thread uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not private.is_admin() then raise exception 'admins only' using errcode = '42501'; end if;
  update public.support_threads set ai_mode = 'on', ai_pending = true where id = p_thread;
  perform realtime.send('{}'::jsonb, 'work', 'maskoret-support-agent', false);
end;
$$;

create function public.admin_add_dev_task(p_thread uuid, p_title text, p_details text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not private.is_admin() then raise exception 'admins only' using errcode = '42501'; end if;
  insert into public.dev_tasks (thread_id, title, details) values (p_thread, left(p_title, 200), left(coalesce(p_details, ''), 8000));
end;
$$;

revoke all on function private.is_support_agent(text) from public;
revoke all on function public.bot_pending_threads(text), public.bot_save_proposal(text, uuid, bigint, text, jsonb),
  public.admin_decide_proposal(bigint, text, text), public.admin_set_ai_mode(uuid, text),
  public.admin_request_proposal(uuid), public.admin_add_dev_task(uuid, text, text) from public;
grant execute on function public.bot_pending_threads(text), public.bot_save_proposal(text, uuid, bigint, text, jsonb)
  to anon, authenticated;
grant execute on function public.admin_decide_proposal(bigint, text, text), public.admin_set_ai_mode(uuid, text),
  public.admin_request_proposal(uuid), public.admin_add_dev_task(uuid, text, text) to authenticated;
