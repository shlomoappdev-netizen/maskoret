-- App updates for Android and Windows: GitHub Actions uploads each build here (with the service key),
-- and the apps read releases/latest.json to find a newer version. Public read, no public write.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('releases', 'releases', true, 52428800,
        array['application/json', 'application/vnd.android.package-archive', 'application/zip', 'application/octet-stream'])
on conflict (id) do update
  set public = excluded.public, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;
