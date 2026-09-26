-- Storage RLS evaluates the policy query under the requester's table RLS
-- context. Authorize the upload through this tightly scoped helper instead,
-- so a valid signature request is not hidden by a related table policy.
-- The helper deliberately accepts only the exact two-folder object layout
-- produced by the client: <requester UUID>/<reservation UUID>/<filename>.

create or replace function public.can_upload_reservation_signature_object(
  p_object_name text
) returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_actor_id uuid := auth.uid();
  v_folders text[] := storage.foldername(p_object_name);
begin
  if v_actor_id is null
    or coalesce(array_length(v_folders, 1), 0) <> 2
    or v_folders[1] <> v_actor_id::text then
    return false;
  end if;

  return exists (
    select 1
    from public.reservation_signature_requests as signature_request
    where signature_request.request_id::text = v_folders[2]
      and signature_request.requester_id = v_actor_id
      and signature_request.status = 'requested'
  );
end;
$$;

revoke all on function public.can_upload_reservation_signature_object(text)
  from public, anon;
grant execute on function public.can_upload_reservation_signature_object(text)
  to authenticated;

drop policy if exists reservation_signature_upload_own on storage.objects;
create policy reservation_signature_upload_own on storage.objects
  for insert
  to authenticated
  with check (
    bucket_id = 'reservation-signatures'
    and public.can_upload_reservation_signature_object(name)
  );

notify pgrst, 'reload schema';
