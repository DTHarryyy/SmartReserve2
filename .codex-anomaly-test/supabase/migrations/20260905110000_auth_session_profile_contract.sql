-- Stable, authenticated session bootstrap contract for the Flutter client.
-- Keep this RPC independent of PostgREST relationship inference so a schema
-- cache refresh cannot turn a valid password login into a generic failure.

create or replace function public.get_my_session_profile()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  result jsonb;
begin
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'Sign in required';
  end if;

  -- Preserve the previous login-time normalization behavior without requiring
  -- a second RPC call from the client.
  update public.profiles
  set account_status = 'active',
      suspension_reason = null,
      suspended_until = null
  where id = auth.uid()
    and account_status = 'suspended'
    and suspended_until is not null
    and suspended_until <= (now() at time zone 'Asia/Manila')::date;

  select jsonb_build_object(
    'id', p.id,
    'email', p.email,
    'full_name', p.full_name,
    'role', p.role,
    'campus_claim', p.campus_claim,
    'campus_id', p.campus_id,
    'unit', p.unit,
    'verification_status', p.verification_status,
    'onboarding_complete', p.onboarding_complete,
    'account_status', p.account_status,
    'account_access_type', p.account_access_type,
    'must_change_password', p.must_change_password,
    'created_at', p.created_at,
    'password_issued_at', p.password_issued_at,
    'suspension_reason', p.suspension_reason,
    'suspended_until', p.suspended_until,
    'organization_slot_id', p.organization_slot_id,
    'organization_slot_label', s.label,
    'organization_unit_id', u.id,
    'organization_unit_name', u.name,
    'organization_unit_code', u.code,
    'organization_unit_type', u.unit_type,
    'organization_unit_booking_audience', u.booking_audience
  )
  into result
  from public.profiles p
  left join public.organization_account_slots s on s.id = p.organization_slot_id
  left join public.organizational_units u on u.id = s.unit_id
  where p.id = auth.uid();

  return result;
end;
$$;

revoke all on function public.get_my_session_profile() from public, anon;
grant execute on function public.get_my_session_profile() to authenticated;

notify pgrst, 'reload schema';
