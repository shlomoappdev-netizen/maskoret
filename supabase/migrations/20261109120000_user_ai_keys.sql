-- AI API keys saved in the account, so every device the user signs in on can use them.
--
-- The key itself is kept encrypted in Supabase Vault; the table holds only a pointer to it plus the provider settings.
-- Nobody reads the table directly: the signed-in user saves, lists and deletes their own keys through the functions
-- below, which check auth.uid(). Deleting the account (auth.users) removes the rows, and the trigger removes the
-- encrypted keys with them.

create table public.user_ai_keys (
  user_id uuid not null references auth.users(id) on delete cascade,
  provider text not null check (provider in ('openai', 'anthropic', 'gemini', 'openrouter', 'custom')),
  secret_id uuid not null,
  model text not null default '' check (char_length(model) <= 200),
  base_url text not null default '' check (char_length(base_url) <= 300),
  updated_at timestamptz not null default now(),
  primary key (user_id, provider)
);
alter table public.user_ai_keys enable row level security;
revoke all on public.user_ai_keys from anon, authenticated;

create function private.drop_ai_key_secret() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  delete from vault.secrets where id = old.secret_id;
  return old;
end;
$$;
create trigger user_ai_keys_drop_secret after delete on public.user_ai_keys
  for each row execute function private.drop_ai_key_secret();
revoke all on function private.drop_ai_key_secret() from public;

-- Saves (or replaces) the key of one provider. p_key null keeps the saved key and updates only the model / address.
create function public.ai_key_save(p_provider text, p_key text, p_model text, p_base_url text) returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_secret uuid;
  v_key text := nullif(trim(coalesce(p_key, '')), '');
begin
  if v_uid is null then raise exception 'not signed in' using errcode = '42501'; end if;
  if v_key is not null and char_length(v_key) > 500 then raise exception 'key too long'; end if;
  select secret_id into v_secret from public.user_ai_keys where user_id = v_uid and provider = p_provider;
  if v_secret is null then
    if v_key is null then raise exception 'no key'; end if;
    v_secret := vault.create_secret(v_key, 'ai-key-' || v_uid || '-' || p_provider, 'AI API key of a Maskoret user');
    insert into public.user_ai_keys (user_id, provider, secret_id, model, base_url)
    values (v_uid, p_provider, v_secret, left(coalesce(p_model, ''), 200), left(coalesce(p_base_url, ''), 300));
  else
    if v_key is not null then perform vault.update_secret(v_secret, v_key); end if;
    update public.user_ai_keys
       set model = left(coalesce(p_model, ''), 200), base_url = left(coalesce(p_base_url, ''), 300), updated_at = now()
     where user_id = v_uid and provider = p_provider;
  end if;
end;
$$;

-- The signed-in user's keys, decrypted, newest first.
create function public.ai_keys() returns table (provider text, api_key text, model text, base_url text, updated_at timestamptz)
language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'not signed in' using errcode = '42501'; end if;
  return query
    select k.provider, s.decrypted_secret, k.model, k.base_url, k.updated_at
      from public.user_ai_keys k join vault.decrypted_secrets s on s.id = k.secret_id
     where k.user_id = auth.uid()
     order by k.updated_at desc;
end;
$$;

create function public.ai_key_delete(p_provider text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'not signed in' using errcode = '42501'; end if;
  delete from public.user_ai_keys where user_id = auth.uid() and provider = p_provider;
end;
$$;

revoke all on function public.ai_key_save(text, text, text, text), public.ai_keys(), public.ai_key_delete(text) from public, anon;
grant execute on function public.ai_key_save(text, text, text, text), public.ai_keys(), public.ai_key_delete(text) to authenticated;

-- ===== The AI conversation, shared by the user's devices =====
-- One row per user: the messages (without the attached images, which stay on the device that sent them) and when the
-- conversation was last cleared, so a device that still has older messages doesn't bring them back.
create table public.ai_conversations (
  user_id uuid primary key references auth.users(id) on delete cascade default auth.uid(),
  messages jsonb not null default '[]'::jsonb check (jsonb_typeof(messages) = 'array' and pg_column_size(messages) < 2000000),
  cleared_at timestamptz,
  updated_at timestamptz not null default now()
);
alter table public.ai_conversations enable row level security;
revoke all on public.ai_conversations from anon, authenticated;
grant select, insert, update on public.ai_conversations to authenticated;
create policy "ai conversation: own row" on public.ai_conversations for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
