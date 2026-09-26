-- Reservations were being blocked with "This facility needs official permit
-- mappings before it can accept reservations" for generic comfort amenities
-- (Wi-Fi, Parking, Air Conditioning, etc.) that have nothing to do with the
-- official permit paperwork. Investigation: every facility_amenities row in
-- the live database has null permit-row codes except "Sound System" (which
-- has its internal code set). Those null rows could only exist by bypassing
-- both the admin dialog's client-side validation and this RPC's own guard --
-- the RPC's `x not in (...)` check silently no-ops when x is null (SQL
-- three-valued logic: `null not in (...)` is null, not true, so `if null or
-- null then raise` never fires), which is how a row like "Parking" could
-- have been written with both codes null despite the "guard".
--
-- Decision: comfort amenities should never require a permit-row mapping.
-- Only items an admin has actually started mapping to a real official code
-- (today: only Sound System) should keep requiring one. That's captured by
-- the new `requires_permit_mapping` column, backfilled from whether either
-- code is already set -- no guessed label list needed.

alter table public.facility_amenities
  add column if not exists requires_permit_mapping boolean not null default true;

update public.facility_amenities
set requires_permit_mapping = (
  internal_permit_row_code is not null or external_permit_row_code is not null
);

create or replace function public.populate_reservation_permit_items(p_request_id uuid)
returns void
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
end;
$$;

create or replace function public.save_facility_configuration_v3(
  p_facility_id uuid, p_rates jsonb, p_amenities jsonb, p_account_name text, p_account_number text,
  p_instructions text default '', p_deposit_window_minutes integer default 1440,
  p_balance_due_lead_minutes integer default 1440, p_correction_window_minutes integer default 1440,
  p_down_payment_percent integer default 50, p_internal_permit_row_code text default null,
  p_external_permit_row_code text default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  result jsonb;
  item jsonb;
  requires boolean;
begin
  if p_internal_permit_row_code is null
     or p_internal_permit_row_code not in ('audio_visual_main_hall','conference_room','other')
     or p_external_permit_row_code is null
     or p_external_permit_row_code not in ('gym_auditorium','avr','accommodation','love_hall','other') then
    raise exception 'Select explicit internal and external facility permit rows' using errcode='22023';
  end if;
  for item in select value from jsonb_array_elements(coalesce(p_amenities,'[]'::jsonb)) loop
    requires := coalesce((item->>'requires_permit_mapping')::boolean, true);
    if requires and (
      item->>'internal_permit_row_code' is null
      or item->>'internal_permit_row_code' not in ('sound_system','overhead_projector','lcd_accessories','other')
      or item->>'external_permit_row_code' is null
      or item->>'external_permit_row_code' not in ('tables_chairs','lcd_projector','avr','led_video_wall','accommodation','love_hall','other')
    ) then
      raise exception 'Every amenity needs explicit internal and external permit-row mappings' using errcode='22023';
    end if;
  end loop;
  result:=public.save_facility_configuration_v2(p_facility_id,p_rates,p_amenities,p_account_name,p_account_number,
    p_instructions,p_deposit_window_minutes,p_balance_due_lead_minutes,p_correction_window_minutes,p_down_payment_percent);
  update facilities set internal_permit_row_code=p_internal_permit_row_code,
    external_permit_row_code=p_external_permit_row_code where id=p_facility_id;
  for item in select value from jsonb_array_elements(coalesce(p_amenities,'[]'::jsonb)) loop
    update facility_amenities set internal_permit_row_code=item->>'internal_permit_row_code',
      external_permit_row_code=item->>'external_permit_row_code',
      permit_quantity_required=coalesce((item->>'permit_quantity_required')::boolean,false),
      requires_permit_mapping=coalesce((item->>'requires_permit_mapping')::boolean,true)
    where facility_id=p_facility_id and lower(name)=lower(trim(item->>'name'));
  end loop;
  return result;
end $$;

notify pgrst, 'reload schema';
