-- Let requesters ask for additional amenities when booking a facility.
-- Adds reservation_requests.amenities and threads a new p_amenities
-- parameter through submit_reservation / submit_reservation_untrusted_amount.

alter table public.reservation_requests
  add column if not exists amenities text[] not null default '{}';

alter table public.reservation_requests
  drop constraint if exists reservation_requests_amenities_len;
alter table public.reservation_requests
  add constraint reservation_requests_amenities_len
  check (cardinality(amenities) <= 20);

-- Both functions are recreated with an extra trailing parameter rather than
-- overloaded, so the old 8-arg signatures must go first (an overload would
-- make existing 8-arg RPC calls from cached clients ambiguous).
drop function if exists public.submit_reservation(
  uuid, uuid, text, integer, timestamptz[], timestamptz[], jsonb, integer
);
drop function if exists public.submit_reservation_untrusted_amount(
  uuid, uuid, text, integer, timestamptz[], timestamptz[], jsonb, integer
);

create function public.submit_reservation_untrusted_amount(
  p_request_id uuid,
  p_facility_id uuid,
  p_purpose text,
  p_headcount integer,
  p_starts_at timestamptz[],
  p_ends_at timestamptz[],
  p_attachment_metadata jsonb default '[]'::jsonb,
  p_payment_amount_centavos integer default 0,
  p_amenities text[] default '{}'
) returns public.reservation_requests
language plpgsql security definer set search_path = public, storage as $$
declare
  profile public.profiles%rowtype;
  facility public.facilities%rowtype;
  result public.reservation_requests%rowtype;
  held boolean;
  payment text;
  attachment jsonb;
  event_id uuid;
  amenities_clean text[];
begin
  if auth.uid() is null then raise exception using errcode = '42501', message = 'Sign in required'; end if;
  select * into profile from public.profiles where id = auth.uid() for update;
  if profile.id is null or profile.account_status <> 'active' then
    raise exception using errcode = '42501', message = 'This account cannot submit reservations';
  end if;
  if profile.role in ('internal_admin','external_admin') then
    raise exception using errcode = '22023', message = 'Use a member account to submit a reservation';
  end if;
  select * into facility from public.facilities
    where id = p_facility_id and archived_at is null and public_listing for share;
  if facility.id is null then raise exception using errcode = 'P0002', message = 'Facility not found'; end if;
  if cardinality(p_starts_at) is null or cardinality(p_starts_at) not between 1 and 12
     or cardinality(p_starts_at) <> cardinality(p_ends_at) then
    raise exception using errcode = '22023', message = 'Provide between one and twelve valid occurrences';
  end if;
  if jsonb_array_length(coalesce(p_attachment_metadata, '[]'::jsonb)) > 3 then
    raise exception using errcode = '22023', message = 'A maximum of three supporting files is allowed';
  end if;
  select coalesce(array_agg(distinct trim(t) order by trim(t)), '{}')
    into amenities_clean
    from unnest(coalesce(p_amenities, '{}'::text[])) t
    where trim(t) <> '';
  if cardinality(amenities_clean) > 20 then
    raise exception using errcode = '22023', message = 'A maximum of twenty amenities can be requested';
  end if;
  held := profile.verification_status = 'pending';
  payment := case when profile.verification_status = 'verified' then 'not_required' else 'quoted' end;
  insert into public.reservation_requests(
    id, requester_id, facility_id, requester_name, requester_role, requester_unit,
    facility_name, facility_building, facility_room, facility_capacity,
    purpose, headcount, held_for_verification, recurrence,
    payment_amount_centavos, payment_status, amenities
  ) values (
    p_request_id, profile.id, facility.id, coalesce(nullif(profile.full_name,''), profile.email),
    profile.role, coalesce(profile.unit,''), facility.name::text, facility.building,
    facility.room, facility.capacity, trim(p_purpose), p_headcount, held,
    case when cardinality(p_starts_at) > 1 then 'weekly' else 'none' end,
    case when payment = 'quoted' then greatest(0, p_payment_amount_centavos) else 0 end,
    payment, amenities_clean
  ) returning * into result;
  for i in 1..cardinality(p_starts_at) loop
    if p_starts_at[i] >= p_ends_at[i] then
      raise exception using errcode = '22023', message = 'End time must be after start time';
    end if;
    if extract(epoch from (p_ends_at[i] - p_starts_at[i])) / 60 > facility.max_duration_minutes then
      raise exception using errcode = '22023', message = 'Reservation exceeds the facility maximum duration';
    end if;
    if p_starts_at[i] < now() or
       (i = 1 and p_starts_at[i] > now() + make_interval(days => facility.advance_booking_days)) then
      raise exception using errcode = '22023', message = 'Reservation date is outside the booking window';
    end if;
    insert into public.reservation_occurrences(
      request_id, facility_id, starts_at, ends_at, buffer_minutes
    ) values (result.id, facility.id, p_starts_at[i], p_ends_at[i], facility.booking_buffer_minutes);
  end loop;
  for attachment in select value from jsonb_array_elements(coalesce(p_attachment_metadata, '[]'::jsonb)) loop
    if attachment->>'storage_path' not like auth.uid()::text || '/%' then
      raise exception using errcode = '42501', message = 'Invalid attachment path';
    end if;
    insert into public.reservation_attachments(request_id, owner_id, storage_path, file_name, mime_type, byte_size)
    values (result.id, auth.uid(), attachment->>'storage_path', attachment->>'file_name',
            attachment->>'mime_type', (attachment->>'byte_size')::integer);
  end loop;
  event_id := public.reservation_event(result.id, 'submitted a reservation request', null,
    jsonb_build_object('held_for_verification', held, 'amenities', to_jsonb(amenities_clean)), null, false);
  insert into public.app_notifications(recipient_id, request_id, event_id, kind, title, body)
  select p.id, result.id, event_id, 'reservation_submitted', 'New reservation request',
         result.requester_name || ' requested ' || result.facility_name
  from public.profiles p
  where p.role in ('internal_admin','external_admin') and p.account_status = 'active' and not held;
  return result;
end;
$$;
revoke all on function public.submit_reservation_untrusted_amount(
  uuid, uuid, text, integer, timestamptz[], timestamptz[], jsonb, integer, text[]
) from public, anon, authenticated;

create function public.submit_reservation(
  p_request_id uuid, p_facility_id uuid, p_purpose text, p_headcount integer,
  p_starts_at timestamptz[], p_ends_at timestamptz[],
  p_attachment_metadata jsonb default '[]'::jsonb,
  p_payment_amount_centavos integer default 0,
  p_amenities text[] default '{}'
) returns public.reservation_requests
language plpgsql security definer set search_path = public, storage as $$
declare calculated integer; result public.reservation_requests%rowtype;
begin
  calculated := public.reservation_quote_centavos(p_facility_id, p_starts_at, p_ends_at);
  result := public.submit_reservation_untrusted_amount(
    p_request_id, p_facility_id, p_purpose, p_headcount, p_starts_at, p_ends_at,
    p_attachment_metadata, calculated, p_amenities);
  if result.payment_status = 'not_required' then
    delete from public.app_notifications n using public.profiles recipient
    where n.request_id = result.id and n.recipient_id = recipient.id
      and recipient.role = 'external_admin';
  end if;
  return result;
end;
$$;
revoke all on function public.submit_reservation(
  uuid, uuid, text, integer, timestamptz[], timestamptz[], jsonb, integer, text[]
) from public, anon;
grant execute on function public.submit_reservation(
  uuid, uuid, text, integer, timestamptz[], timestamptz[], jsonb, integer, text[]
) to authenticated;;
