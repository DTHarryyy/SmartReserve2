-- Organization-only prototype account policy.
-- Public signup is disabled in Supabase config; this migration makes the
-- database enforce named organization representatives and blocks legacy
-- personal campus accounts from booking.

alter table public.profiles
  add column if not exists account_access_type text not null default 'legacy_unassigned',
  add column if not exists must_change_password boolean not null default false,
  add column if not exists password_issued_at timestamptz;

alter table public.profiles
  drop constraint if exists profiles_account_access_type_check,
  add constraint profiles_account_access_type_check check (
    account_access_type in (
      'administrator',
      'organization_representative',
      'external_guest',
      'legacy_unassigned'
    )
  );

alter table public.organizational_units
  add column if not exists requires_representative boolean not null default true,
  add column if not exists booking_audience text;

update public.organizational_units u
set requires_representative = exists (
      select 1
      from public.organization_account_slots s
      where s.unit_id = u.id and s.active
    ),
    booking_audience = case
      when exists (
        select 1
        from public.organization_account_slots s
        where s.unit_id = u.id and s.active
      ) then coalesce(
        (
          select p.campus_claim
          from public.organization_account_slots s
          join public.profiles p on p.organization_slot_id = s.id
          where s.unit_id = u.id
            and s.active
            and p.account_status = 'active'
            and p.campus_claim in ('student', 'faculty', 'staff')
          limit 1
        ),
        'student'
      )
      else null
    end
where u.booking_audience is null
   or u.requires_representative is distinct from exists (
      select 1
      from public.organization_account_slots s
      where s.unit_id = u.id and s.active
    );

alter table public.organizational_units
  drop constraint if exists organizational_units_booking_audience_check,
  add constraint organizational_units_booking_audience_check check (
    booking_audience in ('student', 'faculty', 'staff')
  );

alter table public.organizational_units
  drop constraint if exists organizational_units_representative_policy_check,
  add constraint organizational_units_representative_policy_check check (
    (requires_representative and booking_audience is not null)
    or (not requires_representative and booking_audience is null)
  );

do $$
begin
  if exists (
    select 1
    from public.organization_account_slots
    where active
    group by unit_id
    having count(*) > 1
  ) then
    raise exception using
      errcode = '23505',
      message = 'Cannot enable organization-only policy: at least one organization already has multiple active account slots.';
  end if;
end;
$$;

create unique index if not exists organization_one_active_slot_per_unit
  on public.organization_account_slots(unit_id)
  where active;

update public.profiles
set account_access_type = case
      when role in ('internal_admin', 'external_admin') then 'administrator'
      when organization_slot_id is not null
        and exists (
          select 1
          from public.organization_account_slots s
          join public.organizational_units u on u.id = s.unit_id
          where s.id = profiles.organization_slot_id
            and s.active
            and u.active
            and u.requires_representative
        ) then 'organization_representative'
      when campus_claim = 'none' and onboarding_complete then 'external_guest'
      else 'legacy_unassigned'
    end,
    must_change_password = false
where true;

update public.profiles p
set campus_claim = u.booking_audience,
    verification_status = 'verified',
    role = 'user',
    unit = coalesce(nullif(u.code, ''), u.name::text),
    onboarding_complete = true
from public.organization_account_slots s
join public.organizational_units u on u.id = s.unit_id
where p.organization_slot_id = s.id
  and p.account_access_type = 'organization_representative';

update public.profiles
set organization_slot_id = null
where account_access_type in ('administrator', 'external_guest', 'legacy_unassigned')
  and organization_slot_id is not null;

create or replace function public.enforce_organization_slot_policy()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  unit_row public.organizational_units%rowtype;
begin
  if not new.active then
    return new;
  end if;

  select * into unit_row
  from public.organizational_units
  where id = new.unit_id;

  if unit_row.id is null or not unit_row.active then
    raise exception using errcode = '22023',
      message = 'Organization unit is not active';
  end if;

  if not unit_row.requires_representative then
    raise exception using errcode = '22023',
      message = 'Hierarchy container organizations cannot have representative account slots';
  end if;

  if exists (
    select 1
    from public.organization_account_slots s
    where s.unit_id = new.unit_id
      and s.active
      and s.id <> new.id
  ) then
    raise exception using errcode = '23505',
      message = 'This organization already has an active representative slot';
  end if;

  new.label := coalesce(nullif(trim(new.label), ''), 'Authorized representative');
  return new;
end;
$$;

drop trigger if exists organization_account_slots_policy on public.organization_account_slots;
create trigger organization_account_slots_policy
before insert or update of unit_id, label, active on public.organization_account_slots
for each row execute procedure public.enforce_organization_slot_policy();

create or replace function public.enforce_profile_access_policy()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.role in ('internal_admin', 'external_admin') then
    if new.organization_slot_id is not null then
      raise exception using errcode = '22023',
        message = 'Administrator accounts cannot be assigned to organization representative slots';
    end if;
    if new.account_access_type <> 'administrator' then
      new.account_access_type := 'administrator';
    end if;
    return new;
  end if;

  if new.account_access_type = 'administrator' then
    raise exception using errcode = '22023',
      message = 'Only administrator roles can use administrator access';
  end if;

  if new.account_access_type = 'organization_representative' then
    if new.role <> 'user' then
      raise exception using errcode = '22023',
        message = 'Organization representatives must use the user role';
    end if;
    if new.account_status <> 'active' then
      raise exception using errcode = '22023',
        message = 'Organization representatives must be active accounts';
    end if;
    if new.organization_slot_id is null or not exists (
      select 1
      from public.organization_account_slots s
      join public.organizational_units u on u.id = s.unit_id
      where s.id = new.organization_slot_id
        and s.active
        and u.active
        and u.requires_representative
    ) then
      raise exception using errcode = '22023',
        message = 'Organization representatives require one active organization slot';
    end if;
  elsif new.organization_slot_id is not null then
    raise exception using errcode = '22023',
      message = 'Only organization representatives can hold organization slots';
  end if;

  return new;
end;
$$;

drop trigger if exists profiles_access_policy on public.profiles;
create trigger profiles_access_policy
before insert or update of role, account_status, account_access_type, organization_slot_id on public.profiles
for each row execute procedure public.enforce_profile_access_policy();

create or replace function public.requester_pricing_audience(p_user_id uuid default auth.uid())
returns text
language sql
stable
security definer
set search_path = public
as $$
  select case
    when p.account_access_type = 'organization_representative'
      and p.verification_status = 'verified'
      and p.campus_claim in ('student','faculty','staff') then p.campus_claim
    else 'guest'
  end
  from public.profiles p
  where p.id = p_user_id;
$$;

create or replace function public.requester_admin_lane(p_user_id uuid default auth.uid())
returns text
language sql
stable
security definer
set search_path = public
as $$
  select case
    when p.account_access_type = 'organization_representative'
      and p.verification_status = 'verified'
      and p.campus_claim in ('student', 'faculty', 'staff') then 'internal'
    else 'external'
  end
  from public.profiles p
  where p.id = p_user_id;
$$;

create or replace function public.campus_representative_can_reserve(p_user_id uuid default auth.uid())
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.profiles p
    join public.organization_account_slots s on s.id = p.organization_slot_id
    join public.organizational_units u on u.id = s.unit_id
    where p.id = p_user_id
      and p.account_access_type = 'organization_representative'
      and not p.must_change_password
      and p.account_status = 'active'
      and p.role = 'user'
      and p.verification_status = 'verified'
      and p.campus_claim in ('student', 'faculty', 'staff')
      and s.active
      and u.active
      and u.requires_representative
  );
$$;

create or replace function public.require_reservation_account_access(p_user_id uuid default auth.uid())
returns void
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  profile_row public.profiles%rowtype;
begin
  select * into profile_row
  from public.profiles
  where id = p_user_id;

  if profile_row.id is null then
    raise exception using errcode = '42501', message = 'Sign in required';
  end if;

  if profile_row.role <> 'user' or profile_row.account_status <> 'active' then
    raise exception using errcode = '42501',
      message = 'This account cannot submit reservations';
  end if;

  if profile_row.account_access_type = 'external_guest' then
    return;
  end if;

  if profile_row.account_access_type = 'organization_representative' then
    if profile_row.must_change_password then
      raise exception using errcode = '42501',
        message = 'Change your temporary password before submitting reservations';
    end if;
    if public.campus_representative_can_reserve(p_user_id) then
      return;
    end if;
    raise exception using errcode = '42501',
      message = 'This organization representative account is not assigned to an active organization slot.';
  end if;

  raise exception using errcode = '42501',
    message = 'This account is not assigned to an authorized organization account. Contact an Internal Admin.';
end;
$$;

create or replace function public.require_campus_representative_slot(p_user_id uuid default auth.uid())
returns void
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  perform public.require_reservation_account_access(p_user_id);
end;
$$;

create or replace function public.enforce_reservation_requester_slot()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.require_reservation_account_access(new.requester_id);
  return new;
end;
$$;

drop trigger if exists reservation_requests_representative_slot on public.reservation_requests;
create trigger reservation_requests_representative_slot
before insert on public.reservation_requests
for each row execute procedure public.enforce_reservation_requester_slot();

create or replace function public.my_facility_access()
returns table (
  facility_id uuid,
  can_manage boolean,
  supports_internal boolean,
  supports_external boolean,
  bookable boolean,
  booking_unavailability_code text
)
language sql
stable
security definer
set search_path = public
as $$
  select
    f.id,
    public.can_manage_facility(f.id),
    f.facility_classification in ('internal', 'shared'),
    f.facility_classification in ('external', 'shared'),
    case
      when public.admin_lane() is not null then false
      when not exists (
        select 1 from public.profiles p
        where p.id = auth.uid()
          and p.role = 'user'
          and p.account_status = 'active'
          and (
            p.account_access_type = 'external_guest'
            or (
              p.account_access_type = 'organization_representative'
              and not p.must_change_password
              and public.campus_representative_can_reserve(p.id)
            )
          )
      ) then false
      when f.archived_at is not null or not f.public_listing or f.status <> 'active' then false
      when f.facility_classification not in ('shared', public.requester_admin_lane()) then false
      when not public.has_active_admin_in_lane(public.requester_admin_lane()) then false
      else true
    end,
    case
      when public.admin_lane() is not null then null
      when not exists (
        select 1 from public.profiles p
        where p.id = auth.uid()
          and p.role = 'user'
          and p.account_status = 'active'
          and (
            p.account_access_type = 'external_guest'
            or (
              p.account_access_type = 'organization_representative'
              and not p.must_change_password
              and public.campus_representative_can_reserve(p.id)
            )
          )
      ) then 'organization_assignment_required'
      when f.archived_at is not null or not f.public_listing or f.status <> 'active' then 'facility_inactive'
      when f.facility_classification not in ('shared', public.requester_admin_lane()) then 'facility_not_available_for_account_type'
      when not public.has_active_admin_in_lane(public.requester_admin_lane()) then
        case public.requester_admin_lane()
          when 'internal' then 'no_active_internal_admin'
          else 'no_active_external_admin'
        end
      else null
    end
  from public.facilities f
  where f.archived_at is null;
$$;

create or replace function public.complete_guest_onboarding()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  profile_row public.profiles%rowtype;
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;

  select * into profile_row
  from public.profiles
  where id = auth.uid()
  for update;

  if profile_row.id is null then
    raise exception using errcode = '42501', message = 'Profile not found';
  end if;

  if profile_row.account_access_type <> 'external_guest' then
    raise exception using errcode = '42501',
      message = 'This account cannot be converted to a guest account. Contact an Internal Admin for organization assignment.';
  end if;

  update public.profiles
  set campus_claim = 'none',
      role = 'user',
      verification_status = 'none',
      organization_slot_id = null,
      onboarding_complete = true
  where id = auth.uid();
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
language plpgsql
security definer
set search_path = public
as $$
declare
  result public.organizational_units%rowtype;
  slot_row public.organization_account_slots%rowtype;
begin
  if not public.is_internal_admin() then
    raise exception using errcode = '42501', message = 'Only internal administrators can manage organization units';
  end if;
  if length(trim(coalesce(p_name, ''))) < 2 then
    raise exception using errcode = '22023', message = 'Organization name is required';
  end if;
  if p_unit_type not in ('college', 'department', 'office', 'student_organization', 'dean_office') then
    raise exception using errcode = '22023', message = 'Invalid organization unit type';
  end if;
  if p_parent_id is not null and not exists (
    select 1 from public.organizational_units where id = p_parent_id and active
  ) then
    raise exception using errcode = '22023', message = 'Parent organization is not active';
  end if;
  if coalesce(p_requires_representative, true) and p_booking_audience not in ('student', 'faculty', 'staff') then
    raise exception using errcode = '22023', message = 'Choose Student, Faculty, or University Staff for this organization account';
  end if;
  if not coalesce(p_requires_representative, true) and p_booking_audience is not null then
    raise exception using errcode = '22023', message = 'Container organizations cannot have a booking audience';
  end if;

  insert into public.organizational_units(
    parent_id, name, code, unit_type, requires_representative,
    booking_audience, created_by
  )
  values (
    p_parent_id,
    trim(p_name),
    nullif(trim(coalesce(p_code, '')), ''),
    p_unit_type,
    coalesce(p_requires_representative, true),
    case when coalesce(p_requires_representative, true) then p_booking_audience else null end,
    auth.uid()
  )
  returning * into result;

  insert into public.account_admin_events(actor_id, target_id, target_email, action, reason, before_values, after_values)
  values (auth.uid(), null, result.name::text, 'create_organization_unit', null, '{}'::jsonb, to_jsonb(result));

  if result.requires_representative then
    insert into public.organization_account_slots(unit_id, label)
    values (result.id, 'Authorized representative')
    returning * into slot_row;

    insert into public.account_admin_events(actor_id, target_id, target_email, action, reason, before_values, after_values)
    values (auth.uid(), null, slot_row.id::text, 'create_organization_account_slot', null, '{}'::jsonb, to_jsonb(slot_row));
  end if;

  return result;
end;
$$;

create or replace function public.update_organization_unit_policy(
  p_unit_id uuid,
  p_name text,
  p_code text default null,
  p_parent_id uuid default null,
  p_unit_type text default 'student_organization',
  p_booking_audience text default null
) returns public.organizational_units
language plpgsql
security definer
set search_path = public
as $$
declare
  before_row public.organizational_units%rowtype;
  result public.organizational_units%rowtype;
begin
  if not public.is_internal_admin() then
    raise exception using errcode = '42501', message = 'Only internal administrators can manage organization units';
  end if;

  select * into before_row
  from public.organizational_units
  where id = p_unit_id
  for update;

  if before_row.id is null then
    raise exception using errcode = 'P0002', message = 'Organization unit not found';
  end if;
  if p_parent_id = p_unit_id then
    raise exception using errcode = '22023', message = 'An organization cannot be its own parent';
  end if;
  if before_row.requires_representative and p_booking_audience not in ('student', 'faculty', 'staff') then
    raise exception using errcode = '22023', message = 'Choose Student, Faculty, or University Staff for this organization account';
  end if;
  if not before_row.requires_representative and p_booking_audience is not null then
    raise exception using errcode = '22023', message = 'Container organizations cannot have a booking audience';
  end if;
  if p_parent_id is not null and not exists (
    select 1 from public.organizational_units where id = p_parent_id and active
  ) then
    raise exception using errcode = '22023', message = 'Parent organization is not active';
  end if;

  update public.organizational_units
  set parent_id = p_parent_id,
      name = trim(p_name),
      code = nullif(trim(coalesce(p_code, '')), ''),
      unit_type = p_unit_type,
      booking_audience = case when before_row.requires_representative then p_booking_audience else null end
  where id = p_unit_id
  returning * into result;

  update public.profiles p
  set campus_claim = result.booking_audience,
      unit = coalesce(nullif(result.code, ''), result.name::text)
  from public.organization_account_slots s
  where p.organization_slot_id = s.id
    and s.unit_id = result.id
    and p.account_access_type = 'organization_representative';

  insert into public.account_admin_events(actor_id, target_id, target_email, action, reason, before_values, after_values)
  values (auth.uid(), null, result.name::text, 'update_organization_unit_policy', null, to_jsonb(before_row), to_jsonb(result));

  return result;
end;
$$;

create or replace function public.archive_organization_unit_policy(p_unit_id uuid)
returns public.organizational_units
language plpgsql
security definer
set search_path = public
as $$
declare
  before_row public.organizational_units%rowtype;
  result public.organizational_units%rowtype;
begin
  if not public.is_internal_admin() then
    raise exception using errcode = '42501', message = 'Only internal administrators can manage organization units';
  end if;

  select * into before_row
  from public.organizational_units
  where id = p_unit_id
  for update;

  if before_row.id is null then
    raise exception using errcode = 'P0002', message = 'Organization unit not found';
  end if;

  if exists (
    select 1
    from public.organization_account_slots s
    join public.profiles p on p.organization_slot_id = s.id
    where s.unit_id = p_unit_id
      and s.active
      and p.account_status = 'active'
  ) then
    raise exception using errcode = '23503',
      message = 'Transfer or remove the representative before archiving this organization';
  end if;

  update public.organizational_units
  set active = false
  where id = p_unit_id
  returning * into result;

  update public.organization_account_slots
  set active = false
  where unit_id = p_unit_id;

  insert into public.account_admin_events(actor_id, target_id, target_email, action, reason, before_values, after_values)
  values (auth.uid(), null, result.name::text, 'archive_organization_unit_policy', null, to_jsonb(before_row), to_jsonb(result));

  return result;
end;
$$;

create or replace function public.assign_existing_organization_representative(
  p_profile_id uuid,
  p_slot_id uuid
) returns public.profiles
language plpgsql
security definer
set search_path = public
as $$
declare
  slot_row public.organization_account_slots%rowtype;
  unit_row public.organizational_units%rowtype;
  target_row public.profiles%rowtype;
  before_row public.profiles%rowtype;
  result public.profiles%rowtype;
begin
  if not public.is_internal_admin() then
    raise exception using errcode = '42501', message = 'Only internal administrators can assign organization representatives';
  end if;

  select * into slot_row from public.organization_account_slots where id = p_slot_id for update;
  if slot_row.id is null or not slot_row.active then
    raise exception using errcode = '22023', message = 'Organization account slot is not active';
  end if;

  select * into unit_row from public.organizational_units where id = slot_row.unit_id for update;
  if unit_row.id is null or not unit_row.active or not unit_row.requires_representative then
    raise exception using errcode = '22023', message = 'Organization unit is not available for representative accounts';
  end if;

  select * into target_row from public.profiles where id = p_profile_id for update;
  if target_row.id is null then
    raise exception using errcode = 'P0002', message = 'Account not found';
  end if;
  if target_row.role <> 'user' then
    raise exception using errcode = '22023', message = 'Only user accounts can be organization representatives';
  end if;
  if target_row.account_status <> 'active' then
    raise exception using errcode = '22023', message = 'Only active accounts can be assigned';
  end if;
  if target_row.account_access_type not in ('legacy_unassigned', 'organization_representative') then
    raise exception using errcode = '22023', message = 'Only unassigned campus accounts or existing representatives can be assigned';
  end if;
  if target_row.organization_slot_id is not null and target_row.organization_slot_id <> p_slot_id then
    raise exception using errcode = '23505', message = 'This representative already has an organization account slot';
  end if;
  if exists (
    select 1
    from public.profiles p
    where p.organization_slot_id = p_slot_id
      and p.account_status = 'active'
      and p.id <> p_profile_id
  ) then
    raise exception using errcode = '23505', message = 'This organization account slot is already assigned';
  end if;

  before_row := target_row;
  update public.profiles
  set account_access_type = 'organization_representative',
      organization_slot_id = p_slot_id,
      campus_claim = unit_row.booking_audience,
      verification_status = 'verified',
      role = 'user',
      unit = coalesce(nullif(unit_row.code, ''), unit_row.name::text),
      onboarding_complete = true,
      must_change_password = false,
      password_issued_at = null
  where id = p_profile_id
  returning * into result;

  insert into public.account_admin_events(actor_id, target_id, target_email, action, reason, before_values, after_values)
  values (auth.uid(), result.id, result.email, 'assign_existing_organization_representative', null, to_jsonb(before_row), to_jsonb(result));

  return result;
end;
$$;

create or replace function public.assign_organization_representative(
  p_profile_id uuid,
  p_slot_id uuid
) returns public.profiles
language plpgsql
security definer
set search_path = public
as $$
begin
  return public.assign_existing_organization_representative(p_profile_id, p_slot_id);
end;
$$;

create or replace function public.provision_organization_representative_profile(
  p_actor uuid,
  p_profile_id uuid,
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
  target_row public.profiles%rowtype;
  result public.profiles%rowtype;
begin
  if not public.is_internal_admin(p_actor) then
    raise exception using errcode = '42501', message = 'Only internal administrators can provision organization representatives';
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
    select 1
    from public.profiles p
    where p.organization_slot_id = p_slot_id
      and p.account_status = 'active'
      and p.id <> p_profile_id
  ) then
    raise exception using errcode = '23505', message = 'This organization account slot is already assigned';
  end if;

  select * into target_row from public.profiles where id = p_profile_id for update;
  if target_row.id is null then
    raise exception using errcode = 'P0002', message = 'Account not found';
  end if;

  update public.profiles
  set full_name = trim(p_full_name),
      role = 'user',
      account_status = 'active',
      account_access_type = 'organization_representative',
      must_change_password = true,
      password_issued_at = now(),
      invitation_sent_at = null,
      organization_slot_id = p_slot_id,
      campus_claim = unit_row.booking_audience,
      campus_id = null,
      verification_status = 'verified',
      onboarding_complete = true,
      unit = coalesce(nullif(unit_row.code, ''), unit_row.name::text)
  where id = p_profile_id
  returning * into result;

  insert into public.account_admin_events(actor_id, target_id, target_email, action, reason, before_values, after_values)
  values (p_actor, result.id, result.email, 'create_organization_representative', null, to_jsonb(target_row), to_jsonb(result));

  return result;
end;
$$;

create or replace function public.remove_organization_representative(p_profile_id uuid)
returns public.profiles
language plpgsql
security definer
set search_path = public
as $$
declare
  before_row public.profiles%rowtype;
  result public.profiles%rowtype;
begin
  if not public.is_internal_admin() then
    raise exception using errcode = '42501', message = 'Only internal administrators can remove organization representatives';
  end if;

  select * into before_row from public.profiles where id = p_profile_id for update;
  if before_row.id is null then
    raise exception using errcode = 'P0002', message = 'Account not found';
  end if;
  if before_row.account_access_type <> 'organization_representative' then
    raise exception using errcode = '22023', message = 'Only organization representatives can be removed from slots';
  end if;

  update public.profiles
  set organization_slot_id = null,
      account_access_type = 'legacy_unassigned',
      campus_claim = null,
      campus_id = null,
      verification_status = 'none',
      unit = '',
      must_change_password = false,
      password_issued_at = null
  where id = p_profile_id
  returning * into result;

  insert into public.account_admin_events(actor_id, target_id, target_email, action, reason, before_values, after_values)
  values (auth.uid(), result.id, result.email, 'remove_organization_representative', null, to_jsonb(before_row), to_jsonb(result));

  return result;
end;
$$;

create or replace function public.transfer_organization_representative(
  p_current_profile_id uuid,
  p_replacement_profile_id uuid,
  p_slot_id uuid
) returns public.profiles
language plpgsql
security definer
set search_path = public
as $$
declare
  slot_row public.organization_account_slots%rowtype;
  unit_row public.organizational_units%rowtype;
  current_before public.profiles%rowtype;
  replacement_before public.profiles%rowtype;
  replacement_after public.profiles%rowtype;
begin
  if not public.is_internal_admin() then
    raise exception using errcode = '42501', message = 'Only internal administrators can transfer organization representatives';
  end if;

  select * into slot_row from public.organization_account_slots where id = p_slot_id for update;
  if slot_row.id is null or not slot_row.active then
    raise exception using errcode = '22023', message = 'Organization account slot is not active';
  end if;

  select * into unit_row from public.organizational_units where id = slot_row.unit_id for update;
  if unit_row.id is null or not unit_row.active or not unit_row.requires_representative then
    raise exception using errcode = '22023', message = 'Organization unit is not available for representative accounts';
  end if;

  select * into current_before from public.profiles where id = p_current_profile_id for update;
  select * into replacement_before from public.profiles where id = p_replacement_profile_id for update;

  if current_before.organization_slot_id <> p_slot_id then
    raise exception using errcode = '22023', message = 'Current representative does not hold this organization slot';
  end if;
  if replacement_before.id is null or replacement_before.role <> 'user' or replacement_before.account_status <> 'active' then
    raise exception using errcode = '22023', message = 'Replacement must be an active user account';
  end if;
  if replacement_before.organization_slot_id is not null then
    raise exception using errcode = '23505', message = 'Replacement already has an organization slot';
  end if;
  if replacement_before.account_access_type not in ('legacy_unassigned', 'organization_representative') then
    raise exception using errcode = '22023', message = 'Replacement must be an unassigned campus account or representative';
  end if;

  update public.profiles
  set organization_slot_id = null,
      account_access_type = 'legacy_unassigned',
      campus_claim = null,
      verification_status = 'none',
      unit = '',
      must_change_password = false,
      password_issued_at = null
  where id = p_current_profile_id;

  update public.profiles
  set account_access_type = 'organization_representative',
      organization_slot_id = p_slot_id,
      campus_claim = unit_row.booking_audience,
      verification_status = 'verified',
      role = 'user',
      unit = coalesce(nullif(unit_row.code, ''), unit_row.name::text),
      onboarding_complete = true,
      must_change_password = false,
      password_issued_at = null
  where id = p_replacement_profile_id
  returning * into replacement_after;

  insert into public.account_admin_events(actor_id, target_id, target_email, action, reason, before_values, after_values)
  values (auth.uid(), current_before.id, current_before.email, 'transfer_organization_representative_from', null, to_jsonb(current_before), jsonb_build_object('account_access_type', 'legacy_unassigned'));

  insert into public.account_admin_events(actor_id, target_id, target_email, action, reason, before_values, after_values)
  values (auth.uid(), replacement_after.id, replacement_after.email, 'transfer_organization_representative_to', null, to_jsonb(replacement_before), to_jsonb(replacement_after));

  return replacement_after;
end;
$$;

create or replace function public.convert_legacy_account_to_external_guest(
  p_profile_id uuid,
  p_reason text
) returns public.profiles
language plpgsql
security definer
set search_path = public
as $$
declare
  before_row public.profiles%rowtype;
  result public.profiles%rowtype;
  reason_value text := nullif(trim(coalesce(p_reason, '')), '');
begin
  if not public.is_internal_admin() then
    raise exception using errcode = '42501', message = 'Only internal administrators can convert legacy accounts';
  end if;
  if reason_value is null then
    raise exception using errcode = '22023', message = 'A conversion reason is required';
  end if;

  select * into before_row
  from public.profiles
  where id = p_profile_id
  for update;

  if before_row.id is null then
    raise exception using errcode = 'P0002', message = 'Account not found';
  end if;
  if before_row.role <> 'user' then
    raise exception using errcode = '22023', message = 'Only user accounts can be converted to external guest access';
  end if;
  if before_row.account_access_type <> 'legacy_unassigned' then
    raise exception using errcode = '22023', message = 'Only legacy unassigned accounts can be converted to external guests';
  end if;

  update public.profiles
  set account_access_type = 'external_guest',
      organization_slot_id = null,
      campus_claim = 'none',
      campus_id = null,
      unit = '',
      verification_status = 'none',
      onboarding_complete = true,
      must_change_password = false,
      password_issued_at = null
  where id = p_profile_id
  returning * into result;

  insert into public.account_admin_events(actor_id, target_id, target_email, action, reason, before_values, after_values)
  values (auth.uid(), result.id, result.email, 'convert_legacy_account_to_external_guest', reason_value, to_jsonb(before_row), to_jsonb(result));

  return result;
end;
$$;

create or replace function public.record_organization_representative_password_reset(
  p_actor uuid,
  p_profile_id uuid
) returns public.profiles
language plpgsql
security definer
set search_path = public
as $$
declare
  before_row public.profiles%rowtype;
  result public.profiles%rowtype;
begin
  if not public.is_internal_admin(p_actor) then
    raise exception using errcode = '42501', message = 'Only internal administrators can reset organization representative passwords';
  end if;

  select * into before_row
  from public.profiles
  where id = p_profile_id
  for update;

  if before_row.id is null then
    raise exception using errcode = 'P0002', message = 'Account not found';
  end if;
  if before_row.account_access_type <> 'organization_representative'
     or before_row.account_status <> 'active' then
    raise exception using errcode = '22023', message = 'Target must be an active organization representative';
  end if;

  update public.profiles
  set must_change_password = true,
      password_issued_at = now()
  where id = p_profile_id
  returning * into result;

  insert into public.account_admin_events(actor_id, target_id, target_email, action, reason, before_values, after_values)
  values (p_actor, result.id, result.email, 'reset_organization_representative_password', null, to_jsonb(before_row), to_jsonb(result));

  return result;
end;
$$;

create or replace function public.complete_initial_password_change()
returns public.profiles
language plpgsql
security definer
set search_path = public
as $$
declare
  before_row public.profiles%rowtype;
  result public.profiles%rowtype;
begin
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'Sign in required';
  end if;

  select * into before_row
  from public.profiles
  where id = auth.uid()
  for update;

  if before_row.id is null then
    raise exception using errcode = 'P0002', message = 'Profile not found';
  end if;
  if not before_row.must_change_password then
    raise exception using errcode = '22023', message = 'This account does not require a temporary password change';
  end if;

  update public.profiles
  set must_change_password = false,
      password_issued_at = null
  where id = auth.uid()
  returning * into result;

  insert into public.account_admin_events(actor_id, target_id, target_email, action, reason, before_values, after_values)
  values (auth.uid(), result.id, result.email, 'complete_initial_password_change', null, to_jsonb(before_row), to_jsonb(result));

  return result;
end;
$$;

create or replace function public.get_external_clients()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare result_value jsonb;
begin
  if public.admin_lane() is distinct from 'external' then
    raise exception using errcode = '42501',
      message = 'External administrator access required';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', client.id,
    'email', client.email,
    'full_name', coalesce(nullif(client.full_name, ''), client.email),
    'role', 'user',
    'account_access_type', client.account_access_type,
    'must_change_password', client.must_change_password,
    'account_status', client.account_status,
    'created_at', client.created_at,
    'reservation_count', client.reservation_count,
    'last_reservation_at', client.last_reservation_at,
    'payment_count', client.payment_count,
    'last_payment_at', client.last_payment_at
  ) order by client.last_activity_at desc, client.created_at desc), '[]'::jsonb)
  into result_value
  from (
    select
      p.id,
      p.email,
      p.full_name,
      p.account_status,
      p.account_access_type,
      p.must_change_password,
      p.created_at,
      coalesce(reservations.reservation_count, 0)::integer
        as reservation_count,
      reservations.last_reservation_at,
      coalesce(payments.payment_count, 0)::integer as payment_count,
      payments.last_payment_at,
      greatest(
        coalesce(reservations.last_reservation_at, '-infinity'::timestamptz),
        coalesce(payments.last_payment_at, '-infinity'::timestamptz)
      ) as last_activity_at
    from public.profiles p
    left join lateral (
      select count(*)::integer as reservation_count,
        max(r.created_at) as last_reservation_at
      from public.reservation_requests r
      where r.requester_id = p.id
    ) reservations on true
    left join lateral (
      select count(*)::integer as payment_count,
        max(t.submitted_at) as last_payment_at
      from public.payment_transactions t
      where t.payer_id = p.id
    ) payments on true
    where p.role = 'user'
      and p.account_status = 'active'
      and p.account_access_type = 'external_guest'
      and (
        coalesce(reservations.reservation_count, 0) > 0
        or coalesce(payments.payment_count, 0) > 0
      )
  ) client;

  return result_value;
end;
$$;

revoke all on function public.create_organizational_unit(text, text, uuid, text) from public, anon, authenticated;
revoke all on function public.update_organizational_unit(uuid, text, text, uuid, text, boolean) from public, anon, authenticated;
revoke all on function public.archive_organizational_unit(uuid) from public, anon, authenticated;
revoke all on function public.create_organization_account_slot(uuid, text) from public, anon, authenticated;
revoke all on function public.update_organization_account_slot(uuid, text, boolean) from public, anon, authenticated;
revoke all on function public.archive_organization_account_slot(uuid) from public, anon, authenticated;

revoke all on function public.require_reservation_account_access(uuid) from public, anon;
revoke all on function public.create_organization_unit(text, text, uuid, text, boolean, text) from public, anon;
revoke all on function public.update_organization_unit_policy(uuid, text, text, uuid, text, text) from public, anon;
revoke all on function public.archive_organization_unit_policy(uuid) from public, anon;
revoke all on function public.assign_existing_organization_representative(uuid, uuid) from public, anon;
revoke all on function public.transfer_organization_representative(uuid, uuid, uuid) from public, anon;
revoke all on function public.convert_legacy_account_to_external_guest(uuid, text) from public, anon;
revoke all on function public.complete_initial_password_change() from public, anon;
revoke all on function public.record_organization_representative_password_reset(uuid, uuid) from public, anon, authenticated;
revoke all on function public.provision_organization_representative_profile(uuid, uuid, text, uuid) from public, anon, authenticated;
revoke all on function public.enforce_organization_slot_policy() from public, anon, authenticated;
revoke all on function public.enforce_profile_access_policy() from public, anon, authenticated;
revoke all on function public.enforce_reservation_requester_slot() from public, anon, authenticated;

grant execute on function public.require_reservation_account_access(uuid) to authenticated;
grant execute on function public.create_organization_unit(text, text, uuid, text, boolean, text) to authenticated;
grant execute on function public.update_organization_unit_policy(uuid, text, text, uuid, text, text) to authenticated;
grant execute on function public.archive_organization_unit_policy(uuid) to authenticated;
grant execute on function public.assign_existing_organization_representative(uuid, uuid) to authenticated;
grant execute on function public.transfer_organization_representative(uuid, uuid, uuid) to authenticated;
grant execute on function public.convert_legacy_account_to_external_guest(uuid, text) to authenticated;
grant execute on function public.complete_initial_password_change() to authenticated;

revoke all on function public.my_facility_access() from public, anon;
grant execute on function public.my_facility_access() to authenticated;
revoke all on function public.get_external_clients() from public, anon;
grant execute on function public.get_external_clients() to authenticated;
revoke all on function public.complete_guest_onboarding() from public, anon;
grant execute on function public.complete_guest_onboarding() to authenticated;
revoke all on function public.campus_representative_can_reserve(uuid) from public, anon;
grant execute on function public.campus_representative_can_reserve(uuid) to authenticated;

notify pgrst, 'reload schema';
