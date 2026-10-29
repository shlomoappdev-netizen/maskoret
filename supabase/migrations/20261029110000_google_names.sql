-- Google sign-in gives the name as full_name / name (email sign-ups use display_name).
create or replace function private.handle_new_user() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.profiles (id, display_name, email)
  values (new.id,
          coalesce(left(coalesce(nullif(new.raw_user_meta_data ->> 'display_name', ''),
                                 nullif(new.raw_user_meta_data ->> 'full_name', ''),
                                 new.raw_user_meta_data ->> 'name'), 80), ''),
          new.email);
  return new;
end;
$$;
