-- Immutable e-signature records for reservation permits.  CEO source files
-- remain private; ordinary users receive only an Edge Function rendition.

create table if not exists public.ceo_signature_revisions (
  id uuid primary key default gen_random_uuid(),
  storage_path text not null unique,
  file_name text not null,
  mime_type text not null check (mime_type in ('image/png', 'image/jpeg')),
  byte_size integer not null check (byte_size between 1 and 5242880),
  sha256 text not null,
  active boolean not null default true,
  uploaded_by uuid not null references public.profiles(id) on delete restrict,
  uploaded_at timestamptz not null default now(),
  replaced_at timestamptz
);

create unique index if not exists ceo_signature_revisions_one_active_idx
  on public.ceo_signature_revisions ((active)) where active;

create table if not exists public.reservation_signature_requests (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null references public.reservation_requests(id) on delete cascade,
  requester_id uuid not null references public.profiles(id) on delete restrict,
  status text not null default 'requested'
    check (status in ('requested', 'signed', 'superseded')),
  requested_by uuid not null references public.profiles(id) on delete restrict,
  requested_at timestamptz not null default now(),
  signed_at timestamptz,
  superseded_at timestamptz,
  check ((status = 'signed') = (signed_at is not null))
);

create unique index if not exists reservation_signature_requests_one_open_idx
  on public.reservation_signature_requests (request_id) where status = 'requested';

create table if not exists public.reservation_user_signatures (
  id uuid primary key default gen_random_uuid(),
  signature_request_id uuid not null unique references public.reservation_signature_requests(id) on delete restrict,
  request_id uuid not null references public.reservation_requests(id) on delete cascade,
  requester_id uuid not null references public.profiles(id) on delete restrict,
  storage_path text not null unique,
  file_name text not null,
  mime_type text not null check (mime_type in ('image/png', 'image/jpeg')),
  byte_size integer not null check (byte_size between 1 and 5242880),
  sha256 text not null,
  submitted_at timestamptz not null default now()
);

alter table public.reservation_permits
  add column if not exists user_signature_id uuid references public.reservation_user_signatures(id) on delete restrict,
  add column if not exists ceo_signature_id uuid references public.ceo_signature_revisions(id) on delete restrict;

alter table public.ceo_signature_revisions enable row level security;
alter table public.reservation_signature_requests enable row level security;
alter table public.reservation_user_signatures enable row level security;

grant select on public.reservation_signature_requests, public.reservation_user_signatures to authenticated;
create policy reservation_signature_requests_read on public.reservation_signature_requests
  for select to authenticated using (
    requester_id = auth.uid() or public.can_manage_reservation(request_id)
  );
create policy reservation_user_signatures_read on public.reservation_user_signatures
  for select to authenticated using (
    requester_id = auth.uid() or public.can_manage_reservation(request_id)
  );
revoke all on public.ceo_signature_revisions from anon, authenticated;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('reservation-signatures', 'reservation-signatures', false, 5242880, array['image/png', 'image/jpeg'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('ceo-signatures', 'ceo-signatures', false, 5242880, array['image/png', 'image/jpeg'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

create policy reservation_signature_upload_own on storage.objects
  for insert to authenticated with check (
    bucket_id = 'reservation-signatures'
    and (storage.foldername(name))[1] = auth.uid()::text
    and exists (
      select 1 from public.reservation_signature_requests request
      where request.request_id::text = (storage.foldername(name))[2]
        and request.requester_id = auth.uid()
        and request.status = 'requested'
    )
  );
create policy reservation_signature_read_own on storage.objects
  for select to authenticated using (
    bucket_id = 'reservation-signatures' and exists (
      select 1 from public.reservation_user_signatures s
      where s.storage_path = name and (s.requester_id = auth.uid() or public.can_manage_reservation(s.request_id))
    )
  );

create or replace function public.record_ceo_signature_replacement(
  p_storage_path text, p_file_name text, p_mime_type text,
  p_byte_size integer, p_sha256 text, p_actor_id uuid
) returns public.ceo_signature_revisions language plpgsql security definer set search_path = public as $$
declare result public.ceo_signature_revisions;
begin
  if not exists (select 1 from profiles where id = p_actor_id and role = 'internal_admin' and account_status = 'active') then
    raise exception 'Only Internal Admins may replace the CEO signature' using errcode = '42501';
  end if;
  if p_mime_type not in ('image/png', 'image/jpeg') or p_byte_size not between 1 and 5242880 then
    raise exception 'CEO signature must be a PNG or JPEG no larger than 5 MB' using errcode = '22023';
  end if;
  update ceo_signature_revisions set active = false, replaced_at = now() where active;
  insert into ceo_signature_revisions(storage_path,file_name,mime_type,byte_size,sha256,uploaded_by)
  values(p_storage_path,p_file_name,p_mime_type,p_byte_size,p_sha256,p_actor_id) returning * into result;
  insert into audit_entries(entity_type, target_label, actor_id, actor_name, actor_role, action, source_type, source_id, details)
  select 'system', 'CEO permit signature', p_actor_id,
    coalesce(nullif(full_name, ''), email, 'the system'), coalesce(role, 'system'),
    'replaced CEO permit signature', 'ceo_signature_revision', result.id,
    jsonb_build_object('revision_id', result.id)
  from profiles where id = p_actor_id;
  return result;
end $$;
revoke all on function public.record_ceo_signature_replacement(text,text,text,integer,text,uuid) from public, anon, authenticated;
grant execute on function public.record_ceo_signature_replacement(text,text,text,integer,text,uuid) to service_role;

create or replace function public.request_reservation_signature(p_request_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare req reservation_requests%rowtype; actor uuid := auth.uid();
begin
  if not exists (select 1 from profiles where id = actor and role = 'internal_admin' and account_status = 'active') then raise exception 'Only Internal Admins may request signatures' using errcode = '42501'; end if;
  select * into req from reservation_requests where id = p_request_id for update;
  if not found or req.reservation_status <> 'confirmed' or coalesce(req.total_amount_centavos,0) > coalesce((select sum(amount_centavos) from payment_transactions where request_id=req.id and status='verified'),0) then
    raise exception 'A signature can be requested only for a confirmed, fully paid reservation' using errcode = '22023';
  end if;
  if not exists(select 1 from ceo_signature_revisions where active) then raise exception 'An active CEO signature is required' using errcode = '22023'; end if;
  update reservation_signature_requests set status='superseded', superseded_at=now() where request_id=req.id and status='requested';
  insert into reservation_signature_requests(request_id, requester_id, requested_by) values(req.id, req.requester_id, actor);
  perform public.notify_reservation_user(req.id, public.reservation_event(req.id, 'requested reservation e-signature'), 'signature_requested', 'E-signature requested', 'Your confirmed reservation is ready for signature.');
end $$;
grant execute on function public.request_reservation_signature(uuid) to authenticated;

create or replace function public.submit_reservation_signature(
  p_signature_request_id uuid, p_storage_path text, p_file_name text, p_mime_type text, p_byte_size integer, p_sha256 text
) returns void language plpgsql security definer set search_path = public as $$
declare signature_request reservation_signature_requests%rowtype; actor uuid := auth.uid();
begin
  select * into signature_request from reservation_signature_requests where id=p_signature_request_id for update;
  if not found or signature_request.requester_id <> actor or signature_request.status <> 'requested' then raise exception 'This signature request is no longer available' using errcode = '42501'; end if;
  if p_mime_type not in ('image/png','image/jpeg') or p_byte_size not between 1 and 5242880 or split_part(p_storage_path,'/',1) <> actor::text then raise exception 'Invalid signature upload' using errcode = '22023'; end if;
  insert into reservation_user_signatures(signature_request_id,request_id,requester_id,storage_path,file_name,mime_type,byte_size,sha256)
  values(signature_request.id,signature_request.request_id,actor,p_storage_path,p_file_name,p_mime_type,p_byte_size,p_sha256);
  update reservation_signature_requests set status='signed',signed_at=now() where id=signature_request.id;
  perform public.notify_reservation_user(signature_request.request_id, public.reservation_event(signature_request.request_id, 'submitted reservation e-signature'), 'signature_submitted', 'E-signature submitted', 'Your reservation permit is being issued.');
  perform public.issue_reservation_permit(signature_request.request_id);
end $$;
grant execute on function public.submit_reservation_signature(uuid,text,text,text,integer,text) to authenticated;

notify pgrst, 'reload schema';
