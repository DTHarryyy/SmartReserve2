-- Standard catalog amenities (Wi-Fi, accessibility, utilities, etc.) are
-- real reservation service preferences, but they are not rows on the fixed
-- official permit form. Only the facility and persisted, billable/requestable
-- facility_amenity records belong in the printable permit snapshot.

create or replace function public.populate_reservation_permit_items(
  p_request_id uuid
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.reservation_requests%rowtype;
  duration_value integer;
  facility public.facilities%rowtype;
  line record;
  item record;
  ord integer := 0;
begin
  select * into r from public.reservation_requests where id = p_request_id;
  if r.id is null then
    raise exception using errcode = 'P0002', message = 'Reservation not found';
  end if;
  select * into facility from public.facilities where id = r.facility_id;
  if facility.id is null then
    raise exception using errcode = 'P0002', message = 'Facility not found';
  end if;
  select greatest(1, coalesce(sum(
    extract(epoch from (ends_at - starts_at)) / 60
  )::integer, 1)) into duration_value
  from public.reservation_occurrences
  where request_id = r.id
    and booking_state in ('requested', 'held', 'booked', 'checked_in');

  delete from public.reservation_permit_items where request_id = r.id;
  select * into line
  from public.reservation_price_lines
  where request_id = r.id and line_type = 'facility'
  order by created_at limit 1;
  insert into public.reservation_permit_items(
    request_id, source_kind, source_id, label, row_code, duration_minutes,
    billing_basis, unit_amount_centavos, line_total_centavos, display_order
  ) values (
    r.id, 'facility', facility.id, r.facility_name,
    case r.admin_lane
      when 'internal' then 'facility:' || coalesce(facility.internal_permit_row_code, 'unmapped')
      else 'external:' || coalesce(facility.external_permit_row_code, 'unmapped')
    end,
    duration_value, 'hourly', coalesce(line.unit_amount_centavos, 0),
    coalesce(line.line_total_centavos, 0), ord
  );

  for item in
    select a.*, fa.internal_permit_row_code, fa.external_permit_row_code,
      fa.permit_quantity_required, fa.pricing_unit
    from public.reservation_amenities a
    join public.facility_amenities fa on fa.id = a.facility_amenity_id
    where a.request_id = r.id
    order by a.name_snapshot
  loop
    ord := ord + 1;
    insert into public.reservation_permit_items(
      request_id, source_kind, source_id, label, row_code,
      requested_quantity, duration_minutes, billing_basis,
      unit_amount_centavos, line_total_centavos, display_order
    ) values (
      r.id, 'amenity', item.facility_amenity_id, item.name_snapshot,
      case r.admin_lane
        when 'internal' then 'equipment:' || coalesce(item.internal_permit_row_code, 'unmapped')
        else 'external:' || coalesce(item.external_permit_row_code, 'unmapped')
      end,
      case when item.permit_quantity_required then item.quantity else null end,
      duration_value, item.pricing_unit, item.unit_price_centavos,
      item.line_total_centavos, ord
    );
  end loop;
end;
$$;

revoke all on function public.populate_reservation_permit_items(uuid)
  from public, anon, authenticated;
grant execute on function public.populate_reservation_permit_items(uuid)
  to service_role;

-- Rebuild only affected legacy snapshots. The original requested catalog
-- labels remain in reservation_requests. A signature/permit based on the old
-- printable hash is superseded; a fresh request is created only if the real
-- facility mappings are now complete.
do $$
declare
  r record;
  v_hash text;
  v_event uuid;
begin
  for r in
    select distinct request.id, request.requester_id, request.decided_by,
      request.reservation_status, request.version
    from public.reservation_requests request
    join public.reservation_permit_items item on item.request_id = request.id
    where item.source_kind = 'requested_amenity'
  loop
    perform public.populate_reservation_permit_items(r.id);
    v_hash := public.permit_printable_hash(r.id);
    update public.reservation_signature_requests
    set status = 'superseded', signed_at = null, superseded_at = now()
    where request_id = r.id and status in ('requested', 'signed')
      and printable_content_hash is distinct from v_hash;
    update public.reservation_permits
    set status = 'superseded', generation_status = 'failed',
        generation_error_code = 'catalog_items_removed_from_permit'
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
        jsonb_build_object('reason', 'catalog_items_not_printed_on_permit'),
        null, true
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
