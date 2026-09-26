-- Public registration is reserved for outside renters and paying customers.
-- Campus organization representative accounts continue to be admin-issued.

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (
    id,
    email,
    full_name,
    role,
    campus_claim,
    verification_status,
    onboarding_complete,
    account_access_type,
    must_change_password
  )
  values (
    new.id,
    new.email,
    coalesce(new.raw_user_meta_data ->> 'full_name', ''),
    'user',
    'none',
    'none',
    true,
    'external_guest',
    false
  );
  return new;
end;
$$;

notify pgrst, 'reload schema';
