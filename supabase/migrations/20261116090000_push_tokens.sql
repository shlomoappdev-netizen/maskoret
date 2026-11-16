-- Push notifications from the assistant (Android, through Firebase Cloud Messaging).
--
-- A phone saves its FCM token here when the user is signed in. When a device finds a new alert in the household's
-- data (a trend over its limit, a month in the red…), it calls the edge function `assistant-push`, which sends it to
-- the phones of the household's members: each alert once, and at most one notification a day per user.
-- Nobody reads these tables directly: the app only saves and deletes its own token through the functions below;
-- the edge function works with the service role.

create table public.push_tokens (
  token text primary key check (char_length(token) between 20 and 4096),
  user_id uuid not null references auth.users(id) on delete cascade,
  platform text not null check (platform in ('android')),
  updated_at timestamptz not null default now()
);
create index push_tokens_user_idx on public.push_tokens(user_id);
alter table public.push_tokens enable row level security;
revoke all on public.push_tokens from anon, authenticated;

-- When each user last got a notification (the once-a-day limit).
create table public.push_state (
  user_id uuid primary key references auth.users(id) on delete cascade,
  last_push_at timestamptz not null
);
alter table public.push_state enable row level security;
revoke all on public.push_state from anon, authenticated;

-- Alerts already sent to a household, so each goes out once. Only the alert's id is kept, never its text.
create table public.push_alerts (
  household_id uuid not null references public.households(id) on delete cascade,
  alert_id text not null check (char_length(alert_id) between 1 and 200),
  sent_at timestamptz not null default now(),
  primary key (household_id, alert_id)
);
alter table public.push_alerts enable row level security;
revoke all on public.push_alerts from anon, authenticated;

-- Saves this phone's token for the signed-in user (a phone that changed accounts moves with it).
create function public.push_token_save(p_token text, p_platform text) returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'not signed in' using errcode = '42501'; end if;
  insert into public.push_tokens (token, user_id, platform)
  values (p_token, v_uid, p_platform)
  on conflict (token) do update set user_id = excluded.user_id, platform = excluded.platform, updated_at = now();
end;
$$;

-- Signing out: this phone stops getting the account's notifications.
create function public.push_token_delete(p_token text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  delete from public.push_tokens where token = p_token and user_id = auth.uid();
end;
$$;

revoke all on function public.push_token_save(text, text), public.push_token_delete(text) from public, anon;
grant execute on function public.push_token_save(text, text), public.push_token_delete(text) to authenticated;
