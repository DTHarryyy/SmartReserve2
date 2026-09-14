-- A permit that has not been generated must follow the currently active
-- official signatures. Retaining an old revision after it has been replaced
-- makes Preview succeed (it uses current revisions) while Generate fails.
create or replace function public.prepare_reservation_permit(
  p_request_id uuid,
  p_actor_id uuid
)
returns public.reservation_permits
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.reservation_requests%rowtype;
  readiness jsonb;
  hash_value text;
  existing public.reservation_permits%rowtype;
  result public.reservation_permits%rowtype;
  next_version integer;
  material jsonb;
  user_sig public.reservation_user_signatures%rowtype;
  internal_sig uuid;
  recommender_sig uuid;
  authorized_sig uuid;
  template text;
  template_hash text;
begin
  if p_actor_id is null then
    raise exception using errcode = '42501', message = 'Actor required';
  end if;

  select * into r
  from public.reservation_requests
  where id = p_request_id
  for update;

  perform set_config('request.jwt.claim.sub', p_actor_id::text, true);
  if r.id is null or (
    r.requester_id <> p_actor_id
    and not public.can_manage_reservation(r.id)
  ) then
    raise exception using errcode = '42501', message = 'Reservation access denied';
  end if;

  readiness := public.get_reservation_permit_readiness(r.id);
  if not (readiness ->> 'ready')::boolean then
    return null;
  end if;

  hash_value := readiness ->> 'printable_content_hash';
  select * into user_sig
  from public.reservation_user_signatures
  where request_id = r.id
    and printable_content_hash = hash_value
  order by submitted_at desc
  limit 1;

  template := case r.admin_lane when 'internal' then 'internal' else 'external' end;
  template_hash := case template
    when 'internal' then '4732b1b07c455531615faa3de2b6e2dd2631ec2e4fa609c34ff99e241f64cb58'
    else 'bf328cc2b7eadafae9be130e2ec93342c05dea78a3579f1fccbb58ce1d5767aa'
  end;

  select id into internal_sig
  from public.permit_official_signature_revisions
  where slot = 'internal_approver' and active;
  select id into recommender_sig
  from public.permit_official_signature_revisions
  where slot = 'external_recommender' and active;
  select id into authorized_sig
  from public.permit_official_signature_revisions
  where slot = 'external_authorized_official' and active;

  material := public.permit_printable_material(r.id) || jsonb_build_object(
    'template_kind', template,
    'template_sha256', template_hash,
    'user_signed_at', user_sig.submitted_at
  );

  select * into existing
  from public.reservation_permits
  where request_id = r.id and status = 'active';

  if found
    and existing.content_hash = hash_value
    and existing.template_sha256 = template_hash
    and existing.user_signature_id is not distinct from user_sig.id
    and (
      (
        template = 'internal'
        and existing.internal_approver_signature_id is not distinct from internal_sig
      )
      or (
        template = 'external'
        and existing.external_recommender_signature_id is not distinct from recommender_sig
        and existing.external_authorized_signature_id is not distinct from authorized_sig
      )
    )
  then
    return existing;
  end if;

  if found then
    update public.reservation_permits set status = 'superseded' where id = existing.id;
  end if;

  select coalesce(max(version), 0) + 1 into next_version
  from public.reservation_permits
  where request_id = r.id;

  insert into public.reservation_permits (
    request_id,
    permit_number,
    version,
    status,
    verification_token,
    snapshot,
    content_hash,
    issued_by,
    template_kind,
    template_sha256,
    generation_status,
    user_signature_id,
    internal_approver_signature_id,
    external_recommender_signature_id,
    external_authorized_signature_id
  )
  values (
    r.id,
    'SR-' || to_char(now() at time zone 'Asia/Manila', 'YYYY') || '-' ||
      lpad(nextval('public.reservation_permit_seq')::text, 6, '0'),
    next_version,
    'active',
    encode(extensions.gen_random_bytes(16), 'hex'),
    material,
    hash_value,
    p_actor_id,
    template,
    template_hash,
    'generating',
    user_sig.id,
    case when template = 'internal' then internal_sig end,
    case when template = 'external' then recommender_sig end,
    case when template = 'external' then authorized_sig end
  )
  returning * into result;

  return result;
end;
$$;
