-- Admins by account id instead of an email in the code (the repository is public).
-- After setting up a new project, add the admin once in the SQL editor:
--   insert into private.admins (user_id) select id from auth.users where email = '<your email>';

create table private.admins (
  user_id uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);
revoke all on private.admins from public, anon, authenticated;

create or replace function private.is_admin() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from private.admins a join auth.users u on u.id = a.user_id
                 where a.user_id = (select auth.uid()) and u.email_confirmed_at is not null);
$$;
