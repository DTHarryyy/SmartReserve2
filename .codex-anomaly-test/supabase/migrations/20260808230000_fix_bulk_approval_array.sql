create or replace function public.bulk_approve_reservations(
  p_request_ids uuid[], p_expected_versions jsonb, p_idempotency_key uuid
) returns jsonb
language plpgsql security definer set search_path=public as $$
declare
  id uuid;
  result jsonb;
  action_ids uuid[] := array[]::uuid[];
begin
  if not public.reservation_is_admin() then
    raise exception using errcode='42501',message='Administrator access required';
  end if;
  foreach id in array p_request_ids loop
    result:=public.reservation_action(
      id,'approve',null,'{}'::jsonb,
      (p_expected_versions->>id::text)::integer,
      md5(p_idempotency_key::text||id::text)::uuid
    );
    action_ids:=array_append(action_ids,(result->>'action_id')::uuid);
  end loop;
  return jsonb_build_object('action_ids',action_ids);
end;
$$;

grant execute on function public.bulk_approve_reservations(uuid[],jsonb,uuid)
to authenticated;
