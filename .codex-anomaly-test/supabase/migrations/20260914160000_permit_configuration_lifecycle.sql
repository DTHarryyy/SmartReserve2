-- Permit configuration must be complete before a requester is asked to sign.
-- This migration keeps the existing permit documents and snapshots, but makes
-- the mapping prerequisite explicit, lane-aware, and repairable in place.

alter table public.reservation_permits
  add column if not exists delivery_status text not null default 'not_sent'
    check (delivery_status in ('not_sent', 'sent')),
  add column if not exists delivered_at timestamptz,
  add column if not exists delivered_by uuid references public.profiles(id)
    on delete set null;

alter table public.reservation_permits
  drop constraint if exists reservation_permits_delivery_state_check;
alter table public.reservation_permits
  add constraint reservation_permits_delivery_state_check check (
    (delivery_status = 'not_sent' and delivered_at is null)
    or (delivery_status = 'sent' and delivered_at is not null)
  );

-- Existing generated permits were already announced by the predecessor. Keep
-- them downloadable; new permits require an explicit, audited delivery.
update public.reservation_permits
set delivery_status = 'sent',
    delivered_at = coalesce(pdf_generated_at, issued_at)
where generation_status = 'ready'
  and delivery_status = 'not_sent'
  and delivered_at is null;

-- A small, stable contract for the client. It returns only the missing rows
-- for this reservation and lane; it is deliberately not a copy of the broad
-- facility rates/payment configuration screen.
create or replace function public.get_reservation_permit_configuration(
  p_request_id uuid
) returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_request public.reservation_requests%rowtype;
  v_missing jsonb;
begin
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'Sign in required';
  end if;

  select * into v_request
  from public.reservation_requests
  where id = p_request_id;

  if not found or not public.can_access_reservation(p_request_id) then
    raise exception using errcode = '42501', message = 'Reservation access denied';
  end if;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'source_kind', item.source_kind,
        'source_id', item.source_id,
        'label', item.label,
        'row_code', item.row_code,
        'lane', v_request.admin_lane,
        'can_configure', item.source_kind in ('facility', 'amenity')
      ) order by item.display_order, item.label
    ),
    '[]'::jsonb
  ) into v_missing
  from public.reservation_permit_items item
  where item.request_id = v_request.id
    and item.row_code like '%:unmapped';

  return jsonb_build_object(
    'ready', jsonb_array_length(v_missing) = 0,
    'lane', v_request.admin_lane,
    'missing_mappings', v_missing
  );
end;
$$;

revoke all on function public.get_reservation_permit_configuration(uuid)
  from public, anon;
grant execute on function public.get_reservation_permit_configuration(uuid)
  to authenticated;

-- Extend the existing readiness response without changing its public return
-- type. Signature and official-signature checks remain separate from mapping
-- readiness, so the UI can explain exactly who needs to act.
create or replace function public.get_reservation_permit_readiness(
  p_request_id uuid
) returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  r public.reservation_requests%rowtype;
  blockers jsonb := '[]'::jsonb;
  paid integer;
  hash_value text;
  sig record;
  configuration jsonb;
begin
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'Sign in required';
  end if;

  select * into r from public.reservation_requests where id = p_request_id;
  if not found or (r.requester_id <> auth.uid() and not public.can_manage_reservation(r.id)) then
    raise exception using errcode = '42501', message = 'Reservation access denied';
  end if;

  configuration := public.get_reservation_permit_configuration(r.id);
  if not (configuration->>'ready')::boolean then
    blockers := blockers || '"unmapped_permit_item"'::jsonb;
  end if;
  if r.admin_lane = 'internal' and r.reservation_status <> 'confirmed' then
    blockers := blockers || '"not_confirmed"'::jsonb;
  end if;
  if r.admin_lane = 'external' and r.reservation_status not in ('confirmed', 'completed') then
    blockers := blockers || '"not_confirmed"'::jsonb;
  end if;
  select coalesce(sum(amount_centavos), 0) into paid
  from public.payment_transactions
  where request_id = r.id and status = 'verified' and purpose <> 'refund';
  if r.admin_lane = 'external' and paid < r.total_amount_centavos then
    blockers := blockers || '"full_payment_required"'::jsonb;
  end if;
  if trim(r.requester_unit) = '' and r.admin_lane = 'internal' then
    blockers := blockers || '"requester_unit_required"'::jsonb;
  end if;
  if r.admin_lane = 'external' and (
    nullif(trim(r.external_company_organization), '') is null
    or nullif(trim(r.external_complete_address), '') is null
    or cardinality(coalesce(r.external_contact_numbers, '{}')) = 0
    or r.external_admission_fee_centavos is null
  ) then
    blockers := blockers || '"external_details_required"'::jsonb;
  end if;
  if not exists (
    select 1 from public.reservation_permit_items
    where request_id = r.id and source_kind = 'facility'
  ) then
    blockers := blockers || '"permit_items_required"'::jsonb;
  end if;
  if not exists (
    select 1 from public.reservation_occurrences
    where request_id = r.id and booking_state in ('held', 'booked', 'checked_in')
  ) then
    blockers := blockers || '"schedule_required"'::jsonb;
  end if;
  if r.admin_lane = 'external' and (
    select count(*) from public.reservation_permit_items where request_id = r.id
  ) > 8 then
    blockers := blockers || '"external_row_limit"'::jsonb;
  end if;
  if r.admin_lane = 'external' and exists (
    select 1 from public.reservation_permit_items
    where request_id = r.id
    group by row_code having count(*) > 1
  ) then
    blockers := blockers || '"duplicate_external_row"'::jsonb;
  end if;
  if r.admin_lane = 'external' and exists (
    select 1 from public.reservation_permit_items
    where request_id = r.id
      and row_code = 'external:tables_chairs'
      and requested_quantity is null
  ) then
    blockers := blockers || '"item_quantity_required"'::jsonb;
  end if;
  hash_value := public.permit_printable_hash(r.id);
  select s.id, s.printable_content_hash into sig
  from public.reservation_user_signatures s
  where s.request_id = r.id
  order by s.submitted_at desc limit 1;
  if sig.id is null or sig.printable_content_hash is distinct from hash_value then
    blockers := blockers || '"requester_signature_required"'::jsonb;
  end if;
  if r.admin_lane = 'internal' and not exists (
    select 1 from public.permit_official_signature_revisions
    where slot = 'internal_approver' and active
  ) then
    blockers := blockers || '"internal_approver_signature_required"'::jsonb;
  end if;
  if r.admin_lane = 'external' and not exists (
    select 1 from public.permit_official_signature_revisions
    where slot = 'external_recommender' and active
  ) then
    blockers := blockers || '"external_recommender_signature_required"'::jsonb;
  end if;
  if r.admin_lane = 'external' and not exists (
    select 1 from public.permit_official_signature_revisions
    where slot = 'external_authorized_official' and active
  ) then
    blockers := blockers || '"external_authorized_signature_required"'::jsonb;
  end if;

  return jsonb_build_object(
    'ready', jsonb_array_length(blockers) = 0,
    'template_kind', r.admin_lane,
    'blockers', blockers,
    'printable_content_hash', hash_value,
    'configuration', configuration
  );
end;
$$;

-- This is the narrow, reservation-aware repair operation. It only permits
-- row codes that exist on the supplied official forms and only updates the
-- facility/amenities that belong to the selected reservation.
create or replace function public.save_reservation_permit_mappings(
  p_request_id uuid,
  p_mappings jsonb
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.reservation_requests%rowtype;
  entry jsonb;
  v_kind text;
  v_source_id uuid;
  v_row_code text;
  v_actor uuid := auth.uid();
  v_configuration jsonb;
begin
  if v_actor is null or not public.can_manage_reservation(p_request_id) then
    raise exception using errcode = '42501', message = 'Reservation management access required';
  end if;
  if jsonb_typeof(p_mappings) <> 'array' or jsonb_array_length(p_mappings) = 0 then
    raise exception using errcode = '22023', message = 'Choose at least one permit mapping';
  end if;

  select * into r from public.reservation_requests where id = p_request_id for update;
  if not found or r.reservation_status not in ('awaiting_payment', 'confirmed') then
    raise exception using errcode = '22023', message = 'Permit mappings can be updated only for an approved reservation';
  end if;

  for entry in select value from jsonb_array_elements(p_mappings) loop
    v_kind := entry->>'source_kind';
    v_source_id := nullif(entry->>'source_id', '')::uuid;
    v_row_code := lower(trim(coalesce(entry->>'row_code', '')));

    if v_kind not in ('facility', 'amenity') or v_source_id is null then
      raise exception using errcode = '22023', message = 'Only persisted facility and amenity rows can be mapped';
    end if;
    if not exists (
      select 1 from public.reservation_permit_items item
      where item.request_id = r.id
        and item.source_kind = v_kind
        and item.source_id = v_source_id
    ) then
      raise exception using errcode = '42501', message = 'Permit mapping is not part of this reservation';
    end if;

    if v_kind = 'facility' then
      if r.admin_lane = 'internal' then
        if v_row_code not in ('audio_visual_main_hall', 'conference_room', 'other') then
          raise exception using errcode = '22023', message = 'Select an internal facility row from the official form';
        end if;
        update public.facilities set internal_permit_row_code = v_row_code
        where id = r.facility_id and id = v_source_id;
      else
        if v_row_code not in ('gym_auditorium', 'avr', 'accommodation', 'love_hall', 'other') then
          raise exception using errcode = '22023', message = 'Select an external facility row from the official form';
        end if;
        update public.facilities set external_permit_row_code = v_row_code
        where id = r.facility_id and id = v_source_id;
      end if;
    else
      if r.admin_lane = 'internal' then
        if v_row_code not in ('sound_system', 'overhead_projector', 'lcd_accessories', 'other') then
          raise exception using errcode = '22023', message = 'Select an internal amenity row from the official form';
        end if;
        update public.facility_amenities set internal_permit_row_code = v_row_code
        where id = v_source_id and facility_id = r.facility_id;
      else
        if v_row_code not in ('tables_chairs', 'lcd_projector', 'avr', 'led_video_wall', 'accommodation', 'love_hall', 'other') then
          raise exception using errcode = '22023', message = 'Select an external amenity row from the official form';
        end if;
        update public.facility_amenities set external_permit_row_code = v_row_code,
          permit_quantity_required = (v_row_code = 'tables_chairs')
        where id = v_source_id and facility_id = r.facility_id;
      end if;
      if not found then
        raise exception using errcode = '42501', message = 'Amenity mapping does not belong to this facility';
      end if;
    end if;
  end loop;

  perform public.populate_reservation_permit_items(r.id);
  perform public.refresh_reservation_permit_items_for_mapping(r.id);
  v_configuration := public.get_reservation_permit_configuration(r.id);

  insert into public.audit_entries(
    entity_type, entity_id, target_label, actor_id, actor_name, actor_role,
    action, source_type, source_id, details
  )
  select
    'reservation', r.id, r.facility_name, v_actor,
    coalesce(nullif(p.full_name, ''), p.email), p.role,
    'updated reservation permit mappings', 'reservation_permit_mapping',
    r.id, jsonb_build_object('lane', r.admin_lane, 'ready', v_configuration->>'ready')
  from public.profiles p where p.id = v_actor
  on conflict (source_type, source_id) do update
    set details = excluded.details;

  return v_configuration;
end;
$$;

revoke all on function public.save_reservation_permit_mappings(uuid, jsonb)
  from public, anon;
grant execute on function public.save_reservation_permit_mappings(uuid, jsonb)
  to authenticated;

-- Never create an e-signature task against an incomplete printable form.
create or replace function public.request_reservation_signature(p_request_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.reservation_requests%rowtype;
  actor uuid := auth.uid();
  hash_value text;
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
  if exists (
    select 1 from public.reservation_signature_requests
    where request_id = r.id and status = 'requested'
      and printable_content_hash = hash_value
  ) then
    return;
  end if;
  update public.reservation_signature_requests
  set status = 'superseded', superseded_at = now()
  where request_id = r.id and status = 'requested';
  insert into public.reservation_signature_requests(
    request_id, requester_id, requested_by, reservation_version,
    printable_content_hash
  ) values (r.id, r.requester_id, actor, r.version, hash_value);
  perform public.notify_reservation_user(
    r.id, public.reservation_event(r.id, 'requested reservation e-signature'),
    'signature_requested', 'E-signature requested',
    'Your approved reservation is ready for its reservation-specific signature.'
  );
end;
$$;

-- Approval still holds the selected schedule, but creates a signature task
-- only when the facility can produce the actual official form.
create or replace function public.auto_request_permit_signature_after_approval()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  hash_value text;
  actor uuid;
begin
  if new.reservation_status not in ('awaiting_payment', 'confirmed')
     or old.reservation_status is not distinct from new.reservation_status then
    return new;
  end if;
  if not exists (select 1 from public.reservation_permit_items where request_id = new.id) then
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
  update public.reservation_signature_requests
  set status = 'superseded', superseded_at = now()
  where request_id = new.id and status = 'requested'
    and printable_content_hash is distinct from hash_value;
  if not exists (
    select 1 from public.reservation_signature_requests
    where request_id = new.id and status = 'requested'
      and printable_content_hash = hash_value
  ) then
    insert into public.reservation_signature_requests(
      request_id, requester_id, requested_by, reservation_version,
      printable_content_hash
    ) values (new.id, new.requester_id, actor, new.version, hash_value);
    perform public.notify_reservation_user(
      new.id, public.reservation_event(new.id, 'requested reservation e-signature'),
      'signature_requested', 'E-signature requested',
      'Your approved reservation is ready for its reservation-specific signature.'
    );
  end if;
  return new;
end;
$$;

-- After a configuration change, preserve the one-signature-per-printable-
-- version rule. Do not issue another request until every mapping is resolved.
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
  if not (public.get_reservation_permit_configuration(v_request.id)->>'ready')::boolean then
    return;
  end if;
  v_hash := public.permit_printable_hash(v_request.id);
  update public.reservation_signature_requests
  set status = 'superseded', signed_at = null, superseded_at = now()
  where request_id = v_request.id and status in ('requested', 'signed')
    and printable_content_hash is distinct from v_hash;
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

-- Generation is a document-production action. Delivery is a separate,
-- explicit and auditable requester notification action.
create or replace function public.record_generated_permit(
  p_permit_id uuid,
  p_storage_path text,
  p_sha256 text,
  p_byte_size integer
) returns public.reservation_permits
language plpgsql
security definer
set search_path = public
as $$
declare
  p public.reservation_permits%rowtype;
  r public.reservation_requests%rowtype;
  result public.reservation_permits%rowtype;
begin
  select * into p from public.reservation_permits where id = p_permit_id for update;
  select * into r from public.reservation_requests where id = p.request_id;
  if p.id is null or p.status <> 'active' then
    raise exception using errcode = '22023', message = 'Permit is no longer active';
  end if;
  if p.generation_status = 'ready' then return p; end if;
  if p_storage_path <> r.requester_id::text || '/' || r.id::text || '/' || p.permit_number || '-v' || p.version::text || '.pdf' then
    raise exception using errcode = '42501', message = 'Invalid permit path';
  end if;
  if p_byte_size not between 1 and 10485760 or lower(p_sha256) !~ '^[0-9a-f]{64}$' then
    raise exception using errcode = '22023', message = 'Invalid permit file metadata';
  end if;
  update public.reservation_permits
  set storage_path = p_storage_path,
      pdf_sha256 = lower(p_sha256),
      pdf_byte_size = p_byte_size,
      pdf_generated_at = now(),
      generation_status = 'ready',
      generation_error_code = null,
      delivery_status = 'not_sent',
      delivered_at = null,
      delivered_by = null
  where id = p.id returning * into result;
  insert into public.audit_entries(
    entity_type, entity_id, target_label, actor_id, actor_name, actor_role,
    action, source_type, source_id, details
  )
  select
    'reservation', r.id, p.permit_number, p.issued_by,
    coalesce(nullif(profile.full_name, ''), profile.email), profile.role,
    'generated official reservation permit', 'reservation_permit_generation',
    p.id, jsonb_build_object(
      'template_kind', p.template_kind,
      'template_sha256', p.template_sha256,
      'pdf_sha256', lower(p_sha256),
      'byte_size', p_byte_size
    )
  from public.profiles profile where profile.id = p.issued_by
  on conflict (source_type, source_id) do nothing;
  return result;
end;
$$;

create or replace function public.deliver_reservation_permit(
  p_permit_id uuid
) returns public.reservation_permits
language plpgsql
security definer
set search_path = public
as $$
declare
  p public.reservation_permits%rowtype;
  r public.reservation_requests%rowtype;
  v_actor uuid := auth.uid();
  result public.reservation_permits%rowtype;
begin
  if v_actor is null then
    raise exception using errcode = '42501', message = 'Sign in required';
  end if;
  select * into p from public.reservation_permits where id = p_permit_id for update;
  select * into r from public.reservation_requests where id = p.request_id;
  if p.id is null or r.id is null or not public.can_manage_reservation(r.id) then
    raise exception using errcode = '42501', message = 'Reservation management access required';
  end if;
  if p.status <> 'active' or p.generation_status <> 'ready' or p.storage_path is null then
    raise exception using errcode = '22023', message = 'Generate the active official permit before sending it';
  end if;
  if p.delivery_status = 'sent' then return p; end if;

  update public.reservation_permits
  set delivery_status = 'sent', delivered_at = now(), delivered_by = v_actor
  where id = p.id returning * into result;
  perform public.notify_reservation_user(
    r.id,
    public.reservation_event(r.id, 'delivered official reservation permit', null,
      jsonb_build_object('permit_id', p.id, 'permit_number', p.permit_number), null, true),
    'permit_available',
    'Official permit available',
    'Your official reservation permit is ready to download and print.'
  );
  insert into public.audit_entries(
    entity_type, entity_id, target_label, actor_id, actor_name, actor_role,
    action, source_type, source_id, details
  )
  select
    'reservation', r.id, p.permit_number, v_actor,
    coalesce(nullif(profile.full_name, ''), profile.email), profile.role,
    'delivered official reservation permit', 'reservation_permit_delivery',
    p.id, jsonb_build_object('recipient_id', r.requester_id, 'delivery_method', 'in_app')
  from public.profiles profile where profile.id = v_actor
  on conflict (source_type, source_id) do nothing;
  return result;
end;
$$;

revoke all on function public.deliver_reservation_permit(uuid)
  from public, anon;
grant execute on function public.deliver_reservation_permit(uuid)
  to authenticated;

drop policy if exists reservation_permits_storage_read on storage.objects;
create policy reservation_permits_storage_read on storage.objects
for select to authenticated using (
  bucket_id = 'reservation-permits'
  and exists (
    select 1 from public.reservation_permits p
    where p.storage_path = name
      and p.status = 'active'
      and p.generation_status = 'ready'
      and (
        public.can_manage_reservation(p.request_id)
        or (p.delivery_status = 'sent' and public.can_access_reservation(p.request_id))
      )
  )
);

notify pgrst, 'reload schema';
