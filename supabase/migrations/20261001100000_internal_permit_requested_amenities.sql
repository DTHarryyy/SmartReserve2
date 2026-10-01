-- Internal permits list every requested amenity under B. EQUIPMENT. The
-- standard catalog amenities a requester adds (Wi-Fi, Projector, Sound
-- System, ...) live only in reservation_requests.amenities, not in
-- reservation_amenities, so they never reached the permit. On the internal
-- lane each one not already present as a facility amenity becomes an
-- equipment item: "Sound System" has its own row on the form, everything
-- else is checked and named under Others. Catalog items are never
-- "unmapped", so they cannot block permit generation. The external lane is
-- unchanged.
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
  requested record;
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
      fa.permit_quantity_required, fa.pricing_unit, fa.requires_permit_mapping
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
      case
        when not item.requires_permit_mapping then 'equipment:exempt'
        when r.admin_lane = 'internal' then 'equipment:' || coalesce(item.internal_permit_row_code, 'unmapped')
        else 'external:' || coalesce(item.external_permit_row_code, 'unmapped')
      end,
      case when item.permit_quantity_required then item.quantity else null end,
      duration_value, item.pricing_unit, item.unit_price_centavos,
      item.line_total_centavos, ord
    );
  end loop;

  if r.admin_lane = 'internal' then
    for requested in
      select trim(a.name) as name
      from unnest(coalesce(r.amenities, '{}'::text[])) with ordinality a(name, position)
      where trim(coalesce(a.name, '')) <> ''
        and not exists (
          select 1 from public.reservation_amenities existing
          where existing.request_id = r.id
            and lower(trim(existing.name_snapshot)) = lower(trim(a.name))
        )
      order by a.position
    loop
      ord := ord + 1;
      insert into public.reservation_permit_items(
        request_id, source_kind, source_id, label, row_code, duration_minutes,
        billing_basis, unit_amount_centavos, line_total_centavos, display_order
      ) values (
        r.id, 'requested_amenity', null, left(requested.name, 160),
        case lower(requested.name)
          when 'sound system' then 'equipment:sound_system'
          else 'equipment:other'
        end,
        duration_value, 'included', 0, 0, ord
      );
    end loop;
  end if;
end;
$$;
