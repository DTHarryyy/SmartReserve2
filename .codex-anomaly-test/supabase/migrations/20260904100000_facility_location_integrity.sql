create extension if not exists citext;

create table if not exists public.campus_map_features (
  id uuid primary key default gen_random_uuid(),
  campus_name text not null default 'CSU Aparri Campus',
  name citext not null,
  feature_type text not null default 'building'
    check (feature_type in ('building', 'outdoor_area', 'entrance', 'annex', 'landmark')),
  latitude double precision not null check (latitude between -90 and 90),
  longitude double precision not null check (longitude between -180 and 180),
  service_radius_m integer not null default 90 check (service_radius_m between 5 and 500),
  source_name text not null default 'SmartReserve initial campus map',
  surveyed_at timestamptz,
  verified_by uuid references public.profiles(id) on delete set null,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (campus_name, name)
);

alter table public.campus_map_features enable row level security;
revoke all on public.campus_map_features from public, anon, authenticated;
grant select on public.campus_map_features to authenticated;

drop policy if exists campus_map_features_select_authenticated on public.campus_map_features;
create policy campus_map_features_select_authenticated
on public.campus_map_features for select to authenticated
using (active or public.is_admin());

insert into public.campus_map_features
  (campus_name, name, feature_type, latitude, longitude, service_radius_m, source_name)
values
  ('CSU Aparri Campus', 'Administration Building', 'building', 18.352232, 121.647860, 90, 'SmartReserve initial campus map'),
  ('CSU Aparri Campus', 'College of Information and Computing Sciences', 'building', 18.351092, 121.649970, 90, 'SmartReserve initial campus map'),
  ('CSU Aparri Campus', 'College of Fisheries and Marine Sciences', 'building', 18.350292, 121.649070, 90, 'SmartReserve initial campus map'),
  ('CSU Aparri Campus', 'Science Laboratory Building', 'building', 18.351862, 121.650430, 90, 'SmartReserve initial campus map'),
  ('CSU Aparri Campus', 'Library and Learning Resource Center', 'building', 18.352522, 121.649460, 90, 'SmartReserve initial campus map'),
  ('CSU Aparri Campus', 'Gymnasium and Sports Complex', 'building', 18.349732, 121.647670, 90, 'SmartReserve initial campus map'),
  ('CSU Aparri Campus', 'Student Center', 'building', 18.351932, 121.648970, 90, 'SmartReserve initial campus map'),
  ('CSU Aparri Campus', 'Technology and Livelihood Building', 'building', 18.350662, 121.650900, 90, 'SmartReserve initial campus map')
on conflict (campus_name, name) do update
set latitude = excluded.latitude,
    longitude = excluded.longitude,
    service_radius_m = excluded.service_radius_m,
    source_name = excluded.source_name,
    active = true,
    updated_at = now();

alter table public.facilities
  add column if not exists map_feature_id uuid references public.campus_map_features(id) on delete set null,
  add column if not exists location_review_status text not null default 'no_pin',
  add column if not exists location_validation_distance_m numeric,
  add column if not exists location_reviewed_by uuid references public.profiles(id) on delete set null,
  add column if not exists location_reviewed_at timestamptz,
  add column if not exists location_review_note text not null default '',
  add column if not exists location_override_reason text not null default '',
  add column if not exists location_review_version integer not null default 1;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'facilities_location_review_status_check'
      and conrelid = 'public.facilities'::regclass
  ) then
    alter table public.facilities
      add constraint facilities_location_review_status_check
      check (location_review_status in (
        'no_pin',
        'needs_review',
        'verified',
        'verified_exception',
        'rejected'
      ));
  end if;
end $$;

create index if not exists facilities_location_review_status_idx
  on public.facilities(location_review_status)
  where archived_at is null;

create index if not exists facilities_map_feature_idx
  on public.facilities(map_feature_id)
  where archived_at is null;

create table if not exists public.facility_location_reviews (
  id uuid primary key default gen_random_uuid(),
  facility_id uuid not null references public.facilities(id) on delete cascade,
  reviewer_id uuid references public.profiles(id) on delete set null,
  decision text not null check (decision in ('verify', 'verify_exception', 'reject', 'auto_needs_review')),
  note text not null default '',
  before_status text,
  after_status text not null,
  distance_m numeric,
  map_feature_id uuid references public.campus_map_features(id) on delete set null,
  idempotency_key uuid not null,
  created_at timestamptz not null default now(),
  unique (reviewer_id, idempotency_key)
);

alter table public.facility_location_reviews enable row level security;
revoke all on public.facility_location_reviews from public, anon, authenticated;
grant select on public.facility_location_reviews to authenticated;

drop policy if exists facility_location_reviews_select_authorized on public.facility_location_reviews;
create policy facility_location_reviews_select_authorized
on public.facility_location_reviews for select to authenticated
using (public.is_internal_admin() or public.can_manage_facility(facility_id));

create or replace function public.facility_distance_m(
  p_lat1 double precision,
  p_lng1 double precision,
  p_lat2 double precision,
  p_lng2 double precision
) returns numeric
language sql
immutable
parallel safe
as $$
  select round((
    6371000 * acos(least(1.0, greatest(-1.0,
      cos(radians(p_lat1)) * cos(radians(p_lat2)) *
      cos(radians(p_lng2) - radians(p_lng1)) +
      sin(radians(p_lat1)) * sin(radians(p_lat2))
    )))
  )::numeric, 1);
$$;

revoke all on function public.facility_distance_m(double precision, double precision, double precision, double precision)
from public, anon, authenticated;
grant execute on function public.facility_distance_m(double precision, double precision, double precision, double precision)
to authenticated, service_role;

create or replace function public.apply_facility_location_integrity()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  feature_row public.campus_map_features%rowtype;
  distance_value numeric;
  location_changed boolean;
  manual_status text;
begin
  location_changed := tg_op = 'INSERT'
    or old.latitude is distinct from new.latitude
    or old.longitude is distinct from new.longitude
    or old.building is distinct from new.building
    or old.campus_name is distinct from new.campus_name
    or old.map_feature_id is distinct from new.map_feature_id
    or old.confirmed_outside is distinct from new.confirmed_outside;

  manual_status := coalesce(new.location_review_status, 'no_pin');

  if new.latitude is null or new.longitude is null then
    new.map_feature_id := null;
    new.location_validation_distance_m := null;
    new.location_review_status := 'no_pin';
    new.pin_confidence := 'none';
    new.location_reviewed_by := null;
    new.location_reviewed_at := null;
    new.location_review_note := '';
    new.location_override_reason := '';
    return new;
  end if;

  if new.map_feature_id is not null then
    select *
      into feature_row
    from public.campus_map_features
    where id = new.map_feature_id
      and active
    limit 1;
  end if;

  if feature_row.id is null then
    select *
      into feature_row
    from public.campus_map_features
    where campus_name = new.campus_name
      and lower(name::text) = lower(new.building)
      and active
    order by feature_type = 'building' desc, created_at
    limit 1;
  end if;

  if feature_row.id is not null then
    new.map_feature_id := feature_row.id;
    distance_value := public.facility_distance_m(
      new.latitude,
      new.longitude,
      feature_row.latitude,
      feature_row.longitude
    );
    new.location_validation_distance_m := distance_value;
  else
    new.map_feature_id := null;
    new.location_validation_distance_m := null;
  end if;

  if not location_changed and manual_status in ('verified', 'verified_exception') then
    new.location_review_status := manual_status;
    new.pin_confidence := 'verified';
    return new;
  end if;

  new.location_reviewed_by := null;
  new.location_reviewed_at := null;
  new.location_review_note := '';
  new.location_override_reason := '';

  if new.confirmed_outside
     or feature_row.id is null
     or distance_value is null
     or distance_value > feature_row.service_radius_m
     or coalesce(new.accuracy, 999999) > 15 then
    new.location_review_status := 'needs_review';
    new.pin_confidence := 'needs_check';
    if new.status = 'active' and new.confirmed_outside then
      new.status := 'under_review';
    end if;
  else
    new.location_review_status := 'verified';
    new.pin_confidence := 'verified';
  end if;

  return new;
end;
$$;

drop trigger if exists facilities_location_integrity on public.facilities;
create trigger facilities_location_integrity
before insert or update on public.facilities
for each row execute function public.apply_facility_location_integrity();

create or replace function public.decide_facility_location_review(
  p_facility_id uuid,
  p_decision text,
  p_note text default '',
  p_idempotency_key uuid default gen_random_uuid()
) returns public.facilities
language plpgsql
security definer
set search_path = public
as $$
declare
  actor public.profiles%rowtype;
  facility_row public.facilities%rowtype;
  feature_row public.campus_map_features%rowtype;
  before_status text;
  after_status text;
  note_value text := trim(coalesce(p_note, ''));
  distance_value numeric;
begin
  select *
    into actor
  from public.profiles
  where id = auth.uid()
    and role in ('internal_admin', 'external_admin')
    and account_status = 'active'
  for share;

  if actor.id is null then
    raise exception using errcode = '42501', message = 'Administrator access required.';
  end if;

  select *
    into facility_row
  from public.facilities
  where id = p_facility_id
    and archived_at is null
  for update;

  if facility_row.id is null then
    raise exception using errcode = 'P0002', message = 'Facility not found.';
  end if;

  if not public.can_manage_facility(facility_row.id, actor.id) then
    raise exception using errcode = '42501', message = 'You cannot manage this facility.';
  end if;

  if facility_row.latitude is null or facility_row.longitude is null then
    raise exception using errcode = '23514', message = 'Add a facility pin before reviewing the location.';
  end if;

  if facility_row.map_feature_id is not null then
    select *
      into feature_row
    from public.campus_map_features
    where id = facility_row.map_feature_id
      and active;
  end if;

  if feature_row.id is null then
    select *
      into feature_row
    from public.campus_map_features
    where campus_name = facility_row.campus_name
      and lower(name::text) = lower(facility_row.building)
      and active
    limit 1;
  end if;

  if feature_row.id is null then
    raise exception using errcode = '23514', message = 'No active map feature exists for this facility building.';
  end if;

  distance_value := public.facility_distance_m(
    facility_row.latitude,
    facility_row.longitude,
    feature_row.latitude,
    feature_row.longitude
  );
  before_status := facility_row.location_review_status;

  case lower(trim(p_decision))
    when 'verify' then
      if distance_value > feature_row.service_radius_m then
        raise exception using errcode = '23514', message = 'Pin is too far from the selected building. Move the pin or verify it as an exception with a note.';
      end if;
      after_status := 'verified';
    when 'verify_exception' then
      if length(note_value) < 5 then
        raise exception using errcode = '22023', message = 'A location exception note is required.';
      end if;
      after_status := 'verified_exception';
    when 'reject' then
      if length(note_value) < 5 then
        raise exception using errcode = '22023', message = 'A rejection note is required.';
      end if;
      after_status := 'rejected';
    else
      raise exception using errcode = '22023', message = 'Invalid facility location review decision.';
  end case;

  insert into public.facility_location_reviews(
    facility_id,
    reviewer_id,
    decision,
    note,
    before_status,
    after_status,
    distance_m,
    map_feature_id,
    idempotency_key
  ) values (
    facility_row.id,
    actor.id,
    lower(trim(p_decision)),
    note_value,
    before_status,
    after_status,
    distance_value,
    feature_row.id,
    p_idempotency_key
  ) on conflict (reviewer_id, idempotency_key) do nothing;

  update public.facilities
  set map_feature_id = feature_row.id,
      location_validation_distance_m = distance_value,
      location_review_status = after_status,
      location_reviewed_by = actor.id,
      location_reviewed_at = now(),
      location_review_note = note_value,
      location_override_reason = case
        when after_status = 'verified_exception' then note_value
        else ''
      end,
      location_review_version = location_review_version + 1,
      pin_confidence = case
        when after_status in ('verified', 'verified_exception') then 'verified'
        else 'needs_check'
      end,
      status = case
        when after_status = 'rejected' and status = 'active' then 'under_review'
        else status
      end
  where id = facility_row.id
  returning * into facility_row;

  insert into public.audit_entries(
    entity_type, entity_id, target_label, actor_id, actor_name, actor_role,
    action, reason, before_values, after_values, material, source_type, source_id
  ) values (
    'facility',
    facility_row.id,
    facility_row.name::text,
    actor.id,
    coalesce(nullif(actor.full_name, ''), actor.email, 'Administrator'),
    actor.role,
    'reviewed location',
    note_value,
    jsonb_build_object('location_review_status', before_status),
    jsonb_build_object(
      'location_review_status', after_status,
      'distance_m', distance_value,
      'map_feature', feature_row.name::text
    ),
    true,
    'facility_location_review',
    p_idempotency_key
  ) on conflict (source_type, source_id) do nothing;

  return facility_row;
end;
$$;

revoke all on function public.apply_facility_location_integrity() from public, anon, authenticated;
revoke all on function public.decide_facility_location_review(uuid, text, text, uuid) from public, anon, authenticated;
grant execute on function public.decide_facility_location_review(uuid, text, text, uuid) to authenticated;

update public.facilities f
set map_feature_id = mf.id
from public.campus_map_features mf
where f.map_feature_id is null
  and f.campus_name = mf.campus_name
  and lower(f.building) = lower(mf.name::text);

update public.facilities f
set location_validation_distance_m = public.facility_distance_m(
      f.latitude,
      f.longitude,
      mf.latitude,
      mf.longitude
    ),
    location_review_status = case
      when f.latitude is null or f.longitude is null then 'no_pin'
      when public.facility_distance_m(f.latitude, f.longitude, mf.latitude, mf.longitude) <= mf.service_radius_m
           and coalesce(f.accuracy, 999999) <= 15
           and not f.confirmed_outside then 'verified'
      else 'needs_review'
    end,
    pin_confidence = case
      when f.latitude is null or f.longitude is null then 'none'
      when public.facility_distance_m(f.latitude, f.longitude, mf.latitude, mf.longitude) <= mf.service_radius_m
           and coalesce(f.accuracy, 999999) <= 15
           and not f.confirmed_outside then 'verified'
      else 'needs_check'
    end,
    location_reviewed_by = null,
    location_reviewed_at = null,
    location_review_note = case
      when f.latitude is null or f.longitude is null then ''
      when public.facility_distance_m(f.latitude, f.longitude, mf.latitude, mf.longitude) <= mf.service_radius_m
           and coalesce(f.accuracy, 999999) <= 15
           and not f.confirmed_outside then ''
      else 'Automatically marked for review because the stored pin does not match the selected map feature.'
    end
from public.campus_map_features mf
where f.map_feature_id = mf.id
  and f.archived_at is null;

update public.facilities
set location_review_status = 'needs_review',
    pin_confidence = 'needs_check',
    location_review_note = 'Automatically marked for review because no active map feature matches the selected building.'
where archived_at is null
  and latitude is not null
  and longitude is not null
  and map_feature_id is null;

insert into public.facility_location_reviews(
  facility_id,
  reviewer_id,
  decision,
  note,
  before_status,
  after_status,
  distance_m,
  map_feature_id,
  idempotency_key
)
select
  f.id,
  null,
  'auto_needs_review',
  coalesce(nullif(f.location_review_note, ''), 'Automatic facility location integrity remediation.'),
  null,
  f.location_review_status,
  f.location_validation_distance_m,
  f.map_feature_id,
  gen_random_uuid()
from public.facilities f
where f.archived_at is null
  and f.location_review_status = 'needs_review'
on conflict do nothing;

notify pgrst, 'reload schema';
