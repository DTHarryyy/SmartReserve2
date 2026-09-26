-- Complete the organization-management lifecycle and make Edge Function
-- provisioning safe to deploy on a clean project.

-- Names are unique among active siblings after whitespace/case normalization.
-- The sentinel gives root organizations the same protection as child units.
create unique index if not exists organizational_units_active_sibling_name_key
  on public.organizational_units (
    coalesce(parent_id, '00000000-0000-0000-0000-000000000000'::uuid),
    lower(btrim(name))
  )
  where active;

create or replace function public.organization_representative_slot_preflight(
  p_actor uuid,
  p_slot_id uuid
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  slot_row public.organization_account_slots%rowtype;
  unit_row public.organizational_units%rowtype;
begin
  if not public.is_internal_admin(p_actor) then
    raise exception using errcode = '42501', message = 'Only internal administrators can provision organization representatives';
  end if;

  select * into slot_row
  from public.organization_account_slots
  where id = p_slot_id;
  if slot_row.id is null or not slot_row.active then
    raise exception using errcode = '22023', message = 'Organization account slot is not active';
  end if;

  select * into unit_row
  from public.organizational_units
  where id = slot_row.unit_id;
  if unit_row.id is null or not unit_row.active or not unit_row.requires_representative then
    raise exception using errcode = '22023', message = 'Organization unit is not available for representative accounts';
  end if;

  if exists (
    select 1 from public.profiles
    where organization_slot_id = slot_row.id and account_status = 'active'
  ) then
    raise exception using errcode = '23505', message = 'This organization account slot is already assigned';
  end if;

  return jsonb_build_object(
    'slot_id', slot_row.id,
    'slot_label', slot_row.label,
    'unit_id', unit_row.id,
    'unit_name', unit_row.name,
    'unit_code', unit_row.code,
    'booking_audience', unit_row.booking_audience,
    'active', true,
    'vacant', true
  );
end;
$$;

create or replace function public.provision_organization_representative_profile_v2(
  p_actor uuid,
  p_profile_id uuid,
  p_email text,
  p_full_name text,
  p_slot_id uuid
) returns public.profiles
language plpgsql
security definer
set search_path = public
as $$
declare
  slot_row public.organization_account_slots%rowtype;
  unit_row public.organizational_units%rowtype;
  before_row public.profiles%rowtype;
  result public.profiles%rowtype;
  email_value text := lower(trim(coalesce(p_email, '')));
  name_value text := trim(coalesce(p_full_name, ''));
begin
  if not public.is_internal_admin(p_actor) then
    raise exception using errcode = '42501', message = 'Only internal administrators can provision organization representatives';
  end if;
  if email_value !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
    raise exception using errcode = '22023', message = 'Enter a valid email address';
  end if;
  if length(name_value) < 2 then
    raise exception using errcode = '22023', message = 'Enter the representative full name';
  end if;
  if not exists (
    select 1 from auth.users
    where id = p_profile_id and lower(email) = email_value
  ) then
    raise exception using errcode = 'P0002', message = 'New Auth user was not found for representative provisioning';
  end if;

  select * into slot_row from public.organization_account_slots where id = p_slot_id for update;
  if slot_row.id is null or not slot_row.active then
    raise exception using errcode = '22023', message = 'Organization account slot is not active';
  end if;
  select * into unit_row from public.organizational_units where id = slot_row.unit_id for update;
  if unit_row.id is null or not unit_row.active or not unit_row.requires_representative then
    raise exception using errcode = '22023', message = 'Organization unit is not available for representative accounts';
  end if;
  if exists (
    select 1 from public.profiles p
    where p.organization_slot_id = slot_row.id
      and p.account_status = 'active'
      and p.id <> p_profile_id
  ) then
    raise exception using errcode = '23505', message = 'This organization account slot is already assigned';
  end if;

  select * into before_row from public.profiles where id = p_profile_id for update;
  if before_row.id is not null and lower(before_row.email) <> email_value then
    raise exception using errcode = '22023', message = 'The profile email does not match the new account';
  end if;

  insert into public.profiles (
    id, email, full_name, role, account_status, account_access_type,
    organization_slot_id, campus_claim, campus_id, verification_status,
    onboarding_complete, unit, must_change_password, password_issued_at,
    invitation_sent_at
  ) values (
    p_profile_id, email_value, name_value, 'user', 'active',
    'organization_representative', slot_row.id, unit_row.booking_audience,
    null, 'verified', true, coalesce(nullif(unit_row.code, ''), unit_row.name::text),
    true, now(), null
  ) on conflict (id) do update set
    email = excluded.email,
    full_name = excluded.full_name,
    role = excluded.role,
    account_status = excluded.account_status,
    account_access_type = excluded.account_access_type,
    organization_slot_id = excluded.organization_slot_id,
    campus_claim = excluded.campus_claim,
    campus_id = excluded.campus_id,
    verification_status = excluded.verification_status,
    onboarding_complete = excluded.onboarding_complete,
    unit = excluded.unit,
    must_change_password = excluded.must_change_password,
    password_issued_at = excluded.password_issued_at,
    invitation_sent_at = excluded.invitation_sent_at
  returning * into result;

  insert into public.account_admin_events(actor_id, target_id, target_email, action, reason, before_values, after_values)
  values (
    p_actor, result.id, result.email, 'create_organization_representative', null,
    coalesce(to_jsonb(before_row), '{}'::jsonb), to_jsonb(result)
  );
  return result;
end;
$$;

create or replace function public.create_organization_unit(
  p_name text,
  p_code text default null,
  p_parent_id uuid default null,
  p_unit_type text default 'student_organization',
  p_requires_representative boolean default true,
  p_booking_audience text default null
) returns public.organizational_units
language plpgsql security definer set search_path = public
as $$
declare result public.organizational_units%rowtype; slot_row public.organization_account_slots%rowtype;
begin
  if not public.is_internal_admin() then raise exception using errcode = '42501', message = 'Only internal administrators can manage organization units'; end if;
  if length(trim(coalesce(p_name, ''))) < 2 then raise exception using errcode = '22023', message = 'Organization name is required'; end if;
  if p_unit_type not in ('college', 'department', 'office', 'student_organization', 'dean_office') then raise exception using errcode = '22023', message = 'Invalid organization unit type'; end if;
  if p_parent_id is not null and not exists (
    select 1 from public.organizational_units where id = p_parent_id and active and not requires_representative
  ) then raise exception using errcode = '22023', message = 'Parent organization must be an active container'; end if;
  if coalesce(p_requires_representative, true) and p_booking_audience not in ('student', 'faculty', 'staff') then raise exception using errcode = '22023', message = 'Choose Student, Faculty, or University Staff for this organization account'; end if;
  if not coalesce(p_requires_representative, true) and p_booking_audience is not null then raise exception using errcode = '22023', message = 'Container organizations cannot have a booking audience'; end if;
  insert into public.organizational_units(parent_id, name, code, unit_type, requires_representative, booking_audience, created_by)
  values (p_parent_id, trim(p_name), nullif(trim(coalesce(p_code, '')), ''), p_unit_type, coalesce(p_requires_representative, true), case when coalesce(p_requires_representative, true) then p_booking_audience else null end, auth.uid()) returning * into result;
  insert into public.account_admin_events(actor_id, target_id, target_email, action, reason, before_values, after_values) values (auth.uid(), null, result.name::text, 'create_organization_unit', null, '{}'::jsonb, to_jsonb(result));
  if result.requires_representative then
    insert into public.organization_account_slots(unit_id, label) values (result.id, 'Authorized representative') returning * into slot_row;
    insert into public.account_admin_events(actor_id, target_id, target_email, action, reason, before_values, after_values) values (auth.uid(), null, slot_row.id::text, 'create_organization_account_slot', null, '{}'::jsonb, to_jsonb(slot_row));
  end if;
  return result;
end;
$$;

create or replace function public.update_organization_unit_policy(
  p_unit_id uuid, p_name text, p_code text default null, p_parent_id uuid default null,
  p_unit_type text default 'student_organization', p_booking_audience text default null
) returns public.organizational_units
language plpgsql security definer set search_path = public
as $$
declare before_row public.organizational_units%rowtype; result public.organizational_units%rowtype;
begin
  if not public.is_internal_admin() then raise exception using errcode = '42501', message = 'Only internal administrators can manage organization units'; end if;
  select * into before_row from public.organizational_units where id = p_unit_id for update;
  if before_row.id is null then raise exception using errcode = 'P0002', message = 'Organization unit not found'; end if;
  if length(trim(coalesce(p_name, ''))) < 2 then raise exception using errcode = '22023', message = 'Organization name is required'; end if;
  if p_unit_type not in ('college', 'department', 'office', 'student_organization', 'dean_office') then raise exception using errcode = '22023', message = 'Invalid organization unit type'; end if;
  if p_parent_id = p_unit_id then raise exception using errcode = '22023', message = 'An organization cannot be its own parent'; end if;
  if p_parent_id is not null and not exists (select 1 from public.organizational_units where id = p_parent_id and active and not requires_representative) then raise exception using errcode = '22023', message = 'Parent organization must be an active container'; end if;
  if p_parent_id is not null and exists (
    with recursive descendants(id) as (
      select id from public.organizational_units where parent_id = p_unit_id
      union select unit.id from public.organizational_units unit join descendants d on unit.parent_id = d.id
    ) select 1 from descendants where id = p_parent_id
  ) then raise exception using errcode = '22023', message = 'An organization cannot be moved beneath one of its children'; end if;
  if before_row.requires_representative and p_booking_audience not in ('student', 'faculty', 'staff') then raise exception using errcode = '22023', message = 'Choose Student, Faculty, or University Staff for this organization account'; end if;
  if not before_row.requires_representative and p_booking_audience is not null then raise exception using errcode = '22023', message = 'Container organizations cannot have a booking audience'; end if;
  update public.organizational_units set parent_id = p_parent_id, name = trim(p_name), code = nullif(trim(coalesce(p_code, '')), ''), unit_type = p_unit_type, booking_audience = case when before_row.requires_representative then p_booking_audience else null end where id = p_unit_id returning * into result;
  update public.profiles p set campus_claim = result.booking_audience, unit = coalesce(nullif(result.code, ''), result.name::text) from public.organization_account_slots s where p.organization_slot_id = s.id and s.unit_id = result.id and p.account_access_type = 'organization_representative';
  insert into public.account_admin_events(actor_id, target_id, target_email, action, reason, before_values, after_values) values (auth.uid(), null, result.name::text, 'update_organization_unit_policy', null, to_jsonb(before_row), to_jsonb(result));
  return result;
end;
$$;

create or replace function public.archive_organization_unit_policy(p_unit_id uuid)
returns public.organizational_units
language plpgsql security definer set search_path = public
as $$
declare before_row public.organizational_units%rowtype; result public.organizational_units%rowtype;
begin
  if not public.is_internal_admin() then raise exception using errcode = '42501', message = 'Only internal administrators can manage organization units'; end if;
  select * into before_row from public.organizational_units where id = p_unit_id for update;
  if before_row.id is null then raise exception using errcode = 'P0002', message = 'Organization unit not found'; end if;
  if exists (select 1 from public.organizational_units where parent_id = p_unit_id and active) then raise exception using errcode = '23503', message = 'Archive or move active child organizations first'; end if;
  if exists (select 1 from public.organization_account_slots s join public.profiles p on p.organization_slot_id = s.id where s.unit_id = p_unit_id and s.active and p.account_status = 'active') then raise exception using errcode = '23503', message = 'Transfer or remove the representative before archiving this organization'; end if;
  update public.organizational_units set active = false where id = p_unit_id returning * into result;
  update public.organization_account_slots set active = false where unit_id = p_unit_id;
  insert into public.account_admin_events(actor_id, target_id, target_email, action, reason, before_values, after_values) values (auth.uid(), null, result.name::text, 'archive_organization_unit_policy', null, to_jsonb(before_row), to_jsonb(result));
  return result;
end;
$$;

create or replace function public.restore_organization_unit_policy(p_unit_id uuid)
returns public.organizational_units
language plpgsql security definer set search_path = public
as $$
declare before_row public.organizational_units%rowtype; result public.organizational_units%rowtype; slot_row public.organization_account_slots%rowtype;
begin
  if not public.is_internal_admin() then raise exception using errcode = '42501', message = 'Only internal administrators can manage organization units'; end if;
  select * into before_row from public.organizational_units where id = p_unit_id for update;
  if before_row.id is null then raise exception using errcode = 'P0002', message = 'Organization unit not found'; end if;
  if before_row.active then return before_row; end if;
  if before_row.parent_id is not null and not exists (select 1 from public.organizational_units where id = before_row.parent_id and active and not requires_representative) then raise exception using errcode = '22023', message = 'Restore the active container parent before restoring this organization'; end if;
  update public.organizational_units set active = true where id = p_unit_id returning * into result;
  if result.requires_representative then
    select * into slot_row from public.organization_account_slots where unit_id = result.id order by created_at limit 1 for update;
    if slot_row.id is null then insert into public.organization_account_slots(unit_id, label, active) values (result.id, 'Authorized representative', true); else update public.organization_account_slots set active = true where id = slot_row.id; end if;
  end if;
  insert into public.account_admin_events(actor_id, target_id, target_email, action, reason, before_values, after_values) values (auth.uid(), null, result.name::text, 'restore_organization_unit_policy', null, to_jsonb(before_row), to_jsonb(result));
  return result;
end;
$$;

revoke all on function public.organization_representative_slot_preflight(uuid, uuid) from public, anon, authenticated;
revoke all on function public.provision_organization_representative_profile_v2(uuid, uuid, text, text, uuid) from public, anon, authenticated;
revoke all on function public.provision_organization_representative_profile(uuid, uuid, text, uuid) from public, anon, authenticated;
revoke all on function public.record_organization_representative_password_reset(uuid, uuid) from public, anon, authenticated;
grant execute on function public.organization_representative_slot_preflight(uuid, uuid) to service_role;
grant execute on function public.provision_organization_representative_profile_v2(uuid, uuid, text, text, uuid) to service_role;
grant execute on function public.provision_organization_representative_profile(uuid, uuid, text, uuid) to service_role;
grant execute on function public.record_organization_representative_password_reset(uuid, uuid) to service_role;
revoke all on function public.restore_organization_unit_policy(uuid) from public, anon;
grant execute on function public.restore_organization_unit_policy(uuid) to authenticated;

notify pgrst, 'reload schema';
