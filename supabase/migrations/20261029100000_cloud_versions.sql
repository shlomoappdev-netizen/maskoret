-- Everything lives on the server: the version history replaces local backups.
-- A device can add its own version to the history (e.g. the side that lost a sync conflict),
-- and the history keeps the newest 30 by time.

alter table public.household_snapshots add column note text;

create or replace function private.snapshot_household_data() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.household_snapshots (household_id, data, revision, saved_at, updated_by, device)
  values (old.household_id, old.data, old.revision, old.updated_at, old.updated_by, old.device);
  delete from public.household_snapshots s
   where s.household_id = old.household_id
     and s.id not in (select id from public.household_snapshots
                      where household_id = old.household_id order by saved_at desc, id desc limit 30);
  return new;
end;
$$;

create function public.save_household_snapshot(hid uuid, p_data jsonb, p_device text default null, p_note text default null)
returns void language plpgsql security definer set search_path = '' as $$
declare rev bigint;
begin
  if not private.is_member(hid) then raise exception 'not a member' using errcode = '42501'; end if;
  if octet_length(p_data::text) > 20 * 1024 * 1024 then raise exception 'data too large'; end if;
  select revision into rev from public.household_data where household_id = hid;
  insert into public.household_snapshots (household_id, data, revision, saved_at, updated_by, device, note)
  values (hid, p_data, coalesce(rev, 0), now(), auth.uid(), left(p_device, 80), left(p_note, 200));
  delete from public.household_snapshots s
   where s.household_id = hid
     and s.id not in (select id from public.household_snapshots
                      where household_id = hid order by saved_at desc, id desc limit 30);
end;
$$;

revoke all on function public.save_household_snapshot(uuid, jsonb, text, text) from public, anon;
grant execute on function public.save_household_snapshot(uuid, jsonb, text, text) to authenticated;
