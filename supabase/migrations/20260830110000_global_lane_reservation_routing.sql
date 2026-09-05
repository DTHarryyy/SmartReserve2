-- Reservation routing is lane-wide: verified campus users route to active
-- internal administrators; renters and other non-verified users route to
-- active external administrators. Facility-management ownership remains
-- assignment-based through has_facility_admin_lane/can_manage_facility.

create or replace function public.has_active_admin_in_lane(p_lane text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select p_lane in ('internal', 'external') and exists (
    select 1
    from public.profiles p
    where p.account_status = 'active'
      and p.role = case p_lane
        when 'internal' then 'internal_admin'
        else 'external_admin'
      end
  );
$$;

revoke all on function public.has_active_admin_in_lane(text)
  from public, anon;
grant execute on function public.has_active_admin_in_lane(text)
  to authenticated;

create or replace function public.my_facility_access()
returns table (
  facility_id uuid,
  can_manage boolean,
  assignment_role text,
  supports_internal boolean,
  supports_external boolean,
  bookable boolean
)
language sql
stable
security definer
set search_path = public
as $$
  select f.id,
    public.can_manage_facility(f.id),
    (select a.assignment_role from public.facility_admin_assignments a
      where a.facility_id = f.id and a.admin_id = auth.uid()),
    f.facility_classification in ('internal', 'shared'),
    f.facility_classification in ('external', 'shared'),
    case when public.admin_lane() is null
      then f.archived_at is null
        and f.public_listing
        and f.status = 'active'
        and f.facility_classification in ('shared', public.requester_admin_lane())
        and public.has_active_admin_in_lane(public.requester_admin_lane())
      else false end
  from public.facilities f
  where f.archived_at is null;
$$;

revoke all on function public.my_facility_access() from public, anon;
grant execute on function public.my_facility_access() to authenticated;

create or replace function public.facility_busy_windows(
  p_facility_ids uuid[],
  p_from timestamptz,
  p_to timestamptz
) returns table (
  facility_id uuid,
  starts_at timestamptz,
  ends_at timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
  select o.facility_id, o.starts_at, o.ends_at
  from public.reservation_occurrences o
  join public.facilities f on f.id = o.facility_id
  where p_to > p_from
    and p_to <= p_from + interval '120 days'
    and array_length(p_facility_ids, 1) between 1 and 40
    and o.facility_id = any(p_facility_ids)
    and o.booking_state in ('held', 'booked')
    and f.archived_at is null
    and f.public_listing
    and f.facility_classification in ('shared', public.requester_admin_lane())
    and public.has_active_admin_in_lane(public.requester_admin_lane())
    and tstzrange(o.starts_at, o.ends_at, '[)')
      && tstzrange(p_from, p_to, '[)')
  order by o.facility_id, o.starts_at;
$$;

revoke all on function public.facility_busy_windows(uuid[], timestamptz, timestamptz)
  from public, anon;
grant execute on function public.facility_busy_windows(uuid[], timestamptz, timestamptz)
  to authenticated;

create or replace function public.get_reservation_quote(
  p_facility_id uuid,
  p_starts_at timestamptz[],
  p_ends_at timestamptz[],
  p_amenity_ids uuid[] default '{}'::uuid[],
  p_headcount integer default null
) returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  facility public.facilities%rowtype;
  audience_value text;
  lane_value text;
  exemption_value text;
  rate_value integer;
  facility_total integer := 0;
  amenity_total integer := 0;
  total_value integer;
  total_minutes numeric := 0;
  lines_value jsonb := '[]'::jsonb;
  amenities_value jsonb := '[]'::jsonb;
  terms_value jsonb := '[]'::jsonb;
  payload jsonb;
  item record;
  local_start timestamp;
  local_end timestamp;
  i integer;
begin
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'Sign in required';
  end if;
  select * into facility from public.facilities
  where id = p_facility_id and archived_at is null and public_listing
    and status = 'active';
  if facility.id is null then
    raise exception using errcode = 'P0002', message = 'Facility not found or unavailable';
  end if;
  audience_value := public.requester_pricing_audience();
  lane_value := public.requester_admin_lane();
  exemption_value := case audience_value
    when 'student' then 'verified_student'
    when 'faculty' then 'verified_faculty'
    else 'none'
  end;
  if facility.facility_classification not in ('shared', lane_value) then
    raise exception using errcode = '22023',
      message = 'This facility is not available for your account type';
  end if;
  if not public.has_active_admin_in_lane(lane_value) then
    raise exception using errcode = '22023',
      message = 'This facility does not yet have an administrator for your account type';
  end if;
  if cardinality(p_starts_at) is null or cardinality(p_starts_at) not between 1 and 12
     or cardinality(p_starts_at) <> cardinality(p_ends_at) then
    raise exception using errcode = '22023', message = 'Provide between one and twelve valid occurrences';
  end if;
  if p_headcount is not null and p_headcount not between 1 and facility.capacity then
    raise exception using errcode = '22023', message = 'Attendee count exceeds facility capacity';
  end if;
  if exemption_value = 'none' then
    select hourly_rate_centavos into rate_value
    from public.facility_rates
    where facility_id = p_facility_id and audience = audience_value and enabled;
    if rate_value is null then
      raise exception using errcode = '22023', message = 'No active rate is configured for your account type';
    end if;
  else
    rate_value := 0;
  end if;
  for i in 1..cardinality(p_starts_at) loop
    local_start := p_starts_at[i] at time zone 'Asia/Manila';
    local_end := p_ends_at[i] at time zone 'Asia/Manila';
    if p_starts_at[i] >= p_ends_at[i] or local_start::date <> local_end::date then
      raise exception using errcode = '22023', message = 'Choose a valid same-day time range';
    end if;
    if not facility.open_days[extract(isodow from local_start)::integer]
       or local_start::time < facility.open_time or local_end::time > facility.close_time then
      raise exception using errcode = '22023', message = 'Reservation is outside facility operating hours';
    end if;
    if extract(epoch from (p_ends_at[i] - p_starts_at[i])) / 60
        > facility.max_duration_minutes then
      raise exception using errcode = '22023', message = 'Reservation exceeds the facility maximum duration';
    end if;
    if p_starts_at[i] < now()
       or p_starts_at[i] > now() + make_interval(days => facility.advance_booking_days) then
      raise exception using errcode = '22023', message = 'Reservation date is outside the booking window';
    end if;
    total_minutes := total_minutes + extract(epoch from (p_ends_at[i] - p_starts_at[i])) / 60;
  end loop;
  facility_total := round(total_minutes * rate_value / 60)::integer;
  lines_value := jsonb_build_array(jsonb_build_object(
    'line_type','facility','source_id',facility.id,'label',facility.name::text,
    'quantity',round(total_minutes / 60, 2),'unit_amount_centavos',rate_value,
    'line_total_centavos',facility_total
  ));
  if cardinality(coalesce(p_amenity_ids, '{}'::uuid[]))
      <> cardinality(array(
        select distinct amenity_id
        from unnest(coalesce(p_amenity_ids, '{}'::uuid[])) amenity_id
      )) then
    raise exception using errcode = '22023', message = 'Duplicate amenities are not allowed';
  end if;
  for item in
    select a.*,
      case a.pricing_unit when 'per_occurrence' then cardinality(p_starts_at) else 1 end quantity_value
    from public.facility_amenities a
    where a.id = any(coalesce(p_amenity_ids, '{}'::uuid[]))
      and a.facility_id = p_facility_id and a.enabled
    order by a.name
  loop
    declare
      unit_price integer := case when exemption_value = 'none'
        then item.price_centavos else 0 end;
      line_total integer := unit_price * item.quantity_value;
    begin
      amenity_total := amenity_total + line_total;
      amenities_value := amenities_value || jsonb_build_array(jsonb_build_object(
        'id',item.id,'name',item.name::text,'price_centavos',unit_price,
        'quantity',item.quantity_value,'line_total_centavos',line_total
      ));
      lines_value := lines_value || jsonb_build_array(jsonb_build_object(
        'line_type','amenity','source_id',item.id,'label',item.name::text,
        'quantity',item.quantity_value,'unit_amount_centavos',unit_price,
        'line_total_centavos',line_total
      ));
    end;
  end loop;
  if jsonb_array_length(amenities_value) <> cardinality(coalesce(p_amenity_ids, '{}'::uuid[])) then
    raise exception using errcode = '22023', message = 'One or more amenities are unavailable for this facility';
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',t.id,'title',t.title,'version',t.version,'content',t.content,
    'content_hash',t.content_hash
  ) order by t.scope,t.version),'[]'::jsonb)
  into terms_value
  from public.terms_versions t
  where t.active and (t.scope = 'global' or t.facility_id = p_facility_id);
  total_value := facility_total + amenity_total;
  payload := jsonb_build_object(
    'facility_id',facility.id,'audience',audience_value,'admin_lane',lane_value,
    'currency','PHP','facility_amount_centavos',facility_total,
    'amenity_amount_centavos',amenity_total,'discount_amount_centavos',0,
    'total_amount_centavos',total_value,
    'down_payment_percent',facility.down_payment_percent,
    'payment_exemption',exemption_value,
    'required_down_payment_centavos',
      (total_value * facility.down_payment_percent + 99) / 100,
    'lines',lines_value,'amenities',amenities_value,'terms',terms_value
  );
  return payload || jsonb_build_object(
    'pricing_fingerprint', encode(extensions.digest(payload::text, 'sha256'), 'hex')
  );
end;
$$;

revoke all on function public.get_reservation_quote(uuid,timestamptz[],timestamptz[],uuid[],integer)
  from public, anon;
grant execute on function public.get_reservation_quote(uuid,timestamptz[],timestamptz[],uuid[],integer)
  to authenticated;

drop function if exists public.submit_reservation_v2(
  uuid, uuid, text, integer, timestamptz[], timestamptz[], uuid[], uuid[], text, jsonb, text[]
);

create or replace function public.submit_reservation_v2(
  p_request_id uuid,
  p_facility_id uuid,
  p_purpose text,
  p_headcount integer,
  p_starts_at timestamptz[],
  p_ends_at timestamptz[],
  p_amenity_ids uuid[] default '{}'::uuid[],
  p_terms_version_ids uuid[] default '{}'::uuid[],
  p_pricing_fingerprint text default null,
  p_attachment_metadata jsonb default '[]'::jsonb,
  p_requested_amenities text[] default '{}'::text[]
) returns public.reservation_requests
language plpgsql
security definer
set search_path = public, storage
as $$
declare
  profile public.profiles%rowtype;
  facility public.facilities%rowtype;
  quote jsonb;
  result public.reservation_requests%rowtype;
  attachment jsonb;
  line jsonb;
  amenity jsonb;
  term_row public.terms_versions%rowtype;
  required_terms uuid[];
  selected_names text[];
  requested_names text[];
  lane_value text;
  allowed_catalog text[] := array[
    'Wi-Fi',
    'Power Outlets',
    'Air Conditioning',
    'Projector',
    'Smart TV',
    'Sound System',
    'Whiteboard',
    'Parking',
    'PWD Accessibility',
    'Security Cameras',
    'Generator'
  ];
  invalid_requested text;
  local_start timestamp;
  local_end timestamp;
  event_id uuid;
  i integer;
begin
  if auth.uid() is null then raise exception using errcode='42501',message='Sign in required'; end if;
  select * into profile from public.profiles where id = auth.uid() for update;
  if profile.id is null or profile.account_status <> 'active' or profile.role <> 'user' then
    raise exception using errcode='42501',message='This account cannot submit reservations';
  end if;
  select * into facility from public.facilities
  where id = p_facility_id and archived_at is null and public_listing and status = 'active'
  for share;
  if facility.id is null then raise exception using errcode='P0002',message='Facility not found or unavailable'; end if;
  lane_value := public.requester_admin_lane(profile.id);
  if facility.facility_classification not in ('shared', lane_value) then
    raise exception using errcode='22023',
      message='This facility is not available for your account type';
  end if;
  if not public.has_active_admin_in_lane(lane_value) then
    raise exception using errcode='22023',
      message='This facility does not yet have an administrator for your account type';
  end if;
  perform 1 from public.facility_rates
    where facility_id = p_facility_id and enabled for share;
  perform 1 from public.facility_amenities
    where id = any(coalesce(p_amenity_ids,'{}'::uuid[])) for share;
  perform 1 from public.terms_versions
    where active and (scope='global' or facility_id=p_facility_id) for share;

  select requested.value into invalid_requested
  from unnest(coalesce(p_requested_amenities,'{}'::text[])) requested(value)
  where trim(coalesce(requested.value,'')) <> ''
    and not exists (
      select 1
      from unnest(allowed_catalog) allowed(label)
      where lower(allowed.label) = lower(trim(requested.value))
    )
  limit 1;
  if invalid_requested is not null then
    raise exception using errcode='22023',
      message='One or more requested amenities are not in the standard catalog';
  end if;

  select coalesce(array_agg(allowed.label order by allowed.ord),'{}'::text[])
  into requested_names
  from unnest(allowed_catalog) with ordinality allowed(label, ord)
  where exists (
      select 1
      from unnest(coalesce(p_requested_amenities,'{}'::text[])) requested(value)
      where lower(trim(requested.value)) = lower(allowed.label)
    )
    and not exists (
      select 1
      from unnest(coalesce(facility.amenities,'{}'::text[])) included(label)
      where lower(trim(included.label)) = lower(allowed.label)
    );

  quote := public.get_reservation_quote(
    p_facility_id,p_starts_at,p_ends_at,p_amenity_ids,p_headcount
  );
  if p_pricing_fingerprint is null
     or p_pricing_fingerprint <> quote->>'pricing_fingerprint' then
    raise exception using errcode='40001',message='Pricing changed. Review the updated quote and try again';
  end if;
  if p_headcount not between 1 and facility.capacity then
    raise exception using errcode='22023',message='Attendee count exceeds facility capacity';
  end if;
  if length(trim(p_purpose)) not between 3 and 1000 then
    raise exception using errcode='22023',message='Provide a reservation purpose';
  end if;
  if jsonb_array_length(coalesce(p_attachment_metadata,'[]'::jsonb)) > 3 then
    raise exception using errcode='22023',message='A maximum of three supporting files is allowed';
  end if;
  select coalesce(array_agg(id order by id),'{}'::uuid[]) into required_terms
  from public.terms_versions
  where active and (scope='global' or facility_id=p_facility_id);
  if cardinality(required_terms) <> cardinality(array(
      select distinct id from unnest(coalesce(p_terms_version_ids,'{}'::uuid[])) id
    )) or not required_terms @> coalesce(p_terms_version_ids,'{}'::uuid[]) then
    raise exception using errcode='22023',message='Accept the current reservation terms before submitting';
  end if;
  for i in 1..cardinality(p_starts_at) loop
    local_start := p_starts_at[i] at time zone 'Asia/Manila';
    local_end := p_ends_at[i] at time zone 'Asia/Manila';
    if p_starts_at[i] >= p_ends_at[i] or local_start::date <> local_end::date then
      raise exception using errcode='22023',message='Choose a valid same-day time range';
    end if;
    if not facility.open_days[extract(isodow from local_start)::integer]
       or local_start::time < facility.open_time or local_end::time > facility.close_time then
      raise exception using errcode='22023',message='Reservation is outside facility operating hours';
    end if;
    if extract(epoch from (p_ends_at[i]-p_starts_at[i]))/60 > facility.max_duration_minutes then
      raise exception using errcode='22023',message='Reservation exceeds the facility maximum duration';
    end if;
    if p_starts_at[i] < now()
       or p_starts_at[i] > now()+make_interval(days=>facility.advance_booking_days) then
      raise exception using errcode='22023',message='Reservation date is outside the booking window';
    end if;
  end loop;
  select coalesce(array_agg(a.name::text order by a.name),'{}'::text[])
  into selected_names
  from public.facility_amenities a
  where a.id=any(coalesce(p_amenity_ids,'{}'::uuid[]));
  insert into public.reservation_requests(
    id,requester_id,facility_id,requester_name,requester_role,requester_unit,
    facility_name,facility_building,facility_room,facility_capacity,purpose,headcount,
    status,held_for_verification,recurrence,payment_amount_centavos,payment_status,
    amenities,admin_lane,pricing_audience,currency,facility_amount_centavos,
    amenity_amount_centavos,discount_amount_centavos,total_amount_centavos,
    required_down_payment_centavos,pricing_fingerprint,down_payment_percent,
    payment_exemption
  ) values (
    p_request_id,profile.id,facility.id,coalesce(nullif(profile.full_name,''),profile.email),
    profile.role,coalesce(profile.unit,''),facility.name::text,facility.building,facility.room,
    facility.capacity,trim(p_purpose),p_headcount,'pending',false,
    case when cardinality(p_starts_at)>1 then 'weekly' else 'none' end,
    (quote->>'total_amount_centavos')::integer,
    case when (quote->>'total_amount_centavos')::integer=0 then 'not_required' else 'quoted' end,
    selected_names || requested_names,quote->>'admin_lane',quote->>'audience','PHP',
    (quote->>'facility_amount_centavos')::integer,
    (quote->>'amenity_amount_centavos')::integer,0,
    (quote->>'total_amount_centavos')::integer,
    (quote->>'required_down_payment_centavos')::integer,
    quote->>'pricing_fingerprint',
    (quote->>'down_payment_percent')::integer,
    quote->>'payment_exemption'
  ) returning * into result;
  for i in 1..cardinality(p_starts_at) loop
    insert into public.reservation_occurrences(
      request_id,facility_id,starts_at,ends_at,buffer_minutes
    ) values (result.id,facility.id,p_starts_at[i],p_ends_at[i],facility.booking_buffer_minutes);
  end loop;
  for amenity in select value from jsonb_array_elements(quote->'amenities') loop
    insert into public.reservation_amenities(
      request_id,facility_amenity_id,name_snapshot,unit_price_centavos,quantity,line_total_centavos
    ) values (
      result.id,(amenity->>'id')::uuid,amenity->>'name',
      (amenity->>'price_centavos')::integer,(amenity->>'quantity')::integer,
      (amenity->>'line_total_centavos')::integer
    );
  end loop;
  for line in select value from jsonb_array_elements(quote->'lines') loop
    insert into public.reservation_price_lines(
      request_id,line_type,source_id,label,quantity,unit_amount_centavos,line_total_centavos
    ) values (
      result.id,line->>'line_type',(line->>'source_id')::uuid,line->>'label',
      (line->>'quantity')::numeric,(line->>'unit_amount_centavos')::integer,
      (line->>'line_total_centavos')::integer
    );
  end loop;
  for term_row in select * from public.terms_versions where id=any(required_terms) loop
    insert into public.reservation_terms_acceptances(
      request_id,terms_version_id,user_id,content_hash
    ) values (result.id,term_row.id,profile.id,term_row.content_hash);
  end loop;
  for attachment in select value from jsonb_array_elements(coalesce(p_attachment_metadata,'[]'::jsonb)) loop
    if attachment->>'storage_path' not like auth.uid()::text||'/%' then
      raise exception using errcode='42501',message='Invalid attachment path';
    end if;
    insert into public.reservation_attachments(
      request_id,owner_id,storage_path,file_name,mime_type,byte_size
    ) values (
      result.id,auth.uid(),attachment->>'storage_path',attachment->>'file_name',
      attachment->>'mime_type',(attachment->>'byte_size')::integer
    );
  end loop;
  event_id := public.reservation_event(result.id,'submitted a reservation request',null,
    jsonb_build_object('admin_lane',result.admin_lane,'total_amount_centavos',result.total_amount_centavos),null,false);
  insert into public.app_notifications(recipient_id,request_id,event_id,kind,title,body)
  select p.id,result.id,event_id,'reservation_submitted','New reservation request',
    result.requester_name||' requested '||result.facility_name
  from public.profiles p
  where p.account_status='active'
    and p.role=case result.admin_lane when 'internal' then 'internal_admin' else 'external_admin' end;
  return result;
end;
$$;

revoke all on function public.submit_reservation_v2(
  uuid, uuid, text, integer, timestamptz[], timestamptz[], uuid[], uuid[], text, jsonb, text[]
) from public, anon, authenticated;
grant execute on function public.submit_reservation_v2(
  uuid, uuid, text, integer, timestamptz[], timestamptz[], uuid[], uuid[], text, jsonb, text[]
) to authenticated;

notify pgrst, 'reload schema';
