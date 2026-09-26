-- Follow-up to the permit lifecycle migration. Keep this separate because the
-- preceding migration has already been deployed. It closes the remaining
-- race: any content-changing repair invalidates old signatures immediately,
-- even while other mappings are still incomplete.

create or replace function public.refresh_reservation_permit_items_for_mapping(
  p_request_id uuid
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_request public.reservation_requests%rowtype;
  v_actor uuid := auth.uid();
  v_hash text;
begin
  if v_actor is null or not public.can_manage_reservation(p_request_id) then
    raise exception using errcode = '42501', message = 'Reservation management access required';
  end if;
  select * into v_request
  from public.reservation_requests where id = p_request_id for update;
  if not found or v_request.reservation_status not in ('awaiting_payment', 'confirmed') then
    raise exception using errcode = '22023', message = 'Permit mappings can be refreshed only for an approved reservation';
  end if;

  perform public.populate_reservation_permit_items(v_request.id);
  v_hash := public.permit_printable_hash(v_request.id);

  update public.reservation_signature_requests
  set status = 'superseded', signed_at = null, superseded_at = now()
  where request_id = v_request.id and status in ('requested', 'signed')
    and printable_content_hash is distinct from v_hash;
  update public.reservation_permits
  set status = 'superseded', generation_status = 'failed',
      generation_error_code = 'permit_mapping_changed'
  where request_id = v_request.id and status = 'active'
    and content_hash is distinct from v_hash;

  if not (public.get_reservation_permit_configuration(v_request.id)->>'ready')::boolean then
    return;
  end if;
  if not exists (
    select 1 from public.reservation_signature_requests
    where request_id = v_request.id and printable_content_hash = v_hash
      and status in ('requested', 'signed')
  ) then
    insert into public.reservation_signature_requests(
      request_id, requester_id, requested_by, reservation_version,
      printable_content_hash
    ) values (
      v_request.id, v_request.requester_id, v_actor, v_request.version, v_hash
    );
    perform public.notify_reservation_user(
      v_request.id,
      public.reservation_event(v_request.id, 'requested refreshed reservation e-signature'),
      'signature_requested', 'E-signature requested',
      'Permit mappings changed. Please sign the refreshed reservation details.'
    );
  end if;
end;
$$;

-- New reservations fail atomically when their selected facility cannot
-- produce the applicable official permit. The lower-level submission writes
-- are in the same transaction and are rolled back with this typed error.
create or replace function public.submit_reservation_v3(
  p_request_id uuid,p_facility_id uuid,p_purpose text,p_headcount integer,p_starts_at timestamptz[],p_ends_at timestamptz[],
  p_amenity_ids uuid[] default '{}'::uuid[],p_terms_version_ids uuid[] default '{}'::uuid[],p_pricing_fingerprint text default null,
  p_attachment_metadata jsonb default '[]'::jsonb,p_requested_amenities text[] default '{}'::text[],p_discount_claim_id uuid default null,
  p_external_company_organization text default null,p_external_complete_address text default null,
  p_external_contact_numbers text[] default null,p_external_admission_fee_centavos integer default null,
  p_item_quantities jsonb default '{}'::jsonb
) returns public.reservation_requests
language plpgsql
security definer
set search_path = public, storage
as $$
declare
  result public.reservation_requests%rowtype;
  category text;
begin
  result := public.submit_reservation_v2(
    p_request_id,p_facility_id,p_purpose,p_headcount,p_starts_at,p_ends_at,
    p_amenity_ids,p_terms_version_ids,p_pricing_fingerprint,
    p_attachment_metadata,p_requested_amenities,p_discount_claim_id
  );
  if result.admin_lane = 'external' then
    if nullif(trim(p_external_company_organization), '') is null
       or nullif(trim(p_external_complete_address), '') is null
       or cardinality(coalesce(p_external_contact_numbers, '{}')) = 0
       or p_external_admission_fee_centavos is null
       or p_external_admission_fee_centavos < 0 then
      raise exception using errcode = '22023', message = 'Complete all external permit details';
    end if;
    category := 'external_renter';
  else
    select case
      when p.account_access_type = 'organization_representative' then 'organization_representative'
      when p.campus_claim in ('student', 'faculty', 'staff') then p.campus_claim
      else 'verified_internal_user'
    end into category
    from public.profiles p where p.id = result.requester_id;
    perform set_config('app.internal_price_normalization', 'on', true);
    update public.reservation_requests
    set payment_amount_centavos = 0,
        payment_status = 'not_required',
        facility_amount_centavos = 0,
        amenity_amount_centavos = 0,
        discount_amount_centavos = 0,
        total_amount_centavos = 0,
        required_down_payment_centavos = 0,
        payment_exemption = 'internal_user'
    where id = result.id returning * into result;
    update public.reservation_price_lines
    set unit_amount_centavos = 0, line_total_centavos = 0
    where request_id = result.id;
  end if;
  update public.reservation_requests
  set requester_category = category,
      requester_unit = case when category = 'organization_representative' then coalesce((
        select ou.name
        from public.profiles p
        join public.organization_account_slots os on os.id = p.organization_slot_id
        join public.organizational_units ou on ou.id = os.unit_id
        where p.id = result.requester_id
      ), result.requester_unit) else result.requester_unit end,
      external_company_organization = case when result.admin_lane = 'external' then trim(p_external_company_organization) end,
      external_complete_address = case when result.admin_lane = 'external' then trim(p_external_complete_address) end,
      external_contact_numbers = case when result.admin_lane = 'external' then p_external_contact_numbers end,
      external_admission_fee_centavos = case when result.admin_lane = 'external' then p_external_admission_fee_centavos end
  where id = result.id returning * into result;

  perform public.populate_reservation_permit_items(result.id);
  update public.reservation_permit_items item
  set requested_quantity = (p_item_quantities ->> item.source_id::text)::integer
  where item.request_id = result.id
    and item.row_code = 'external:tables_chairs'
    and p_item_quantities ? item.source_id::text
    and (p_item_quantities ->> item.source_id::text) ~ '^[1-9][0-9]*$';
  if result.admin_lane = 'external' and exists (
    select 1 from public.reservation_permit_items
    where request_id = result.id
      and row_code = 'external:tables_chairs'
      and requested_quantity is null
  ) then
    raise exception using errcode = '22023', message = 'Enter the requested tables/chairs quantity';
  end if;
  if not (public.get_reservation_permit_configuration(result.id)->>'ready')::boolean then
    raise exception using errcode = '22023',
      message = 'This facility needs official permit mappings before it can accept reservations';
  end if;
  return result;
end;
$$;

-- A changed schedule or printed reservation field cannot leave a stale
-- signature request active while configuration is incomplete.
create or replace function public.invalidate_permit_for_material_version_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  hash_value text;
  actor uuid;
begin
  if old.version is not distinct from new.version then return new; end if;
  update public.reservation_signature_requests
  set status = 'superseded', signed_at = null, superseded_at = now()
  where request_id = new.id and status in ('requested', 'signed');
  update public.reservation_permits
  set status = 'superseded', generation_status = 'failed',
      generation_error_code = 'reservation_changed'
  where request_id = new.id and status = 'active';
  if new.reservation_status in ('awaiting_payment', 'confirmed') then
    if exists (select 1 from public.reservation_permit_items where request_id = new.id) then
      update public.reservation_permit_items
      set duration_minutes = greatest(1, coalesce((
        select sum(extract(epoch from (o.ends_at - o.starts_at)) / 60)::integer
        from public.reservation_occurrences o where o.request_id = new.id
      ), 1))
      where request_id = new.id;
    else
      perform public.populate_reservation_permit_items(new.id);
    end if;
    if exists (
      select 1 from public.reservation_permit_items
      where request_id = new.id and row_code like '%:unmapped'
    ) then
      return new;
    end if;
    hash_value := public.permit_printable_hash(new.id);
    actor := coalesce(auth.uid(), new.decided_by, new.requester_id);
    insert into public.reservation_signature_requests(
      request_id, requester_id, requested_by, reservation_version,
      printable_content_hash
    ) values (new.id, new.requester_id, actor, new.version, hash_value);
    perform public.notify_reservation_user(
      new.id, public.reservation_event(new.id, 'requested reservation e-signature'),
      'signature_requested', 'E-signature requested',
      'Reservation details changed. Please sign the updated reservation details.'
    );
  end if;
  return new;
end;
$$;

notify pgrst, 'reload schema';
