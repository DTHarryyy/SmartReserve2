-- Lets an administrator reissue an already generated permit, e.g. after the
-- permit layout changes. The active permit is superseded and a fresh version
-- (new permit number, current signatures and printable material) is prepared
-- in the same transaction, so a request that is no longer ready keeps its
-- existing permit untouched.
create or replace function public.regenerate_reservation_permit(
  p_request_id uuid,
  p_actor_id uuid
)
returns public.reservation_permits
language plpgsql
security definer
set search_path = public
as $$
declare
  actor_role text;
  existing public.reservation_permits%rowtype;
  result public.reservation_permits%rowtype;
begin
  if p_actor_id is null then
    raise exception using errcode = '42501', message = 'Actor required';
  end if;

  select role into actor_role from public.profiles where id = p_actor_id;
  perform set_config('request.jwt.claim.sub', p_actor_id::text, true);
  if actor_role not in ('internal_admin', 'external_admin')
     or not public.can_manage_reservation(p_request_id) then
    raise exception using errcode = '42501', message = 'Reservation access denied';
  end if;

  perform 1 from public.reservation_requests where id = p_request_id for update;

  select * into existing
  from public.reservation_permits
  where request_id = p_request_id and status = 'active'
  for update;
  if not found then
    raise exception using errcode = '22023', message = 'No active permit to regenerate';
  end if;

  update public.reservation_permits
  set status = 'superseded'
  where id = existing.id;

  result := public.prepare_reservation_permit(p_request_id, p_actor_id);
  if result.id is null then
    raise exception using errcode = '22023',
      message = 'Permit prerequisites are incomplete';
  end if;

  insert into public.audit_entries(
    entity_type, entity_id, target_label, actor_id, actor_name, actor_role,
    action, source_type, source_id, details
  )
  select
    'reservation', p_request_id, result.permit_number, p_actor_id,
    coalesce(nullif(profile.full_name, ''), profile.email), profile.role,
    'regenerated official reservation permit', 'reservation_permit_regeneration',
    result.id, jsonb_build_object(
      'superseded_permit_id', existing.id,
      'superseded_permit_number', existing.permit_number
    )
  from public.profiles profile where profile.id = p_actor_id
  on conflict (source_type, source_id) do nothing;

  return result;
end;
$$;

revoke all on function public.regenerate_reservation_permit(uuid, uuid)
  from public, anon, authenticated;
grant execute on function public.regenerate_reservation_permit(uuid, uuid)
  to service_role;
