-- Configurable 20-50% down payment policy, a hard database-side exemption for
-- verified students and faculty, and a minute-granular balance deadline that
-- can express "exactly 24 hours before the reservation start". Replaces the
-- 50%-hard-coded CHECK constraint and the day-granular balance lead.

alter table public.facilities
  add column if not exists down_payment_percent integer not null default 50
    check (down_payment_percent between 20 and 50),
  add column if not exists balance_due_lead_minutes integer not null default 1440
    check (balance_due_lead_minutes between 60 and 129600);

update public.facilities
set balance_due_lead_minutes = greatest(60, balance_due_lead_days * 1440)
where balance_due_lead_minutes = 1440;

alter table public.reservation_requests
  add column if not exists down_payment_percent integer not null default 50,
  add column if not exists payment_exemption text not null default 'none'
    check (payment_exemption in ('none', 'verified_student', 'verified_faculty'));

alter table public.reservation_requests
  drop constraint if exists reservation_requests_money_check,
  add constraint reservation_requests_money_check check (
    currency = 'PHP'
    and facility_amount_centavos >= 0
    and amenity_amount_centavos >= 0
    and discount_amount_centavos >= 0
    and total_amount_centavos >= 0
    and required_down_payment_centavos >= 0
    and required_down_payment_centavos <= total_amount_centavos
    and down_payment_percent between 20 and 50
    and total_amount_centavos =
      facility_amount_centavos + amenity_amount_centavos - discount_amount_centavos
    and required_down_payment_centavos =
      (total_amount_centavos * down_payment_percent + 99) / 100
  );

create or replace function public.protect_reservation_quote_snapshot()
returns trigger language plpgsql set search_path = public as $$
begin
  if new.admin_lane is distinct from old.admin_lane
      or new.pricing_audience is distinct from old.pricing_audience
      or new.currency is distinct from old.currency
      or new.facility_amount_centavos is distinct from old.facility_amount_centavos
      or new.amenity_amount_centavos is distinct from old.amenity_amount_centavos
      or new.discount_amount_centavos is distinct from old.discount_amount_centavos
      or new.total_amount_centavos is distinct from old.total_amount_centavos
      or new.required_down_payment_centavos is distinct from old.required_down_payment_centavos
      or new.pricing_fingerprint is distinct from old.pricing_fingerprint
      or new.down_payment_percent is distinct from old.down_payment_percent
      or new.payment_exemption is distinct from old.payment_exemption then
    raise exception using errcode = '22023',
      message = 'Reservation lane and pricing snapshots are immutable';
  end if;
  return new;
end;
$$;

-- Recreated with the same signature: exemption and the facility's configured
-- down payment percent are now folded into the quote, so the fingerprint
-- covers them and a stale client-held quote is correctly rejected on submit.
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
  if not public.has_facility_admin_lane(p_facility_id, lane_value) then
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

-- Persist the two new quote fields on every new reservation. Signature is
-- unchanged, so this is a true in-place replace.
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
  p_attachment_metadata jsonb default '[]'::jsonb
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
  perform 1
  from public.facility_admin_assignments a
  join public.profiles admin on admin.id = a.admin_id
  where a.facility_id = p_facility_id
    and admin.account_status = 'active'
    and admin.role = case public.requester_admin_lane(profile.id)
      when 'internal' then 'internal_admin' else 'external_admin' end
  for share of a, admin;
  if not found then
    raise exception using errcode='22023',
      message='This facility does not yet have an administrator for your account type';
  end if;
  select * into facility from public.facilities
  where id = p_facility_id and archived_at is null and public_listing and status = 'active'
  for share;
  if facility.id is null then raise exception using errcode='P0002',message='Facility not found or unavailable'; end if;
  perform 1 from public.facility_rates
    where facility_id = p_facility_id and enabled for share;
  perform 1 from public.facility_amenities
    where id = any(coalesce(p_amenity_ids,'{}'::uuid[])) for share;
  perform 1 from public.terms_versions
    where active and (scope='global' or facility_id=p_facility_id) for share;
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
    selected_names,quote->>'admin_lane',quote->>'audience','PHP',
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
  select a.admin_id,result.id,event_id,'reservation_submitted','New reservation request',
    result.requester_name||' requested '||result.facility_name
  from public.facility_admin_assignments a
  join public.profiles p on p.id=a.admin_id and p.account_status='active'
  where a.facility_id=result.facility_id
    and p.role=case result.admin_lane when 'internal' then 'internal_admin' else 'external_admin' end;
  return result;
end;
$$;

-- Balance deadline now uses minute-granular lead time so it can express
-- "exactly 24 hours before the reservation start", not just a calendar day.
create or replace function public.apply_reservation_payment_gate(p_request_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  request_row public.reservation_requests%rowtype;
  facility public.facilities%rowtype;
  method_id uuid;
  first_start timestamptz;
begin
  select * into request_row from public.reservation_requests where id=p_request_id for update;
  if request_row.id is null then raise exception using errcode='P0002',message='Reservation not found'; end if;
  if not public.lock_reservation_admin_scope(p_request_id)
      and request_row.requester_id <> auth.uid() then
    raise exception using errcode='42501',message='Reservation access denied';
  end if;
  select * into facility from public.facilities where id=request_row.facility_id;
  select min(starts_at) into first_start from public.reservation_occurrences
    where request_id=p_request_id and booking_state='booked';
  if request_row.total_amount_centavos=0 then
    update public.reservation_requests
      set reservation_status='confirmed',payment_due_at=null,balance_due_at=null
      where id=p_request_id;
    return;
  end if;
  select id into method_id from public.facility_payment_methods
  where facility_id=request_row.facility_id and enabled and method_type='gcash'
  order by updated_at desc limit 1;
  if method_id is null then
    raise exception using errcode='22023',message='Configure an active GCash payment method before approving paid reservations';
  end if;
  update public.reservation_occurrences set booking_state='held'
  where request_id=p_request_id and booking_state='booked';
  update public.reservation_requests set
    reservation_status='awaiting_payment',payment_method_id=method_id,
    payment_due_at=now()+make_interval(mins=>facility.deposit_window_minutes),
    balance_due_at=first_start-make_interval(mins=>facility.balance_due_lead_minutes)
  where id=p_request_id;
end;
$$;

revoke all on function public.apply_reservation_payment_gate(uuid)
  from public, anon, authenticated;

-- Extend the aggregate summary with 'overdue' (balance deadline passed while
-- unpaid) and surface the policy fields used by the permit and the user's
-- remaining-balance screen.
create or replace function public.reservation_payment_summary(p_request_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  request_row public.reservation_requests%rowtype;
  verified_value integer;
  submitted_value integer;
  status_value text;
begin
  select * into request_row from public.reservation_requests where id=p_request_id;
  if request_row.id is null or not public.can_access_reservation(p_request_id) then
    raise exception using errcode='42501',message='Reservation access denied';
  end if;
  select coalesce(sum(amount_centavos) filter(where status='verified' and purpose<>'refund'),0),
         coalesce(sum(amount_centavos) filter(where status='submitted'),0)
  into verified_value,submitted_value
  from public.payment_transactions where request_id=p_request_id;
  status_value := case
    when request_row.total_amount_centavos=0 then 'not_required'
    when verified_value>=request_row.total_amount_centavos then 'fully_paid'
    when request_row.balance_due_at is not null and request_row.balance_due_at<now()
      then 'overdue'
    when verified_value>=request_row.required_down_payment_centavos then 'down_payment_verified'
    when submitted_value>0 then 'submitted'
    when verified_value>0 then 'partially_paid'
    else 'unpaid' end;
  return jsonb_build_object(
    'status',status_value,'total_amount_centavos',request_row.total_amount_centavos,
    'required_down_payment_centavos',request_row.required_down_payment_centavos,
    'verified_amount_centavos',verified_value,'submitted_amount_centavos',submitted_value,
    'outstanding_amount_centavos',greatest(0,request_row.total_amount_centavos-verified_value),
    'payment_due_at',request_row.payment_due_at,'balance_due_at',request_row.balance_due_at,
    'down_payment_percent',request_row.down_payment_percent,
    'payment_exemption',request_row.payment_exemption
  );
end;
$$;

revoke all on function public.reservation_payment_summary(uuid) from public,anon;
grant execute on function public.reservation_payment_summary(uuid) to authenticated;

-- v2: adds a facility-level down payment percent and switches the balance
-- lead from whole days to minutes. Named distinctly (rather than replaced in
-- place) to avoid PostgREST overload ambiguity, matching how this codebase
-- already versioned submit_reservation -> submit_reservation_v2.
revoke all on function public.save_facility_configuration(
  uuid, jsonb, jsonb, text, text, text, integer, integer, integer
) from public, anon, authenticated;

create or replace function public.save_facility_configuration_v2(
  p_facility_id uuid,
  p_rates jsonb,
  p_amenities jsonb,
  p_account_name text,
  p_account_number text,
  p_instructions text default '',
  p_deposit_window_minutes integer default 1440,
  p_balance_due_lead_minutes integer default 1440,
  p_correction_window_minutes integer default 1440,
  p_down_payment_percent integer default 50
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  rate_item jsonb;
  amenity_item jsonb;
  method_id uuid;
  facility_name text;
  actor public.profiles%rowtype;
begin
  perform 1
  from public.facility_admin_assignments a
  join public.profiles p on p.id = a.admin_id
  where a.facility_id = p_facility_id and a.admin_id = auth.uid()
    and p.role in ('internal_admin','external_admin')
    and p.account_status = 'active'
  for share of a, p;
  if not found then
    raise exception using errcode = '42501', message = 'Assigned facility access required';
  end if;
  if jsonb_typeof(p_rates) <> 'array'
      or jsonb_array_length(p_rates) <> 4
      or (select count(distinct value->>'audience')
          from jsonb_array_elements(p_rates)) <> 4 then
    raise exception using errcode = '22023',
      message = 'Provide one rate for student, faculty, staff, and guest';
  end if;
  if p_amenities is not null and jsonb_typeof(p_amenities) <> 'array' then
    raise exception using errcode = '22023', message = 'Amenities must be a list';
  end if;
  if jsonb_array_length(coalesce(p_amenities, '[]'::jsonb)) <>
      (select count(distinct lower(trim(value->>'name')))
       from jsonb_array_elements(coalesce(p_amenities, '[]'::jsonb))) then
    raise exception using errcode = '22023', message = 'Amenity names must be unique';
  end if;
  if p_deposit_window_minutes not between 30 and 10080
      or p_balance_due_lead_minutes not between 60 and 129600
      or p_correction_window_minutes not between 30 and 10080
      or p_down_payment_percent not between 20 and 50 then
    raise exception using errcode = '22023', message = 'Invalid payment deadline or down payment settings';
  end if;

  for rate_item in select value from jsonb_array_elements(p_rates) loop
    if rate_item->>'audience' not in ('student','faculty','staff','guest')
        or (rate_item->>'hourly_rate_centavos')::integer < 0 then
      raise exception using errcode = '22023', message = 'Invalid audience rate';
    end if;
    insert into public.facility_rates(
      facility_id, audience, hourly_rate_centavos, enabled
    ) values (
      p_facility_id,
      rate_item->>'audience',
      (rate_item->>'hourly_rate_centavos')::integer,
      true
    )
    on conflict (facility_id, audience) do update
      set hourly_rate_centavos = excluded.hourly_rate_centavos,
          enabled = true,
          updated_at = now(),
          updated_by = auth.uid();
  end loop;

  update public.facility_amenities
  set enabled = false, updated_at = now(), updated_by = auth.uid()
  where facility_id = p_facility_id;
  for amenity_item in
    select value from jsonb_array_elements(coalesce(p_amenities, '[]'::jsonb))
  loop
    if length(trim(coalesce(amenity_item->>'name', ''))) not between 2 and 80
        or coalesce((amenity_item->>'price_centavos')::integer, -1) < 0
        or coalesce(amenity_item->>'pricing_unit', '')
          not in ('per_reservation','per_occurrence') then
      raise exception using errcode = '22023', message = 'Invalid facility amenity';
    end if;
    insert into public.facility_amenities(
      facility_id, name, description, price_centavos, pricing_unit, enabled
    ) values (
      p_facility_id,
      trim(amenity_item->>'name'),
      coalesce(amenity_item->>'description', ''),
      (amenity_item->>'price_centavos')::integer,
      amenity_item->>'pricing_unit',
      true
    )
    on conflict (facility_id, name) do update set
      description = excluded.description,
      price_centavos = excluded.price_centavos,
      pricing_unit = excluded.pricing_unit,
      enabled = true,
      updated_at = now(),
      updated_by = auth.uid();
  end loop;

  update public.facilities
  set deposit_window_minutes = p_deposit_window_minutes,
      balance_due_lead_minutes = p_balance_due_lead_minutes,
      payment_correction_window_minutes = p_correction_window_minutes,
      down_payment_percent = p_down_payment_percent,
      amenities = array(
        select (value->>'name')::text
        from jsonb_array_elements(coalesce(p_amenities, '[]'::jsonb))
      ),
      updated_at = now(),
      updated_by = auth.uid()
  where id = p_facility_id
  returning name::text into facility_name;

  if nullif(trim(coalesce(p_account_name, '')), '') is not null
      or nullif(trim(coalesce(p_account_number, '')), '') is not null then
    if length(trim(coalesce(p_account_name, ''))) < 2
        or length(regexp_replace(coalesce(p_account_number, ''), '[^0-9]', '', 'g'))
          not between 10 and 15 then
      raise exception using errcode = '22023', message = 'Enter a valid GCash destination';
    end if;
    select id into method_id
    from public.facility_payment_methods
    where facility_id = p_facility_id and method_type = 'gcash' and enabled
    for update;
    if method_id is not null and exists(
      select 1 from public.facility_payment_methods m
      where m.id = method_id
        and m.account_name = trim(p_account_name)
        and m.account_number = trim(p_account_number)
        and m.instructions = trim(coalesce(p_instructions, ''))
    ) then
      null;
    else
      if method_id is not null then
        update public.facility_payment_methods
        set enabled = false, updated_at = now(), updated_by = auth.uid()
        where id = method_id;
      end if;
      insert into public.facility_payment_methods(
        facility_id, account_name, account_number, instructions
      ) values (
        p_facility_id, trim(p_account_name), trim(p_account_number),
        trim(coalesce(p_instructions, ''))
      ) returning id into method_id;
    end if;
  end if;

  select * into actor from public.profiles where id = auth.uid();
  insert into public.audit_entries(
    entity_type, entity_id, target_label, actor_id, actor_name, actor_role,
    action, details, material, source_type, source_id
  ) values (
    'facility', p_facility_id, facility_name, auth.uid(),
    coalesce(nullif(actor.full_name, ''), actor.email), actor.role,
    'updated pricing, amenities, and payment settings',
    jsonb_build_object(
      'rates', p_rates,
      'amenity_count', jsonb_array_length(coalesce(p_amenities, '[]'::jsonb)),
      'deposit_window_minutes', p_deposit_window_minutes,
      'balance_due_lead_minutes', p_balance_due_lead_minutes,
      'correction_window_minutes', p_correction_window_minutes,
      'down_payment_percent', p_down_payment_percent
    ), true, 'facility_configuration', gen_random_uuid()
  );

  return jsonb_build_object('facility_id', p_facility_id, 'payment_method_id', method_id);
end;
$$;

revoke all on function public.save_facility_configuration_v2(
  uuid, jsonb, jsonb, text, text, text, integer, integer, integer, integer
) from public, anon;
grant execute on function public.save_facility_configuration_v2(
  uuid, jsonb, jsonb, text, text, text, integer, integer, integer, integer
) to authenticated;

notify pgrst, 'reload schema';
