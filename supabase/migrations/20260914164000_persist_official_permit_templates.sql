-- Edge Function static assets can be silently omitted by CLI deployments when
-- Docker is unavailable. Approved permit forms are persisted in a private
-- Storage bucket instead, and the generator hash-locks them before use.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'permit-templates',
  'permit-templates',
  false,
  10485760,
  array['application/pdf']::text[]
)
on conflict (id) do update
set public = false,
    file_size_limit = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types;

create policy "Internal admins manage approved permit templates"
on storage.objects
for all
to authenticated
using (
  bucket_id = 'permit-templates'
  and public.is_internal_admin()
)
with check (
  bucket_id = 'permit-templates'
  and public.is_internal_admin()
);
