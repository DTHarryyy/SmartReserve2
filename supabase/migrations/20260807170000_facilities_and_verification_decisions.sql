create extension if not exists citext;

create or replace function public.is_admin(target_id uuid default auth.uid())
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.profiles
    where id = target_id
      and role in ('internal_admin', 'external_admin')
      and account_status = 'active'
  );
$$;

grant execute on function public.is_admin(uuid) to authenticated;

create table if not exists public.facilities (
  id uuid primary key default gen_random_uuid(),
  name citext not null check (length(trim(name::text)) between 3 and 60),
  room text not null default '',
  building text not null check (length(trim(building)) > 0),
  category text not null check (length(trim(category)) > 0),
  capacity integer not null check (capacity between 1 and 5000),
  status text not null default 'active'
    check (status in ('active', 'under_review', 'maintenance', 'draft')),
  pin_confidence text not null default 'none'
    check (pin_confidence in ('verified', 'needs_check', 'none')),
  campus_name text not null default 'CSU Aparri Campus',
  floor text not null default 'Ground floor',
  latitude double precision,
  longitude double precision,
  accuracy integer check (accuracy is null or accuracy >= 0),
  confirmed_outside boolean not null default false,
  description text not null default '',
  geo_building text not null default '',
  street text not null default '',
  barangay text not null default '',
  municipality text not null default '',
  province text not null default '',
  region text not null default '',
  country text not null default '',
  geo_edited text[] not null default '{}',
  amenities text[] not null default '{}',
  photo_paths text[] not null default '{}',
  requires_approval boolean not null default true,
  public_listing boolean not null default true,
  open_days boolean[] not null default array[true, true, true, true, true, false, false],
  open_time time not null default '07:00',
  close_time time not null default '19:00',
  max_duration text not null default '4 hours',
  advance_booking text not null default '30 days ahead',
  booking_buffer text not null default '15 minutes',
  booking_count integer not null default 0 check (booking_count >= 0),
  created_by uuid references public.profiles(id) on delete set null,
  updated_by uuid references public.profiles(id) on delete set null,
  updated_by_name text not null default 'Imported record',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  archived_at timestamptz,
  constraint facilities_coordinates_together check (
    (latitude is null and longitude is null) or
    (latitude is not null and longitude is not null and
      latitude between -90 and 90 and longitude between -180 and 180)
  ),
  constraint facilities_open_days_length check (cardinality(open_days) = 7),
  constraint facilities_photo_limit check (cardinality(photo_paths) <= 8),
  constraint facilities_hours_order check (open_time < close_time)
);

create unique index if not exists facilities_active_name_key
on public.facilities (lower(name::text))
where archived_at is null;

create or replace function public.set_facility_actor()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  actor_id uuid := auth.uid();
  actor_name text;
begin
  new.updated_at = now();
  if actor_id is not null then
    select full_name into actor_name from public.profiles where id = actor_id;
    new.updated_by = actor_id;
    new.updated_by_name = coalesce(nullif(actor_name, ''), 'Administrator');
    if tg_op = 'INSERT' then
      new.created_by = actor_id;
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists facilities_set_actor on public.facilities;
create trigger facilities_set_actor
before insert or update on public.facilities
for each row execute procedure public.set_facility_actor();

alter table public.facilities enable row level security;
grant select, insert, update on public.facilities to authenticated;

drop policy if exists facilities_select on public.facilities;
create policy facilities_select on public.facilities
for select to authenticated
using (
  public.is_admin()
  or (
    archived_at is null
    and public_listing
    and status <> 'draft'
  )
);

drop policy if exists facilities_insert_admin on public.facilities;
create policy facilities_insert_admin on public.facilities
for insert to authenticated
with check (public.is_admin());

drop policy if exists facilities_update_admin on public.facilities;
create policy facilities_update_admin on public.facilities
for update to authenticated
using (public.is_admin())
with check (public.is_admin());

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'facility-photos',
  'facility-photos',
  true,
  10485760,
  array['image/jpeg', 'image/png']
)
on conflict (id) do update
set public = true,
    file_size_limit = 10485760,
    allowed_mime_types = array['image/jpeg', 'image/png'];

drop policy if exists facility_photos_public_read on storage.objects;
create policy facility_photos_public_read on storage.objects
for select to public
using (bucket_id = 'facility-photos');

drop policy if exists facility_photos_insert_admin on storage.objects;
create policy facility_photos_insert_admin on storage.objects
for insert to authenticated
with check (bucket_id = 'facility-photos' and public.is_admin());

drop policy if exists facility_photos_update_admin on storage.objects;
create policy facility_photos_update_admin on storage.objects
for update to authenticated
using (bucket_id = 'facility-photos' and public.is_admin())
with check (bucket_id = 'facility-photos' and public.is_admin());

drop policy if exists facility_photos_delete_admin on storage.objects;
create policy facility_photos_delete_admin on storage.objects
for delete to authenticated
using (bucket_id = 'facility-photos' and public.is_admin());

insert into public.facilities (
  id, name, room, building, category, capacity, status, pin_confidence,
  floor, latitude, longitude, accuracy, description, amenities,
  requires_approval, open_days, open_time, close_time, max_duration,
  advance_booking, booking_count, updated_by_name, updated_at
)
values
  (
    '10000000-0000-0000-0000-000000000001', 'Computer Laboratory 1',
    'CICS-201', 'College of Information and Computing Sciences',
    'Computer Laboratory', 40, 'active', 'verified', '2nd floor',
    18.351092, 121.649970, 3,
    'Forty workstations with dual monitors, used by BSIT and BSCS majors. Fixed ceiling projector and a wall-mounted whiteboard.',
    array['Wi-Fi', 'Air Conditioning', 'Projector', 'Power Outlets', 'PWD Accessibility'],
    true, array[true,true,true,true,true,false,false], '07:00', '19:00',
    '4 hours', '30 days ahead', 18, 'R. Aguinaldo', '2026-07-14 00:00:00+00'
  ),
  (
    '10000000-0000-0000-0000-000000000002', 'Marine Biology Wet Lab',
    'CFMS-105', 'College of Fisheries and Marine Sciences',
    'Science Laboratory', 24, 'active', 'verified', 'Ground floor',
    18.350292, 121.649070, 4,
    'Running-seawater benches for coastal sampling work. Requires a faculty supervisor present at all times.',
    array['Wi-Fi', 'Power Outlets', 'Security Cameras', 'Generator'],
    true, array[true,true,true,true,true,true,false], '07:00', '17:00',
    '8 hours', '14 days ahead', 7, 'A. Bautista', '2026-07-02 00:00:00+00'
  ),
  (
    '10000000-0000-0000-0000-000000000003', 'University Auditorium',
    'ADM-G01', 'Administration Building', 'Auditorium', 420, 'active',
    'verified', 'Ground floor', 18.352232, 121.647860, 5,
    'Main assembly hall with a raised stage, house sound and tiered seating. Used for convocations and college-wide ceremonies.',
    array['Wi-Fi', 'Air Conditioning', 'Sound System', 'Projector', 'PWD Accessibility', 'Parking'],
    true, array[true,true,true,true,true,true,true], '07:00', '21:00',
    'Full day', 'One semester', 24, 'R. Aguinaldo', '2026-06-21 00:00:00+00'
  ),
  (
    '10000000-0000-0000-0000-000000000004', 'Reading Hall B', 'LIB-202',
    'Library and Learning Resource Center', 'Library Space', 80,
    'under_review', 'needs_check', '2nd floor', 18.352522, 121.649460, 12,
    'Quiet study hall on the second floor, bookable for tutoring clinics outside library peak hours.',
    array['Wi-Fi', 'Air Conditioning', 'Power Outlets'], true,
    array[true,true,true,true,true,false,false], '08:00', '18:00',
    '4 hours', '30 days ahead', 11, 'M. Santos', '2026-07-09 00:00:00+00'
  ),
  (
    '10000000-0000-0000-0000-000000000005', 'Main Court', 'GYM-001',
    'Gymnasium and Sports Complex', 'Gymnasium', 900, 'maintenance',
    'verified', 'Ground floor', 18.349732, 121.647670, 6,
    'Full-size covered court with bleachers. Currently closed for roof repair — existing bookings were relocated.',
    array['Sound System', 'Parking', 'Security Cameras', 'PWD Accessibility'],
    true, array[true,true,true,true,true,true,true], '06:00', '20:00',
    'Full day', '60 days ahead', 3, 'R. Aguinaldo', '2026-07-18 00:00:00+00'
  ),
  (
    '10000000-0000-0000-0000-000000000006', 'Faculty Conference Room',
    'ADM-304', 'Administration Building', 'Conference Room', 18, 'draft',
    'none', '3rd floor', null, null, null,
    'Small meeting room for departmental and closed-door sessions. Location has not been pinned yet.',
    array['Wi-Fi', 'Air Conditioning', 'Smart TV', 'Whiteboard'], true,
    array[true,true,true,true,true,false,false], '08:00', '17:00',
    '2 hours', '14 days ahead', 0, 'M. Santos', '2026-07-03 00:00:00+00'
  )
on conflict do nothing;

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'facilities'
  ) then
    alter publication supabase_realtime add table public.facilities;
  end if;
end;
$$;

-- A final decision clears document_path after Storage deletion. Do not let
-- that metadata-only update run the onboarding sync and reset a verified or
-- rejected profile back to pending.
drop trigger if exists verification_submission_profile_sync
on public.verification_submissions;
create trigger verification_submission_profile_sync
after insert or update of claim_type, campus_id, unit
on public.verification_submissions
for each row execute procedure public.sync_profile_from_verification();

create or replace function public.decide_verification_atomic(
  p_submission_id uuid,
  p_decision text,
  p_reason text,
  p_actor uuid
)
returns table (submission_id uuid, user_id uuid, document_path text, status text)
language plpgsql
security definer
set search_path = public
as $$
declare
  submission public.verification_submissions%rowtype;
begin
  if not public.is_internal_admin(p_actor) then
    raise exception using errcode = '42501', message = 'Forbidden';
  end if;
  if p_decision not in ('approved', 'changes_requested', 'rejected') then
    raise exception using errcode = '22023', message = 'Invalid decision';
  end if;
  if p_decision in ('changes_requested', 'rejected') and nullif(trim(p_reason), '') is null then
    raise exception using errcode = '22023', message = 'A reason is required';
  end if;

  select * into submission
  from public.verification_submissions
  where id = p_submission_id
  for update;

  if not found then
    raise exception using errcode = 'P0002', message = 'Submission not found';
  end if;
  if submission.status <> 'pending' then
    raise exception using errcode = '40001', message = 'Submission was already decided';
  end if;

  update public.verification_submissions
  set status = p_decision,
      reason = nullif(trim(p_reason), ''),
      decided_at = now(),
      decided_by = p_actor
  where id = p_submission_id;

  update public.profiles
  set verification_status = case p_decision
    when 'approved' then 'verified'
    when 'rejected' then 'rejected'
    else 'pending'
  end
  where id = submission.user_id;

  return query select submission.id, submission.user_id,
    submission.document_path, p_decision;
end;
$$;
