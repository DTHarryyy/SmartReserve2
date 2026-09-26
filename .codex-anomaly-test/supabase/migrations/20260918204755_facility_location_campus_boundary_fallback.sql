-- Every facility currently sitting at pin_confidence = 'needs_check' has tight
-- accuracy (<=15m) and confirmed_outside = false, but is 100-250m from the one
-- lat/lng point stored per building in campus_map_features (service_radius_m
-- = 90m). These are legitimate outdoor/standalone facilities (courts, gyms,
-- pavilions, halls) administratively tagged to a nearby classroom building --
-- the pin itself is correctly placed and sits inside the campus boundary
-- polygon the client app already treats as valid (lib/data/campus_data.dart,
-- campus.boundary). A single 90m radius around one building point was never
-- going to fit them, so they get stuck re-flagged "needs review" on every
-- save no matter how correctly the admin places the pin.
--
-- Fix: accept a pin as verified when it is either close to its matched
-- building OR anywhere inside the whole campus boundary polygon -- mirroring
-- the polygon check the client already uses to decide what counts as a valid
-- location.

create or replace function public.point_in_campus_boundary(
  p_lat double precision,
  p_lng double precision,
  p_campus_name text default 'CSU Aparri Campus'
) returns boolean
language sql
immutable
parallel safe
as $$
  with boundary(lat, lng, seq) as (
    values
      -- Mirrors lib/data/campus_data.dart `campus.boundary` exactly.
      (18.353792, 121.646670, 1),
      (18.354032, 121.650930, 2),
      (18.351292, 121.652070, 3),
      (18.349092, 121.651370, 4),
      (18.348832, 121.647510, 5),
      (18.351232, 121.646410, 6)
  ),
  edges as (
    select b1.lat as yi, b1.lng as xi, b2.lat as yj, b2.lng as xj
    from boundary b1
    join boundary b2 on b2.seq = case when b1.seq = 6 then 1 else b1.seq + 1 end
  )
  select case
    when p_lat is null or p_lng is null then false
    when p_campus_name is distinct from 'CSU Aparri Campus' then false
    else (
      select count(*) filter (
        where ((yi > p_lat) <> (yj > p_lat))
          and (p_lng < (xj - xi) * (p_lat - yi) / (yj - yi) + xi)
      ) % 2 = 1
      from edges
    )
  end;
$$;

revoke all on function public.point_in_campus_boundary(double precision, double precision, text)
from public, anon, authenticated;
grant execute on function public.point_in_campus_boundary(double precision, double precision, text)
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
  near_feature boolean;
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

  near_feature := feature_row.id is not null
    and distance_value is not null
    and distance_value <= feature_row.service_radius_m;

  if new.confirmed_outside
     or coalesce(new.accuracy, 999999) > 15
     or (
       not near_feature
       and not public.point_in_campus_boundary(new.latitude, new.longitude, new.campus_name)
     ) then
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

-- Mirror the same campus-boundary fallback in the manual admin review RPC,
-- which had the identical bug: it refused to let an admin "Verify" a pin
-- that was legitimately on campus but far from its building's single point.
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
      if distance_value > feature_row.service_radius_m
         and not public.point_in_campus_boundary(
           facility_row.latitude, facility_row.longitude, facility_row.campus_name
         ) then
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

-- Backfill: re-evaluate every already-saved, non-archived facility with a
-- pin against the corrected rule so already-stuck rows clear immediately,
-- instead of waiting for their next unrelated edit.
update public.facilities f
set location_review_status = case
      when f.confirmed_outside then 'needs_review'
      when coalesce(f.accuracy, 999999) > 15 then 'needs_review'
      when mf.id is not null
           and public.facility_distance_m(f.latitude, f.longitude, mf.latitude, mf.longitude)
             <= mf.service_radius_m
        then 'verified'
      when public.point_in_campus_boundary(f.latitude, f.longitude, f.campus_name)
        then 'verified'
      else 'needs_review'
    end,
    pin_confidence = case
      when f.confirmed_outside then 'needs_check'
      when coalesce(f.accuracy, 999999) > 15 then 'needs_check'
      when mf.id is not null
           and public.facility_distance_m(f.latitude, f.longitude, mf.latitude, mf.longitude)
             <= mf.service_radius_m
        then 'verified'
      when public.point_in_campus_boundary(f.latitude, f.longitude, f.campus_name)
        then 'verified'
      else 'needs_check'
    end,
    location_validation_distance_m = case
      when mf.id is not null then
        public.facility_distance_m(f.latitude, f.longitude, mf.latitude, mf.longitude)
      else f.location_validation_distance_m
    end,
    status = case
      when f.status = 'under_review' and not f.confirmed_outside then 'active'
      else f.status
    end
from public.campus_map_features mf
where f.archived_at is null
  and f.map_feature_id = mf.id
  and f.latitude is not null
  and f.longitude is not null;

update public.facilities f
set location_review_status = case
      when f.confirmed_outside then 'needs_review'
      when coalesce(f.accuracy, 999999) > 15 then 'needs_review'
      when public.point_in_campus_boundary(f.latitude, f.longitude, f.campus_name)
        then 'verified'
      else 'needs_review'
    end,
    pin_confidence = case
      when f.confirmed_outside then 'needs_check'
      when coalesce(f.accuracy, 999999) > 15 then 'needs_check'
      when public.point_in_campus_boundary(f.latitude, f.longitude, f.campus_name)
        then 'verified'
      else 'needs_check'
    end,
    status = case
      when f.status = 'under_review' and not f.confirmed_outside then 'active'
      else f.status
    end
where f.archived_at is null
  and f.map_feature_id is null
  and f.latitude is not null
  and f.longitude is not null;

notify pgrst, 'reload schema';
