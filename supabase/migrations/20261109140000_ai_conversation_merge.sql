-- The AI conversation is merged on the server instead of replaced.
--
-- Each device used to upload its whole conversation, so the last device to save wiped the messages another device
-- had written. Now a device sends what it has; the server joins it with what it keeps (by message id), drops messages
-- from before the newest "new conversation", keeps the newest 200, and returns the result — the one conversation every
-- device shows.

create function public.ai_conversation_merge(p_messages jsonb, p_cleared_at timestamptz) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_old jsonb;
  v_old_cleared timestamptz;
  v_cleared timestamptz;
  v_merged jsonb;
begin
  if v_uid is null then raise exception 'not signed in' using errcode = '42501'; end if;
  if jsonb_typeof(coalesce(p_messages, '[]'::jsonb)) <> 'array' then raise exception 'messages must be a list'; end if;
  insert into public.ai_conversations (user_id) values (v_uid) on conflict (user_id) do nothing;
  select messages, cleared_at into v_old, v_old_cleared from public.ai_conversations where user_id = v_uid for update;
  v_cleared := greatest(v_old_cleared, p_cleared_at);
  with every as (
    select m, upper(m->>'id') as id, (m->>'date')::timestamptz as d, 0 as incoming from jsonb_array_elements(v_old) m
    union all
    select m, upper(m->>'id'), (m->>'date')::timestamptz, 1 from jsonb_array_elements(coalesce(p_messages, '[]'::jsonb)) m
  ), picked as (
    -- One copy per message: the one where the user already decided on its changes, else the device's newer copy.
    select distinct on (id) m, d from every
     where id is not null and d is not null and (v_cleared is null or d > v_cleared)
     order by id, (m ? 'applied') desc, coalesce((m->>'dismissed')::boolean, false) desc, incoming desc
  ), newest as (
    select m, d from picked order by d desc limit 200
  )
  select coalesce(jsonb_agg(m order by d), '[]'::jsonb) into v_merged from newest;
  update public.ai_conversations set messages = v_merged, cleared_at = v_cleared, updated_at = now() where user_id = v_uid;
  return jsonb_build_object('messages', v_merged, 'cleared_at', v_cleared);
end;
$$;

revoke all on function public.ai_conversation_merge(jsonb, timestamptz) from public, anon;
grant execute on function public.ai_conversation_merge(jsonb, timestamptz) to authenticated;
