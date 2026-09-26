-- Facility mappings are copied into reservation_permit_items. When an
-- administrator repairs a missing mapping after approval, rebuild that
-- snapshot and request a fresh requester signature only if printable content
-- actually changed.

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
    raise exception 'Reservation management access required' using errcode = '42501';
  end if;

  select * into v_request
  from public.reservation_requests
  where id = p_request_id
  for update;
  if not found or v_request.reservation_status not in ('awaiting_payment', 'confirmed') then
    raise exception 'Permit mappings can be refreshed only for an approved reservation'
      using errcode = '22023';
  end if;

  perform public.populate_reservation_permit_items(v_request.id);
  v_hash := public.permit_printable_hash(v_request.id);

  update public.reservation_signature_requests
  set status = 'superseded',
      signed_at = null,
      superseded_at = now()
  where request_id = v_request.id
    and status in ('requested', 'signed')
    and printable_content_hash is distinct from v_hash;

  if not exists (
    select 1
    from public.reservation_signature_requests
    where request_id = v_request.id
      and printable_content_hash = v_hash
      and status in ('requested', 'signed')
  ) then
    insert into public.reservation_signature_requests(
      request_id,
      requester_id,
      requested_by,
      reservation_version,
      printable_content_hash
    ) values (
      v_request.id,
      v_request.requester_id,
      v_actor,
      v_request.version,
      v_hash
    );
    perform public.notify_reservation_user(
      v_request.id,
      public.reservation_event(v_request.id, 'requested refreshed reservation e-signature'),
      'signature_requested',
      'E-signature requested',
      'Permit mappings changed. Please sign the refreshed reservation details.'
    );
  end if;
end;
$$;

revoke all on function public.refresh_reservation_permit_items_for_mapping(uuid)
  from public, anon;
grant execute on function public.refresh_reservation_permit_items_for_mapping(uuid)
  to authenticated;

notify pgrst, 'reload schema';
