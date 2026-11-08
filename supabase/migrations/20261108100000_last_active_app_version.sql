-- The admin's "כניסה אחרונה" showed auth.users.last_sign_in_at, which changes only on a fresh sign-in with a password
-- or a link; a subscriber who stays signed in kept the date they signed up. Last activity now comes from the
-- refreshes of their sessions (every app that's open refreshes its token), and from the app's own report.
-- The app also reports which version it runs (report_app_seen), shown in the subscriber's details.

alter table public.profiles
  add column if not exists app_version text,
  add column if not exists app_platform text,
  add column if not exists last_seen_at timestamptz;

-- The latest sign of life of a user: a sign-in, a session refresh, or the app's report.
create or replace function private.last_active(uid uuid)
returns timestamptz
language sql
stable
security definer
set search_path = ''
as $$
  select greatest(
    (select u.last_sign_in_at from auth.users u where u.id = uid),
    (select max(greatest(s.updated_at, s.refreshed_at at time zone 'utc')) from auth.sessions s where s.user_id = uid),
    (select p.last_seen_at from public.profiles p where p.id = uid));
$$;
revoke all on function private.last_active(uuid) from public, anon, authenticated;

-- Called by the app when it opens (signed in): the version it runs and on which platform.
create or replace function public.report_app_seen(p_version text, p_platform text)
returns void
language sql
security definer
set search_path = ''
as $$
  update public.profiles
     set app_version = left(nullif(trim(p_version), ''), 40),
         app_platform = left(nullif(trim(p_platform), ''), 20),
         last_seen_at = now()
   where id = auth.uid();
$$;
revoke all on function public.report_app_seen(text, text) from public, anon;
grant execute on function public.report_app_seen(text, text) to authenticated;

-- The admin functions: "last_sign_in_at" (the key the apps read) is now the last activity, plus the version.
do $mig$
declare
  f text;
  def text;
begin
  foreach f in array array['admin_overview()', 'admin_user_detail(uuid)', 'bot_pending_threads(text)'] loop
    def := pg_get_functiondef(('public.' || f)::regprocedure);
    def := replace(def, $r$'last_sign_in_at', u.last_sign_in_at$r$,
      $r$'last_sign_in_at', private.last_active(u.id), 'app_version', p.app_version, 'app_platform', p.app_platform$r$);
    execute def;
  end loop;

  def := pg_get_functiondef('public.admin_search_users(text, text, integer, integer)'::regprocedure);
  def := replace(def, 'p.display_name, p.member_no' || chr(10), 'p.display_name, p.member_no, p.app_version, p.app_platform' || chr(10));
  def := replace(def, $r$'last_sign_in_at', x.last_sign_in_at$r$,
    $r$'last_sign_in_at', private.last_active(x.id), 'app_version', x.app_version, 'app_platform', x.app_platform$r$);
  execute def;

  def := pg_get_functiondef('public.admin_stats()'::regprocedure);
  def := replace(def, $r$(select count(*) from auth.users where last_sign_in_at > now() - interval '7 days')$r$,
    $r$(select count(*) from auth.users u where private.last_active(u.id) > now() - interval '7 days')$r$);
  execute def;
end
$mig$;
