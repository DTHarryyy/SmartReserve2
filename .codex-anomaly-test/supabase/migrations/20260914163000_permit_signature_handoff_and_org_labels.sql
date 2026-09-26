-- Make the requester handoff actionable: resending preserves the same
-- immutable signature request rather than creating a duplicate identity.
create or replace function public.request_reservation_signature(
  p_request_id uuid
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.reservation_requests%rowtype;
  actor uuid := auth.uid();
  hash_value text;
  existing_request uuid;
  event_id uuid;
begin
  select * into r from public.reservation_requests where id = p_request_id for update;
  if not found or not public.can_manage_reservation(r.id) then
    raise exception using errcode = '42501', message = 'Reservation management access required';
  end if;
  if r.reservation_status not in ('awaiting_payment', 'confirmed') then
    raise exception using errcode = '22023', message = 'A signature can be requested only after approval';
  end if;
  if not exists (select 1 from public.reservation_permit_items where request_id = r.id) then
    perform public.populate_reservation_permit_items(r.id);
  end if;
  if not (public.get_reservation_permit_configuration(r.id)->>'ready')::boolean then
    raise exception using errcode = '22023', message = 'Complete the required facility permit mappings before requesting a signature';
  end if;

  hash_value := public.permit_printable_hash(r.id);
  select id into existing_request
  from public.reservation_signature_requests
  where request_id = r.id and status = 'requested'
    and printable_content_hash = hash_value;
  if existing_request is not null then
    event_id := public.reservation_event(
      r.id, 'resent reservation e-signature request', null,
      jsonb_build_object('signature_request_id', existing_request), null, true
    );
    perform public.notify_reservation_user(
      r.id, event_id, 'signature_requested', 'E-signature reminder',
      'Your reservation is waiting for your e-signature. Open My reservations to upload it.'
    );
    return;
  end if;

  update public.reservation_signature_requests
  set status = 'superseded', superseded_at = now()
  where request_id = r.id and status = 'requested';
  insert into public.reservation_signature_requests(
    request_id, requester_id, requested_by, reservation_version,
    printable_content_hash
  ) values (r.id, r.requester_id, actor, r.version, hash_value);
  event_id := public.reservation_event(
    r.id, 'requested reservation e-signature', null,
    jsonb_build_object('printable_content_hash', hash_value), null, true
  );
  perform public.notify_reservation_user(
    r.id, event_id, 'signature_requested', 'E-signature requested',
    'Your approved reservation is ready for its reservation-specific signature.'
  );
end;
$$;

-- Repair legacy rows that had already been routed internally but retained an
-- external requester display label. Do not change their immutable lane or
-- financial snapshot; only restore the authoritative organization identity.
do $$
declare
  r record;
  v_hash text;
  v_event uuid;
begin
  for r in
    select request.id, request.requester_id, request.decided_by,
      request.reservation_status, request.version, unit.name as unit_name
    from public.reservation_requests request
    join public.profiles profile on profile.id = request.requester_id
    join public.organization_account_slots slot on slot.id = profile.organization_slot_id
    join public.organizational_units unit on unit.id = slot.unit_id
    where request.admin_lane = 'internal'
      and profile.account_access_type = 'organization_representative'
      and profile.account_status = 'active'
      and profile.verification_status = 'verified'
      and slot.active and unit.active
      and (
        request.requester_category <> 'organization_representative'
        or request.requester_unit is distinct from unit.name
      )
  loop
    update public.reservation_requests
    set requester_category = 'organization_representative',
        requester_unit = r.unit_name
    where id = r.id;
    perform public.populate_reservation_permit_items(r.id);
    v_hash := public.permit_printable_hash(r.id);
    update public.reservation_signature_requests
    set status = 'superseded', signed_at = null, superseded_at = now()
    where request_id = r.id and status in ('requested', 'signed')
      and printable_content_hash is distinct from v_hash;
    update public.reservation_permits
    set status = 'superseded', generation_status = 'failed',
        generation_error_code = 'organization_identity_refreshed'
    where request_id = r.id and status = 'active'
      and content_hash is distinct from v_hash;
    if r.reservation_status in ('awaiting_payment', 'confirmed')
       and not exists (
         select 1 from public.reservation_permit_items
         where request_id = r.id and row_code like '%:unmapped'
       )
       and not exists (
         select 1 from public.reservation_signature_requests
         where request_id = r.id and printable_content_hash = v_hash
           and status in ('requested', 'signed')
       ) then
      insert into public.reservation_signature_requests(
        request_id, requester_id, requested_by, reservation_version,
        printable_content_hash
      ) values (
        r.id, r.requester_id, coalesce(r.decided_by, r.requester_id),
        r.version, v_hash
      );
      v_event := public.reservation_event(
        r.id, 'requested refreshed reservation e-signature', null,
        jsonb_build_object('reason', 'organization_identity_refreshed'), null, true
      );
      perform public.notify_reservation_user(
        r.id, v_event, 'signature_requested', 'E-signature requested',
        'Your approved reservation is ready for its reservation-specific signature.'
      );
    end if;
  end loop;
end;
$$;

notify pgrst, 'reload schema';
