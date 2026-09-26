create or replace function public.decide_verification(
  p_submission_id uuid,
  p_decision text,
  p_reason text default null
)
returns table (submission_id uuid, user_id uuid, document_path text, status text)
language plpgsql
security definer
set search_path = public
as $$
declare
  actor uuid := auth.uid();
begin
  if actor is null or not public.is_internal_admin(actor) then
    raise exception using errcode = '42501', message = 'Active internal administrator access is required';
  end if;

  return query
  select *
  from public.decide_verification_atomic(
    p_submission_id,
    p_decision,
    p_reason,
    actor
  );
end;
$$;

revoke all on function public.decide_verification(uuid, text, text)
from public, anon;
grant execute on function public.decide_verification(uuid, text, text)
to authenticated;
