create extension if not exists citext;

-- ---------------------------------------------------------------------
-- Organization-based campus representatives
-- ---------------------------------------------------------------------

create table if not exists public.organizational_units (
  id uuid primary key default gen_random_uuid(),
  parent_id uuid references public.organizational_units(id) on delete restrict,
  name citext not null,
  code text,
  unit_type text not null check (
    unit_type in ('college', 'department', 'office', 'student_organization', 'dean_office')
  ),
  active boolean not null default true,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index if not exists organizational_units_active_sibling_name_idx
  on public.organizational_units(coalesce(parent_id, '00000000-0000-0000-0000-000000000000'::uuid), lower(name::text))
  where active;

create table if not exists public.organization_account_slots (
  id uuid primary key default gen_random_uuid(),
  unit_id uuid not null references public.organizational_units(id) on delete restrict,
  label text not null default 'Authorized representative',
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists organization_account_slots_unit_idx
  on public.organization_account_slots(unit_id, active);

alter table public.profiles
  add column if not exists organization_slot_id uuid
    references public.organization_account_slots(id) on delete set null;

create unique index if not exists profiles_one_active_organization_slot
  on public.profiles(organization_slot_id)
  where organization_slot_id is not null
    and account_status = 'active';

drop trigger if exists organizational_units_updated_at on public.organizational_units;
create trigger organizational_units_updated_at
before update on public.organizational_units
for each row execute procedure public.set_updated_at();

drop trigger if exists organization_account_slots_updated_at on public.organization_account_slots;
create trigger organization_account_slots_updated_at
before update on public.organization_account_slots
for each row execute procedure public.set_updated_at();

alter table public.organizational_units enable row level security;
alter table public.organization_account_slots enable row level security;

revoke all on public.organizational_units from public, anon, authenticated;
revoke all on public.organization_account_slots from public, anon, authenticated;
grant select on public.organizational_units to authenticated;
grant select on public.organization_account_slots to authenticated;

drop policy if exists organizational_units_internal_admin_select on public.organizational_units;
create policy organizational_units_internal_admin_select
on public.organizational_units for select to authenticated
using (public.is_internal_admin());

drop policy if exists organizational_units_representative_select on public.organizational_units;
create policy organizational_units_representative_select
on public.organizational_units for select to authenticated
using (
  exists (
    select 1
    from public.organization_account_slots s
    join public.profiles p on p.organization_slot_id = s.id
    where s.unit_id = organizational_units.id
      and p.id = auth.uid()
  )
);

drop policy if exists organization_account_slots_internal_admin_select on public.organization_account_slots;
create policy organization_account_slots_internal_admin_select
on public.organization_account_slots for select to authenticated
using (public.is_internal_admin());

drop policy if exists organization_account_slots_representative_select on public.organization_account_slots;
create policy organization_account_slots_representative_select
on public.organization_account_slots for select to authenticated
using (
  exists (
    select 1
    from public.profiles p
    where p.organization_slot_id = organization_account_slots.id
      and p.id = auth.uid()
  )
);

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
      and p.account_status = 'active'
      and p.role = 'user'
      and p.campus_claim in ('student', 'faculty', 'staff')
      and s.active
      and u.active
  );
$$;

create or replace function public.require_campus_representative_slot(p_user_id uuid default auth.uid())
returns void
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  profile_row public.profiles%rowtype;
begin
  select * into profile_row from public.profiles where id = p_user_id;
  if profile_row.id is null then
    raise exception using errcode = '42501', message = 'Sign in required';
  end if;
  if profile_row.campus_claim in ('student', 'faculty', 'staff')
     and not public.campus_representative_can_reserve(p_user_id) then
    raise exception using errcode = '42501',
      message = 'This campus account must be assigned as an authorized organization representative before it can reserve facilities.';
  end if;
end;
$$;

create or replace function public.create_organizational_unit(
  p_name text,
  p_unit_type text,
  p_parent_id uuid default null,
  p_code text default null
) returns public.organizational_units
language plpgsql
security definer
set search_path = public
as $$
declare
  result public.organizational_units%rowtype;
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
  insert into public.organizational_units(parent_id, name, code, unit_type, created_by)
  values (p_parent_id, trim(p_name), nullif(trim(coalesce(p_code, '')), ''), p_unit_type, auth.uid())
  returning * into result;
  insert into public.account_admin_events(actor_id, target_id, target_email, action, reason, before_values, after_values)
  values (auth.uid(), null, result.name::text, 'create_organizational_unit', null, '{}'::jsonb, to_jsonb(result));
  return result;
end;
$$;

create or replace function public.update_organizational_unit(
  p_unit_id uuid,
  p_name text,
  p_unit_type text,
  p_parent_id uuid default null,
  p_code text default null,
  p_active boolean default true
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
  select * into before_row from public.organizational_units where id = p_unit_id for update;
  if before_row.id is null then
    raise exception using errcode = 'P0002', message = 'Organization unit not found';
  end if;
  if p_parent_id = p_unit_id then
    raise exception using errcode = '22023', message = 'An organization cannot be its own parent';
  end if;
  update public.organizational_units
  set parent_id = p_parent_id,
      name = trim(p_name),
      code = nullif(trim(coalesce(p_code, '')), ''),
      unit_type = p_unit_type,
      active = coalesce(p_active, true)
  where id = p_unit_id
  returning * into result;
  insert into public.account_admin_events(actor_id, target_id, target_email, action, reason, before_values, after_values)
  values (auth.uid(), null, result.name::text, 'update_organizational_unit', null, to_jsonb(before_row), to_jsonb(result));
  return result;
end;
$$;

create or replace function public.archive_organizational_unit(p_unit_id uuid)
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
  select * into before_row from public.organizational_units where id = p_unit_id for update;
  if before_row.id is null then
    raise exception using errcode = 'P0002', message = 'Organization unit not found';
  end if;
  update public.organizational_units set active = false where id = p_unit_id returning * into result;
  update public.organization_account_slots set active = false where unit_id = p_unit_id;
  insert into public.account_admin_events(actor_id, target_id, target_email, action, reason, before_values, after_values)
  values (auth.uid(), null, result.name::text, 'archive_organizational_unit', null, to_jsonb(before_row), to_jsonb(result));
  return result;
end;
$$;

create or replace function public.create_organization_account_slot(
  p_unit_id uuid,
  p_label text default 'Authorized representative'
) returns public.organization_account_slots
language plpgsql
security definer
set search_path = public
as $$
declare
  result public.organization_account_slots%rowtype;
begin
  if not public.is_internal_admin() then
    raise exception using errcode = '42501', message = 'Only internal administrators can manage organization account slots';
  end if;
  if not exists (select 1 from public.organizational_units where id = p_unit_id and active) then
    raise exception using errcode = '22023', message = 'Organization unit is not active';
  end if;
  insert into public.organization_account_slots(unit_id, label)
  values (p_unit_id, coalesce(nullif(trim(p_label), ''), 'Authorized representative'))
  returning * into result;
  insert into public.account_admin_events(actor_id, target_id, target_email, action, reason, before_values, after_values)
  values (auth.uid(), null, result.id::text, 'create_organization_account_slot', null, '{}'::jsonb, to_jsonb(result));
  return result;
end;
$$;

create or replace function public.update_organization_account_slot(
  p_slot_id uuid,
  p_label text,
  p_active boolean default true
) returns public.organization_account_slots
language plpgsql
security definer
set search_path = public
as $$
declare
  before_row public.organization_account_slots%rowtype;
  result public.organization_account_slots%rowtype;
begin
  if not public.is_internal_admin() then
    raise exception using errcode = '42501', message = 'Only internal administrators can manage organization account slots';
  end if;
  select * into before_row from public.organization_account_slots where id = p_slot_id for update;
  if before_row.id is null then
    raise exception using errcode = 'P0002', message = 'Organization account slot not found';
  end if;
  update public.organization_account_slots
  set label = coalesce(nullif(trim(p_label), ''), 'Authorized representative'),
      active = coalesce(p_active, true)
  where id = p_slot_id
  returning * into result;
  insert into public.account_admin_events(actor_id, target_id, target_email, action, reason, before_values, after_values)
  values (auth.uid(), null, result.id::text, 'update_organization_account_slot', null, to_jsonb(before_row), to_jsonb(result));
  return result;
end;
$$;

create or replace function public.archive_organization_account_slot(p_slot_id uuid)
returns public.organization_account_slots
language plpgsql
security definer
set search_path = public
as $$
declare
  before_row public.organization_account_slots%rowtype;
  result public.organization_account_slots%rowtype;
begin
  if not public.is_internal_admin() then
    raise exception using errcode = '42501', message = 'Only internal administrators can manage organization account slots';
  end if;
  select * into before_row from public.organization_account_slots where id = p_slot_id for update;
  if before_row.id is null then
    raise exception using errcode = 'P0002', message = 'Organization account slot not found';
  end if;
  update public.organization_account_slots set active = false where id = p_slot_id returning * into result;
  update public.profiles set organization_slot_id = null where organization_slot_id = p_slot_id;
  insert into public.account_admin_events(actor_id, target_id, target_email, action, reason, before_values, after_values)
  values (auth.uid(), null, result.id::text, 'archive_organization_account_slot', null, to_jsonb(before_row), to_jsonb(result));
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
  select * into unit_row from public.organizational_units where id = slot_row.unit_id for share;
  if unit_row.id is null or not unit_row.active then
    raise exception using errcode = '22023', message = 'Organization unit is not active';
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
  if exists (
    select 1 from public.profiles p
    where p.organization_slot_id = p_slot_id
      and p.account_status = 'active'
      and p.id <> p_profile_id
  ) then
    raise exception using errcode = '23505', message = 'This organization account slot is already assigned';
  end if;
  before_row := target_row;
  update public.profiles
  set organization_slot_id = p_slot_id,
      unit = coalesce(nullif(unit_row.code, ''), unit_row.name::text),
      onboarding_complete = true
  where id = p_profile_id
  returning * into result;
  insert into public.account_admin_events(actor_id, target_id, target_email, action, reason, before_values, after_values)
  values (auth.uid(), result.id, result.email, 'assign_organization_representative', null, to_jsonb(before_row), to_jsonb(result));
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
    raise exception using errcode = '42501', message = 'Only internal administrators can assign organization representatives';
  end if;
  select * into before_row from public.profiles where id = p_profile_id for update;
  if before_row.id is null then
    raise exception using errcode = 'P0002', message = 'Account not found';
  end if;
  update public.profiles set organization_slot_id = null where id = p_profile_id returning * into result;
  insert into public.account_admin_events(actor_id, target_id, target_email, action, reason, before_values, after_values)
  values (auth.uid(), result.id, result.email, 'remove_organization_representative', null, to_jsonb(before_row), to_jsonb(result));
  return result;
end;
$$;

revoke all on function public.campus_representative_can_reserve(uuid) from public, anon;
revoke all on function public.require_campus_representative_slot(uuid) from public, anon;
revoke all on function public.create_organizational_unit(text, text, uuid, text) from public, anon;
revoke all on function public.update_organizational_unit(uuid, text, text, uuid, text, boolean) from public, anon;
revoke all on function public.archive_organizational_unit(uuid) from public, anon;
revoke all on function public.create_organization_account_slot(uuid, text) from public, anon;
revoke all on function public.update_organization_account_slot(uuid, text, boolean) from public, anon;
revoke all on function public.archive_organization_account_slot(uuid) from public, anon;
revoke all on function public.assign_organization_representative(uuid, uuid) from public, anon;
revoke all on function public.remove_organization_representative(uuid) from public, anon;
grant execute on function public.campus_representative_can_reserve(uuid) to authenticated;
grant execute on function public.require_campus_representative_slot(uuid) to authenticated;
grant execute on function public.create_organizational_unit(text, text, uuid, text) to authenticated;
grant execute on function public.update_organizational_unit(uuid, text, text, uuid, text, boolean) to authenticated;
grant execute on function public.archive_organizational_unit(uuid) to authenticated;
grant execute on function public.create_organization_account_slot(uuid, text) to authenticated;
grant execute on function public.update_organization_account_slot(uuid, text, boolean) to authenticated;
grant execute on function public.archive_organization_account_slot(uuid) to authenticated;
grant execute on function public.assign_organization_representative(uuid, uuid) to authenticated;
grant execute on function public.remove_organization_representative(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- Payment correction lifecycle
-- ---------------------------------------------------------------------

alter table public.payment_transactions
  add column if not exists correction_due_at timestamptz,
  add column if not exists correction_count integer not null default 0,
  add column if not exists last_corrected_at timestamptz,
  add column if not exists refunded_at timestamptz;

alter table public.payment_transactions
  drop constraint if exists payment_transactions_status_check,
  add constraint payment_transactions_status_check
    check (status in ('submitted','needs_correction','verified','rejected','voided','refunded'));

alter table public.payment_transactions
  drop constraint if exists payment_transactions_check,
  add constraint payment_transactions_check
  check (
    (status = 'verified' and verified_by is not null and verified_at is not null and rejection_reason is null and correction_due_at is null)
    or (status = 'needs_correction' and verified_by is not null and verified_at is not null and length(trim(rejection_reason)) >= 3 and correction_due_at is not null)
    or (status = 'rejected' and verified_by is not null and verified_at is not null and length(trim(rejection_reason)) >= 3)
    or status in ('submitted','voided','refunded')
  );

drop index if exists payment_transactions_active_reference_idx;
create unique index if not exists payment_transactions_active_reference_idx
  on public.payment_transactions(lower(regexp_replace(reference_number,'\s','','g')))
  where status in ('submitted','needs_correction','verified');

drop index if exists payment_transactions_correction_idx;
create index payment_transactions_correction_idx
  on public.payment_transactions(correction_due_at)
  where status = 'needs_correction';

create or replace function public.reservation_payment_summary(p_request_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  request_row public.reservation_requests%rowtype;
  verified_value integer;
  submitted_value integer;
  correction_value integer;
  status_value text;
begin
  select * into request_row from public.reservation_requests where id = p_request_id;
  if request_row.id is null or not public.can_access_reservation(p_request_id) then
    raise exception using errcode = '42501', message = 'Reservation access denied';
  end if;
  select coalesce(sum(amount_centavos) filter(where status = 'verified' and purpose <> 'refund'), 0),
         coalesce(sum(amount_centavos) filter(where status = 'submitted'), 0),
         coalesce(sum(amount_centavos) filter(where status = 'needs_correction'), 0)
  into verified_value, submitted_value, correction_value
  from public.payment_transactions
  where request_id = p_request_id;
  status_value := case
    when request_row.total_amount_centavos = 0 then 'not_required'
    when verified_value >= request_row.total_amount_centavos then 'fully_paid'
    when correction_value > 0 then 'needs_correction'
    when verified_value >= request_row.required_down_payment_centavos then 'down_payment_verified'
    when submitted_value > 0 then 'submitted'
    when verified_value > 0 then 'partially_paid'
    else 'unpaid'
  end;
  return jsonb_build_object(
    'status', status_value,
    'total_amount_centavos', request_row.total_amount_centavos,
    'required_down_payment_centavos', request_row.required_down_payment_centavos,
    'verified_amount_centavos', verified_value,
    'submitted_amount_centavos', submitted_value,
    'correction_amount_centavos', correction_value,
    'outstanding_amount_centavos', greatest(0, request_row.total_amount_centavos - verified_value),
    'payment_due_at', request_row.payment_due_at,
    'balance_due_at', request_row.balance_due_at,
    'down_payment_percent', request_row.down_payment_percent,
    'payment_exemption', request_row.payment_exemption
  );
end;
$$;

create or replace function public.correct_payment_submission(
  p_payment_id uuid,
  p_amount_centavos integer,
  p_reference_number text,
  p_proof_path text,
  p_idempotency_key uuid
) returns public.payment_transactions
language plpgsql
security definer
set search_path = public, storage
as $$
declare
  payment_row public.payment_transactions%rowtype;
  request_row public.reservation_requests%rowtype;
  result public.payment_transactions%rowtype;
  committed_value integer;
  event_id uuid;
begin
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'Sign in required';
  end if;
  select * into result
  from public.payment_transactions
  where payer_id = auth.uid()
    and idempotency_key = p_idempotency_key;
  if result.id is not null then
    return result;
  end if;
  select * into payment_row from public.payment_transactions where id = p_payment_id for update;
  if payment_row.id is null then
    raise exception using errcode = 'P0002', message = 'Payment not found';
  end if;
  select * into request_row from public.reservation_requests where id = payment_row.request_id for update;
  if request_row.id is null or request_row.requester_id <> auth.uid() or payment_row.payer_id <> auth.uid() then
    raise exception using errcode = '42501', message = 'Reservation access denied';
  end if;
  if payment_row.status <> 'needs_correction' then
    raise exception using errcode = '22023', message = 'This payment is not awaiting correction';
  end if;
  if payment_row.correction_due_at is null or payment_row.correction_due_at < now() then
    raise exception using errcode = '22023', message = 'The payment correction window has ended';
  end if;
  if request_row.reservation_status not in ('awaiting_payment', 'confirmed') then
    raise exception using errcode = '22023', message = 'This reservation is no longer accepting payment corrections';
  end if;
  if p_amount_centavos <= 0 then
    raise exception using errcode = '22023', message = 'Provide a valid payment amount';
  end if;
  if length(trim(coalesce(p_reference_number, ''))) < 6 then
    raise exception using errcode = '22023', message = 'Provide the GCash reference number';
  end if;
  if p_proof_path not like auth.uid()::text || '/' || request_row.id::text || '/%' then
    raise exception using errcode = '42501', message = 'Invalid payment proof path';
  end if;
  select coalesce(sum(amount_centavos), 0) into committed_value
  from public.payment_transactions
  where request_id = request_row.id
    and id <> payment_row.id
    and status in ('submitted', 'needs_correction', 'verified');
  if p_amount_centavos > request_row.total_amount_centavos - committed_value then
    raise exception using errcode = '22023', message = 'Payment is greater than the outstanding balance';
  end if;
  update public.payment_transactions
  set amount_centavos = p_amount_centavos,
      reference_number = trim(p_reference_number),
      proof_path = p_proof_path,
      status = 'submitted',
      verified_by = null,
      verified_at = null,
      rejection_reason = null,
      correction_due_at = null,
      correction_count = correction_count + 1,
      last_corrected_at = now(),
      idempotency_key = p_idempotency_key
  where id = p_payment_id
  returning * into result;
  event_id := public.reservation_event(
    request_row.id,
    'corrected payment proof',
    null,
    jsonb_build_object(
      'payment_id', payment_row.id,
      'previous_amount_centavos', payment_row.amount_centavos,
      'previous_reference_number', payment_row.reference_number,
      'previous_proof_path', payment_row.proof_path,
      'amount_centavos', result.amount_centavos
    ),
    null,
    true
  );
  insert into public.app_notifications(recipient_id, request_id, event_id, kind, title, body)
  select p.id, request_row.id, event_id, 'payment_corrected',
    'Corrected payment submitted for review',
    request_row.requester_name || ' corrected GCash payment proof.'
  from public.profiles p
  where p.account_status = 'active'
    and p.role = case request_row.admin_lane when 'internal' then 'internal_admin' else 'external_admin' end
  on conflict do nothing;
  return result;
exception when unique_violation then
  raise exception using errcode = '23505', message = 'That payment reference or submission was already used';
end;
$$;

create or replace function public.submit_payment(
  p_transaction_id uuid,
  p_request_id uuid,
  p_purpose text,
  p_amount_centavos integer,
  p_reference_number text,
  p_proof_path text,
  p_idempotency_key uuid
) returns public.payment_transactions
language plpgsql
security definer
set search_path = public, storage
as $$
declare
  request_row public.reservation_requests%rowtype;
  result public.payment_transactions%rowtype;
  committed_value integer;
  event_id uuid;
begin
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'Sign in required';
  end if;
  select * into request_row from public.reservation_requests where id = p_request_id for update;
  if request_row.id is null or request_row.requester_id <> auth.uid() then
    raise exception using errcode = '42501', message = 'Reservation access denied';
  end if;
  if request_row.reservation_status not in ('awaiting_payment', 'confirmed') then
    raise exception using errcode = '22023', message = 'This reservation is not accepting payments';
  end if;
  if p_purpose not in ('down_payment', 'balance') or p_amount_centavos <= 0 then
    raise exception using errcode = '22023', message = 'Provide a valid payment amount and purpose';
  end if;
  if request_row.payment_method_id is null then
    raise exception using errcode = '22023', message = 'No payment method is configured for this reservation';
  end if;
  if length(trim(coalesce(p_reference_number, ''))) < 6 then
    raise exception using errcode = '22023', message = 'Provide the GCash reference number';
  end if;
  if p_proof_path not like auth.uid()::text || '/' || p_request_id::text || '/%' then
    raise exception using errcode = '42501', message = 'Invalid payment proof path';
  end if;
  select coalesce(sum(amount_centavos), 0) into committed_value
  from public.payment_transactions
  where request_id = p_request_id
    and status in ('submitted', 'needs_correction', 'verified');
  if p_amount_centavos > request_row.total_amount_centavos - committed_value then
    raise exception using errcode = '22023', message = 'Payment is greater than the outstanding balance';
  end if;
  insert into public.payment_transactions(
    id, request_id, payer_id, payment_method_id, purpose, amount_centavos,
    reference_number, proof_path, idempotency_key
  ) values (
    p_transaction_id, p_request_id, auth.uid(), request_row.payment_method_id,
    p_purpose, p_amount_centavos, trim(p_reference_number), p_proof_path,
    p_idempotency_key
  )
  returning * into result;
  event_id := public.reservation_event(
    p_request_id,
    'submitted payment proof',
    null,
    jsonb_build_object(
      'payment_id', result.id,
      'purpose', result.purpose,
      'amount_centavos', result.amount_centavos
    ),
    null,
    true
  );
  insert into public.app_notifications(recipient_id, request_id, event_id, kind, title, body)
  select p.id, p_request_id, event_id, 'payment_submitted',
    'Payment submitted for review',
    request_row.requester_name || ' submitted GCash payment proof.'
  from public.profiles p
  where p.account_status = 'active'
    and p.role = case request_row.admin_lane when 'internal' then 'internal_admin' else 'external_admin' end
  on conflict do nothing;
  return result;
exception when unique_violation then
  raise exception using errcode = '23505', message = 'That payment reference or submission was already used';
end;
$$;

create or replace function public.decide_payment(
  p_payment_id uuid,
  p_decision text,
  p_reason text default null
) returns public.payment_transactions
language plpgsql
security definer
set search_path = public
as $$
declare
  payment_row public.payment_transactions%rowtype;
  request_row public.reservation_requests%rowtype;
  result public.payment_transactions%rowtype;
  verified_value integer;
  amount_due_now integer;
  current_status text;
  event_id uuid;
  correction_deadline timestamptz;
begin
  select * into payment_row from public.payment_transactions where id = p_payment_id for update;
  if payment_row.id is null then
    raise exception using errcode = 'P0002', message = 'Payment not found';
  end if;
  select * into request_row from public.reservation_requests where id = payment_row.request_id for update;
  if not public.lock_reservation_admin_scope(request_row.id) then
    raise exception using errcode = '42501', message = 'Payment review access denied';
  end if;
  if request_row.reservation_status not in ('awaiting_payment', 'confirmed') then
    raise exception using errcode = '22023', message = 'This reservation is no longer accepting payment decisions';
  end if;
  if payment_row.status <> 'submitted' then
    raise exception using errcode = '22023', message = 'This payment has already been reviewed';
  end if;
  if p_decision = 'reject' then
    if length(trim(coalesce(p_reason, ''))) < 3 then
      raise exception using errcode = '22023', message = 'A rejection reason is required';
    end if;
    correction_deadline := now() + interval '24 hours';
    update public.payment_transactions
    set status = 'needs_correction',
        verified_by = auth.uid(),
        verified_at = now(),
        rejection_reason = trim(p_reason),
        correction_due_at = correction_deadline
    where id = p_payment_id
    returning * into result;
    update public.reservation_requests
    set reservation_status = case
          when reservation_status = 'confirmed' then reservation_status
          else 'awaiting_payment'
        end,
        payment_due_at = case
          when reservation_status = 'awaiting_payment' then correction_deadline
          else payment_due_at
        end
    where id = request_row.id;
    event_id := public.reservation_event(
      request_row.id,
      'payment needs correction',
      trim(p_reason),
      jsonb_build_object(
        'payment_id', payment_row.id,
        'correction_due_at', correction_deadline,
        'status', 'needs_correction'
      ),
      null,
      true
    );
  elsif p_decision = 'verify' then
    update public.payment_transactions
    set status = 'verified',
        verified_by = auth.uid(),
        verified_at = now(),
        rejection_reason = null,
        correction_due_at = null
    where id = p_payment_id
    returning * into result;
    select coalesce(sum(amount_centavos), 0) into verified_value
    from public.payment_transactions
    where request_id = request_row.id and status = 'verified';
    amount_due_now := case
      when request_row.balance_due_at is not null and request_row.balance_due_at <= now()
        then request_row.total_amount_centavos
      else request_row.required_down_payment_centavos
    end;
    if request_row.reservation_status = 'awaiting_payment' and verified_value >= amount_due_now then
      update public.reservation_occurrences
      set booking_state = 'booked'
      where request_id = request_row.id and booking_state = 'held';
      update public.reservation_requests
      set reservation_status = 'confirmed',
          payment_due_at = null
      where id = request_row.id;
    end if;
    event_id := public.reservation_event(
      request_row.id,
      'verified payment',
      null,
      jsonb_build_object(
        'payment_id', payment_row.id,
        'amount_centavos', payment_row.amount_centavos,
        'verified_total_centavos', verified_value
      ),
      null,
      true
    );
    select reservation_status into current_status
    from public.reservation_requests where id = request_row.id;
    if current_status = 'confirmed'
       and verified_value >= request_row.total_amount_centavos
       and request_row.total_amount_centavos > 0 then
      perform public.issue_reservation_permit(request_row.id);
    end if;
  else
    raise exception using errcode = '22023', message = 'Decision must be verify or reject';
  end if;
  perform public.notify_reservation_user(
    request_row.id,
    event_id,
    case p_decision when 'verify' then 'payment_verify' else 'payment_needs_correction' end,
    case p_decision when 'verify' then 'Payment verified' else 'Payment needs correction' end,
    case p_decision
      when 'verify' then 'Your GCash payment was verified.'
      else trim(p_reason) || ' Correct by ' || to_char(correction_deadline at time zone 'Asia/Manila', 'Mon DD, YYYY HH12:MI AM') || '.'
    end
  );
  return result;
exception when exclusion_violation then
  raise exception using errcode = '23P01', message = 'The held schedule is no longer available';
end;
$$;

revoke all on function public.submit_payment(uuid, uuid, text, integer, text, text, uuid) from public, anon;
revoke all on function public.correct_payment_submission(uuid, integer, text, text, uuid) from public, anon;
revoke all on function public.decide_payment(uuid, text, text) from public, anon;
grant execute on function public.submit_payment(uuid, uuid, text, integer, text, text, uuid) to authenticated;
grant execute on function public.correct_payment_submission(uuid, integer, text, text, uuid) to authenticated;
grant execute on function public.decide_payment(uuid, text, text) to authenticated;

-- ---------------------------------------------------------------------
-- Requester self check-in
-- ---------------------------------------------------------------------

create or replace function public.self_check_in_occurrence(
  p_request_id uuid,
  p_occurrence_id uuid,
  p_expected_version integer default null,
  p_idempotency_key uuid default gen_random_uuid()
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  request_row public.reservation_requests%rowtype;
  occurrence_row public.reservation_occurrences%rowtype;
  existing_journal public.reservation_action_journal%rowtype;
  journal_id uuid;
  event_id uuid;
begin
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'Sign in required';
  end if;
  select * into request_row
  from public.reservation_requests
  where id = p_request_id
  for update;
  if request_row.id is null or request_row.requester_id <> auth.uid() then
    raise exception using errcode = '42501', message = 'Reservation access denied';
  end if;
  if request_row.reservation_status <> 'confirmed' then
    raise exception using errcode = '22023', message = 'Only confirmed reservations can be checked in';
  end if;
  if p_expected_version is not null and request_row.version <> p_expected_version then
    raise exception using errcode = '40001', message = 'This reservation changed. Refresh and try again';
  end if;
  select * into occurrence_row
  from public.reservation_occurrences
  where id = p_occurrence_id and request_id = p_request_id
  for update;
  if occurrence_row.id is null or occurrence_row.booking_state <> 'booked' then
    raise exception using errcode = '22023', message = 'This occurrence is not booked';
  end if;
  if occurrence_row.lifecycle_stage <> 'booked' then
    raise exception using errcode = '22023', message = 'This occurrence has already been checked in or closed';
  end if;
  if now() < occurrence_row.starts_at - interval '30 minutes' then
    raise exception using errcode = '22023', message = 'Check-in opens 30 minutes before the booking';
  end if;
  if now() > occurrence_row.starts_at + interval '15 minutes' then
    raise exception using errcode = '22023', message = 'Check-in closed 15 minutes after the booking start';
  end if;
  select * into existing_journal
  from public.reservation_action_journal
  where actor_id = auth.uid() and idempotency_key = p_idempotency_key;
  if existing_journal.id is not null then
    return jsonb_build_object('duplicate', true, 'request_id', p_request_id);
  end if;
  insert into public.reservation_action_journal(
    actor_id, idempotency_key, action, request_ids, before_requests, before_occurrences
  )
  values (
    auth.uid(), p_idempotency_key, 'self_check_in', array[p_request_id],
    jsonb_build_array(to_jsonb(request_row)), jsonb_build_array(to_jsonb(occurrence_row))
  )
  returning id into journal_id;
  update public.reservation_occurrences
  set lifecycle_stage = 'checked_in'
  where id = occurrence_row.id;
  update public.reservation_requests
  set payment_status = case when payment_status = 'authorized' then 'captured' else payment_status end
  where id = p_request_id;
  event_id := public.reservation_event(
    p_request_id,
    'self check in',
    null,
    jsonb_build_object('occurrence_id', occurrence_row.id, 'actor', 'requester'),
    occurrence_row.id,
    false
  );
  perform public.notify_reservation_user(
    p_request_id,
    event_id,
    'reservation_self_check_in',
    'Checked in',
    'Your facility check-in was recorded.'
  );
  update public.reservation_action_journal
  set after_versions = jsonb_build_object(p_request_id::text, (select version from public.reservation_requests where id = p_request_id))
  where id = journal_id;
  return jsonb_build_object('request_id', p_request_id, 'occurrence_id', p_occurrence_id, 'action_id', null);
end;
$$;

create or replace function public.record_occurrence_attendance(
  p_request_id uuid,
  p_occurrence_id uuid,
  p_action text,
  p_reason text default null,
  p_expected_version integer default null,
  p_idempotency_key uuid default gen_random_uuid()
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  request_row public.reservation_requests%rowtype;
  occurrence_row public.reservation_occurrences%rowtype;
  existing_journal public.reservation_action_journal%rowtype;
  journal_id uuid;
  event_id uuid;
  target_stage text;
  now_version integer;
begin
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'Sign in required';
  end if;
  if p_action not in ('complete', 'no_show') then
    raise exception using errcode = '22023', message = 'Administrator attendance can only complete or mark no-show. Requesters use self check-in.';
  end if;
  if not public.lock_reservation_admin_scope(p_request_id) then
    raise exception using errcode = '42501', message = 'Reservation access denied';
  end if;
  select * into existing_journal
  from public.reservation_action_journal
  where actor_id = auth.uid() and idempotency_key = p_idempotency_key;
  if existing_journal.id is not null then
    if existing_journal.action <> p_action or not (p_request_id = any(existing_journal.request_ids)) then
      raise exception using errcode = '22023', message = 'That attendance key was already used for another action';
    end if;
    return jsonb_build_object('duplicate', true, 'action_id', null, 'undo_until', null);
  end if;
  select * into request_row from public.reservation_requests where id = p_request_id for update;
  if request_row.id is null then
    raise exception using errcode = 'P0002', message = 'Reservation not found';
  end if;
  if request_row.reservation_status <> 'confirmed' then
    raise exception using errcode = '22023', message = 'Only a confirmed reservation can enter facility use';
  end if;
  if p_expected_version is not null and request_row.version <> p_expected_version then
    raise exception using errcode = '40001', message = 'This reservation changed. Refresh and try again';
  end if;
  select * into occurrence_row
  from public.reservation_occurrences
  where id = p_occurrence_id and request_id = p_request_id
  for update;
  if occurrence_row.id is null or occurrence_row.booking_state <> 'booked' then
    raise exception using errcode = '22023', message = 'This occurrence is not booked';
  end if;
  if p_action = 'complete' and occurrence_row.lifecycle_stage <> 'checked_in' then
    raise exception using errcode = '22023', message = 'Check in before completing this booking';
  end if;
  if p_action = 'no_show' and now() < occurrence_row.starts_at + interval '15 minutes' then
    raise exception using errcode = '22023', message = 'The no-show grace period has not ended';
  end if;
  target_stage := case p_action when 'complete' then 'completed' else 'no_show' end;
  insert into public.reservation_action_journal(
    actor_id, idempotency_key, action, request_ids, before_requests, before_occurrences
  )
  select auth.uid(), p_idempotency_key, p_action, array[p_request_id],
    jsonb_build_array(to_jsonb(request_row)), jsonb_build_array(to_jsonb(occurrence_row))
  returning id into journal_id;
  update public.reservation_occurrences
  set lifecycle_stage = target_stage,
      attendance_marked_at = now(),
      attendance_marked_by = auth.uid(),
      attendance_reason = nullif(trim(p_reason), '')
  where id = occurrence_row.id;
  if p_action = 'complete' then
    perform public.settle_loyalty_occurrence(occurrence_row.id, 'completed', null);
  end if;
  if not exists (
    select 1 from public.reservation_occurrences
    where request_id = p_request_id
      and lifecycle_stage not in ('completed', 'no_show')
  ) then
    update public.reservation_requests
    set reservation_status = 'completed'
    where id = p_request_id;
    perform public.settle_loyalty_discount_for_reservation(p_request_id, 'consume', p_action);
  end if;
  event_id := public.reservation_event(
    p_request_id,
    replace(p_action, '_', ' '),
    p_reason,
    jsonb_build_object('occurrence_id', occurrence_row.id),
    occurrence_row.id,
    true
  );
  perform public.notify_reservation_user(
    p_request_id,
    event_id,
    'reservation_' || p_action,
    initcap(replace(p_action, '_', ' ')),
    coalesce(nullif(trim(p_reason), ''), 'Your reservation attendance was updated.')
  );
  select version into now_version from public.reservation_requests where id = p_request_id;
  update public.reservation_action_journal
  set after_versions = jsonb_build_object(p_request_id::text, now_version)
  where id = journal_id;
  return jsonb_build_object('request_id', p_request_id, 'action_id', null, 'undo_until', null);
end;
$$;

revoke all on function public.self_check_in_occurrence(uuid, uuid, integer, uuid) from public, anon;
revoke all on function public.record_occurrence_attendance(uuid, uuid, text, text, integer, uuid) from public, anon;
grant execute on function public.self_check_in_occurrence(uuid, uuid, integer, uuid) to authenticated;
grant execute on function public.record_occurrence_attendance(uuid, uuid, text, text, integer, uuid) to authenticated;

-- ---------------------------------------------------------------------
-- Post-use assessment, evidence, and facility-condition anomalies
-- ---------------------------------------------------------------------

create table if not exists public.reservation_use_assessments (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null references public.reservation_requests(id) on delete cascade,
  occurrence_id uuid not null unique references public.reservation_occurrences(id) on delete cascade,
  facility_id uuid not null references public.facilities(id) on delete cascade,
  requester_id uuid not null references public.profiles(id) on delete cascade,
  admin_id uuid not null references public.profiles(id) on delete restrict,
  cleanliness_rating integer not null check (cleanliness_rating between 1 and 5),
  equipment_condition_rating integer not null check (equipment_condition_rating between 1 and 5),
  left_unclean boolean not null default false,
  equipment_damaged boolean not null default false,
  comment text not null default '',
  revision integer not null default 1 check (revision > 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check ((not left_unclean and not equipment_damaged) or length(trim(comment)) >= 3)
);

create table if not exists public.reservation_use_assessment_files (
  id uuid primary key default gen_random_uuid(),
  assessment_id uuid not null references public.reservation_use_assessments(id) on delete cascade,
  storage_path text not null unique,
  file_name text not null,
  mime_type text not null check (mime_type in ('image/jpeg','image/png')),
  byte_size integer not null check (byte_size between 1 and 10485760),
  created_at timestamptz not null default now()
);

create index if not exists reservation_use_assessments_request_idx
  on public.reservation_use_assessments(request_id, updated_at desc);
create index if not exists reservation_use_assessment_files_assessment_idx
  on public.reservation_use_assessment_files(assessment_id);

drop trigger if exists reservation_use_assessments_updated_at on public.reservation_use_assessments;
create trigger reservation_use_assessments_updated_at
before update on public.reservation_use_assessments
for each row execute procedure public.set_updated_at();

alter table public.reservation_use_assessments enable row level security;
alter table public.reservation_use_assessment_files enable row level security;
revoke all on public.reservation_use_assessments from public, anon, authenticated;
revoke all on public.reservation_use_assessment_files from public, anon, authenticated;
grant select on public.reservation_use_assessments to authenticated;
grant select on public.reservation_use_assessment_files to authenticated;

drop policy if exists reservation_use_assessments_read on public.reservation_use_assessments;
create policy reservation_use_assessments_read
on public.reservation_use_assessments for select to authenticated
using (requester_id = auth.uid() or public.can_manage_reservation(request_id));

drop policy if exists reservation_use_assessment_files_read on public.reservation_use_assessment_files;
create policy reservation_use_assessment_files_read
on public.reservation_use_assessment_files for select to authenticated
using (
  exists (
    select 1 from public.reservation_use_assessments a
    where a.id = reservation_use_assessment_files.assessment_id
      and (a.requester_id = auth.uid() or public.can_manage_reservation(a.request_id))
  )
);

insert into storage.buckets(id, name, public, file_size_limit, allowed_mime_types)
values (
  'facility-assessment-evidence', 'facility-assessment-evidence', false, 10485760,
  array['image/jpeg','image/png']
)
on conflict(id) do update set
  public = false,
  file_size_limit = 10485760,
  allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists facility_assessment_evidence_insert_admin on storage.objects;
create policy facility_assessment_evidence_insert_admin
on storage.objects for insert to authenticated
with check (
  bucket_id = 'facility-assessment-evidence'
  and public.admin_lane() is not null
);

drop policy if exists facility_assessment_evidence_read on storage.objects;
create policy facility_assessment_evidence_read
on storage.objects for select to authenticated
using (
  bucket_id = 'facility-assessment-evidence'
  and exists (
    select 1
    from public.reservation_use_assessment_files file_row
    join public.reservation_use_assessments assessment on assessment.id = file_row.assessment_id
    where file_row.storage_path = storage.objects.name
      and (assessment.requester_id = auth.uid() or public.can_manage_reservation(assessment.request_id))
  )
);

alter table public.reservation_anomaly_evidence
  add column if not exists assessment_id uuid
    references public.reservation_use_assessments(id) on delete cascade;

insert into public.anomaly_rules(
  rule_key, enabled, mode, applicable_lanes, signal_family, base_weight,
  evaluation_window_hours, configuration, rule_version
) values
  ('facility_left_unclean', true, 'active', array['internal','external'], 'facility_condition', 15, 2160, '{"flag":"left_unclean"}'::jsonb, 1),
  ('equipment_damage_reported', true, 'active', array['internal','external'], 'facility_condition', 30, 2160, '{"flag":"equipment_damaged"}'::jsonb, 1)
on conflict(rule_key) do update set
  enabled = excluded.enabled,
  mode = excluded.mode,
  applicable_lanes = excluded.applicable_lanes,
  signal_family = excluded.signal_family,
  base_weight = excluded.base_weight,
  evaluation_window_hours = excluded.evaluation_window_hours,
  configuration = excluded.configuration,
  updated_at = now();

create or replace function public.submit_reservation_use_assessment(
  p_occurrence_id uuid,
  p_cleanliness_rating integer,
  p_equipment_condition_rating integer,
  p_left_unclean boolean default false,
  p_equipment_damaged boolean default false,
  p_comment text default '',
  p_attachment_metadata jsonb default '[]'::jsonb,
  p_idempotency_key uuid default gen_random_uuid()
) returns public.reservation_use_assessments
language plpgsql
security definer
set search_path = public, storage
as $$
declare
  occurrence_row public.reservation_occurrences%rowtype;
  request_row public.reservation_requests%rowtype;
  existing public.reservation_use_assessments%rowtype;
  result public.reservation_use_assessments%rowtype;
  event_id uuid;
  attachment jsonb;
  v_anomaly_id uuid;
begin
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'Sign in required';
  end if;
  select * into occurrence_row from public.reservation_occurrences where id = p_occurrence_id for update;
  if occurrence_row.id is null then
    raise exception using errcode = 'P0002', message = 'Occurrence not found';
  end if;
  select * into request_row from public.reservation_requests where id = occurrence_row.request_id for update;
  if not public.lock_reservation_admin_scope(request_row.id) then
    raise exception using errcode = '42501', message = 'Reservation access denied';
  end if;
  if occurrence_row.lifecycle_stage not in ('completed', 'no_show') then
    raise exception using errcode = '22023', message = 'Assessment is available after the occurrence is completed or marked no-show';
  end if;
  if p_cleanliness_rating not between 1 and 5 or p_equipment_condition_rating not between 1 and 5 then
    raise exception using errcode = '22023', message = 'Ratings must be between 1 and 5';
  end if;
  if (coalesce(p_left_unclean, false) or coalesce(p_equipment_damaged, false))
     and length(trim(coalesce(p_comment, ''))) < 3 then
    raise exception using errcode = '22023', message = 'A comment is required when reporting unclean or damaged facilities';
  end if;
  if jsonb_array_length(coalesce(p_attachment_metadata, '[]'::jsonb)) > 3 then
    raise exception using errcode = '22023', message = 'A maximum of three evidence photos is allowed';
  end if;
  select * into existing from public.reservation_use_assessments where occurrence_id = occurrence_row.id for update;
  if existing.id is null then
    insert into public.reservation_use_assessments(
      request_id, occurrence_id, facility_id, requester_id, admin_id,
      cleanliness_rating, equipment_condition_rating, left_unclean,
      equipment_damaged, comment
    ) values (
      request_row.id, occurrence_row.id, request_row.facility_id, request_row.requester_id, auth.uid(),
      p_cleanliness_rating, p_equipment_condition_rating, coalesce(p_left_unclean, false),
      coalesce(p_equipment_damaged, false), trim(coalesce(p_comment, ''))
    )
    returning * into result;
  else
    update public.reservation_use_assessments
    set admin_id = auth.uid(),
        cleanliness_rating = p_cleanliness_rating,
        equipment_condition_rating = p_equipment_condition_rating,
        left_unclean = coalesce(p_left_unclean, false),
        equipment_damaged = coalesce(p_equipment_damaged, false),
        comment = trim(coalesce(p_comment, '')),
        revision = revision + 1
    where id = existing.id
    returning * into result;
  end if;
  for attachment in select value from jsonb_array_elements(coalesce(p_attachment_metadata, '[]'::jsonb)) loop
    if attachment->>'storage_path' not like request_row.id::text || '/' || occurrence_row.id::text || '/%' then
      raise exception using errcode = '42501', message = 'Invalid assessment evidence path';
    end if;
    if attachment->>'mime_type' not in ('image/jpeg', 'image/png') then
      raise exception using errcode = '22023', message = 'Evidence must be JPG or PNG';
    end if;
    insert into public.reservation_use_assessment_files(
      assessment_id, storage_path, file_name, mime_type, byte_size
    ) values (
      result.id,
      attachment->>'storage_path',
      attachment->>'file_name',
      attachment->>'mime_type',
      (attachment->>'byte_size')::integer
    )
    on conflict(storage_path) do nothing;
  end loop;
  event_id := public.reservation_event(
    request_row.id,
    'submitted post-use assessment',
    nullif(trim(coalesce(p_comment, '')), ''),
    jsonb_build_object(
      'assessment_id', result.id,
      'occurrence_id', occurrence_row.id,
      'cleanliness_rating', result.cleanliness_rating,
      'equipment_condition_rating', result.equipment_condition_rating,
      'left_unclean', result.left_unclean,
      'equipment_damaged', result.equipment_damaged,
      'revision', result.revision
    ) || case
      when existing.id is null then '{}'::jsonb
      else jsonb_build_object(
        'previous',
        jsonb_build_object(
          'cleanliness_rating', existing.cleanliness_rating,
          'equipment_condition_rating', existing.equipment_condition_rating,
          'left_unclean', existing.left_unclean,
          'equipment_damaged', existing.equipment_damaged,
          'comment', existing.comment,
          'revision', existing.revision
        )
      )
    end,
    occurrence_row.id,
    true
  );
  perform public.notify_reservation_user(
    request_row.id,
    event_id,
    'reservation_use_assessment',
    'Facility-use feedback posted',
    coalesce(nullif(result.comment, ''), 'An administrator posted a facility-use assessment.')
  );
  if result.left_unclean then
    v_anomaly_id := public.upsert_reservation_anomaly(
      request_row.requester_id,
      request_row.admin_lane,
      request_row.facility_id,
      'facility_left_unclean',
      'facility_left_unclean:' || result.id::text,
      array[request_row.id],
      array[occurrence_row.id],
      now(),
      occurrence_row.starts_at,
      occurrence_row.ends_at,
      1,
      jsonb_build_object('assessment_id', result.id, 'comment', result.comment, 'facility', request_row.facility_name),
      'The facility was reported left unclean after use.',
      true
    );
    update public.reservation_anomaly_evidence set assessment_id = result.id where anomaly_id = v_anomaly_id;
  elsif existing.id is not null and existing.left_unclean then
    update public.reservation_anomalies as anomaly
    set status = 'resolved',
        resolved_at = now(),
        resolved_by = auth.uid(),
        resolution_code = 'assessment_corrected',
        resolution_note = 'Assessment correction removed the left-unclean flag.',
        effective_risk_points = 0,
        last_evaluated_at = now(),
        updated_at = now()
    where anomaly.renter_id = request_row.requester_id
      and anomaly.admin_lane = request_row.admin_lane
      and anomaly.facility_id = request_row.facility_id
      and anomaly.rule_key = 'facility_left_unclean'
      and anomaly.correlation_key = 'facility_left_unclean:' || result.id::text
      and anomaly.status in ('open', 'acknowledged');
  end if;
  if result.equipment_damaged then
    v_anomaly_id := public.upsert_reservation_anomaly(
      request_row.requester_id,
      request_row.admin_lane,
      request_row.facility_id,
      'equipment_damage_reported',
      'equipment_damage_reported:' || result.id::text,
      array[request_row.id],
      array[occurrence_row.id],
      now(),
      occurrence_row.starts_at,
      occurrence_row.ends_at,
      1,
      jsonb_build_object('assessment_id', result.id, 'comment', result.comment, 'facility', request_row.facility_name),
      'Equipment damage was reported after facility use.',
      true
    );
    update public.reservation_anomaly_evidence set assessment_id = result.id where anomaly_id = v_anomaly_id;
  elsif existing.id is not null and existing.equipment_damaged then
    update public.reservation_anomalies as anomaly
    set status = 'resolved',
        resolved_at = now(),
        resolved_by = auth.uid(),
        resolution_code = 'assessment_corrected',
        resolution_note = 'Assessment correction removed the equipment-damaged flag.',
        effective_risk_points = 0,
        last_evaluated_at = now(),
        updated_at = now()
    where anomaly.renter_id = request_row.requester_id
      and anomaly.admin_lane = request_row.admin_lane
      and anomaly.facility_id = request_row.facility_id
      and anomaly.rule_key = 'equipment_damage_reported'
      and anomaly.correlation_key = 'equipment_damage_reported:' || result.id::text
      and anomaly.status in ('open', 'acknowledged');
  end if;
  perform public.recalculate_renter_risk_profiles(request_row.requester_id, request_row.admin_lane, now());
  return result;
end;
$$;

create or replace function public.correct_reservation_use_assessment(
  p_occurrence_id uuid,
  p_cleanliness_rating integer,
  p_equipment_condition_rating integer,
  p_left_unclean boolean default false,
  p_equipment_damaged boolean default false,
  p_comment text default '',
  p_attachment_metadata jsonb default '[]'::jsonb,
  p_idempotency_key uuid default gen_random_uuid()
) returns public.reservation_use_assessments
language sql
security definer
set search_path = public, storage
as $$
  select public.submit_reservation_use_assessment(
    p_occurrence_id,
    p_cleanliness_rating,
    p_equipment_condition_rating,
    p_left_unclean,
    p_equipment_damaged,
    p_comment,
    p_attachment_metadata,
    p_idempotency_key
  );
$$;

revoke all on function public.submit_reservation_use_assessment(uuid, integer, integer, boolean, boolean, text, jsonb, uuid) from public, anon;
revoke all on function public.correct_reservation_use_assessment(uuid, integer, integer, boolean, boolean, text, jsonb, uuid) from public, anon;
grant execute on function public.submit_reservation_use_assessment(uuid, integer, integer, boolean, boolean, text, jsonb, uuid) to authenticated;
grant execute on function public.correct_reservation_use_assessment(uuid, integer, integer, boolean, boolean, text, jsonb, uuid) to authenticated;

-- ---------------------------------------------------------------------
-- Overlap anomaly correction
-- ---------------------------------------------------------------------

create or replace function public.evaluate_overlapping_reservations(
  p_renter_id uuid,
  p_admin_lane text,
  p_as_of timestamptz default now(),
  p_notify boolean default true
) returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  pair_row record;
  anomaly_count integer := 0;
  anomaly_id uuid;
begin
  for pair_row in
    with eligible as (
      select
        r.id as request_id,
        r.facility_id,
        r.facility_name,
        o.id as occurrence_id,
        o.starts_at,
        o.ends_at
      from public.reservation_requests r
      join public.reservation_occurrences o on o.request_id = r.id
      where r.requester_id = p_renter_id
        and r.admin_lane = p_admin_lane
        and r.reservation_status in ('awaiting_payment', 'confirmed')
        and o.booking_state in ('held', 'booked')
        and o.ends_at >= p_as_of - interval '720 hours'
    ), pairs as (
      select
        e1.request_id as request_id_1,
        e2.request_id as request_id_2,
        e1.occurrence_id as occurrence_id_1,
        e2.occurrence_id as occurrence_id_2,
        e1.facility_id as facility_id_1,
        e1.facility_name as facility_name_1,
        e2.facility_name as facility_name_2,
        greatest(e1.starts_at, e2.starts_at) as overlap_started_at,
        least(e1.ends_at, e2.ends_at) as overlap_ended_at
      from eligible e1
      join eligible e2 on e1.occurrence_id < e2.occurrence_id
      where e1.starts_at < e2.ends_at
        and e2.starts_at < e1.ends_at
        and least(e1.ends_at, e2.ends_at) - greatest(e1.starts_at, e2.starts_at) >= interval '30 minutes'
    )
    select *
    from pairs
    order by overlap_started_at, occurrence_id_1, occurrence_id_2
  loop
    anomaly_id := public.upsert_reservation_anomaly(
      p_renter_id,
      p_admin_lane,
      pair_row.facility_id_1,
      'overlapping_reservations',
      'overlap:' || least(pair_row.request_id_1::text, pair_row.request_id_2::text) || ':' || greatest(pair_row.request_id_1::text, pair_row.request_id_2::text),
      array[pair_row.request_id_1, pair_row.request_id_2],
      array[pair_row.occurrence_id_1, pair_row.occurrence_id_2],
      pair_row.overlap_started_at,
      pair_row.overlap_started_at,
      pair_row.overlap_ended_at,
      1,
      jsonb_build_object(
        'overlap_started_at', pair_row.overlap_started_at,
        'overlap_ended_at', pair_row.overlap_ended_at,
        'facilities', jsonb_build_array(pair_row.facility_name_1, pair_row.facility_name_2)
      ),
      'The requester has two reservations that overlap by at least 30 minutes.',
      p_notify
    );
    if anomaly_id is not null then
      anomaly_count := anomaly_count + 1;
    end if;
  end loop;
  update public.reservation_anomalies a
  set status = 'false_positive',
      resolved_at = now(),
      resolution_code = 'automatic_overlap_remediation',
      resolution_note = 'Resolved because no timestamp overlap of at least 30 minutes remains.',
      effective_risk_points = 0,
      updated_at = now()
  where a.renter_id = p_renter_id
    and a.admin_lane = p_admin_lane
    and a.rule_key = 'overlapping_reservations'
    and a.status in ('open', 'acknowledged')
    and not exists (
      select 1
      from public.reservation_anomaly_evidence e1
      join public.reservation_anomaly_evidence e2
        on e1.anomaly_id = e2.anomaly_id
       and e1.id < e2.id
      join public.reservation_occurrences o1 on o1.id = e1.occurrence_id
      join public.reservation_occurrences o2 on o2.id = e2.occurrence_id
      join public.reservation_requests r1 on r1.id = e1.request_id
      join public.reservation_requests r2 on r2.id = e2.request_id
      where e1.anomaly_id = a.id
        and r1.reservation_status in ('awaiting_payment', 'confirmed')
        and r2.reservation_status in ('awaiting_payment', 'confirmed')
        and o1.booking_state in ('held', 'booked')
        and o2.booking_state in ('held', 'booked')
        and o1.starts_at < o2.ends_at
        and o2.starts_at < o1.ends_at
        and least(o1.ends_at, o2.ends_at) - greatest(o1.starts_at, o2.starts_at) >= interval '30 minutes'
    );
  perform public.recalculate_renter_risk_profiles(p_renter_id, p_admin_lane, p_as_of);
  return anomaly_count;
end;
$$;

do $$
declare
  row_value record;
begin
  for row_value in
    select distinct renter_id, admin_lane
    from public.reservation_anomalies
    where rule_key = 'overlapping_reservations'
      and status in ('open', 'acknowledged')
  loop
    perform public.evaluate_overlapping_reservations(
      p_renter_id => row_value.renter_id,
      p_admin_lane => row_value.admin_lane,
      p_as_of => now(),
      p_notify => false
    );
  end loop;
end $$;

revoke all on function public.evaluate_overlapping_reservations(uuid, text, timestamptz, boolean) from public, anon, authenticated;
grant execute on function public.evaluate_overlapping_reservations(uuid, text, timestamptz, boolean) to service_role;

-- ---------------------------------------------------------------------
-- Permit PDF persistence
-- ---------------------------------------------------------------------

alter table public.reservation_permits
  add column if not exists pdf_sha256 text,
  add column if not exists pdf_byte_size integer,
  add column if not exists pdf_generated_at timestamptz;

create or replace function public.record_reservation_permit_pdf(
  p_permit_id uuid,
  p_storage_path text,
  p_sha256 text,
  p_byte_size integer
) returns public.reservation_permits
language plpgsql
security definer
set search_path = public, storage
as $$
declare
  permit_row public.reservation_permits%rowtype;
  request_row public.reservation_requests%rowtype;
  result public.reservation_permits%rowtype;
begin
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'Sign in required';
  end if;
  select * into permit_row from public.reservation_permits where id = p_permit_id for update;
  if permit_row.id is null then
    raise exception using errcode = 'P0002', message = 'Permit not found';
  end if;
  select * into request_row from public.reservation_requests where id = permit_row.request_id;
  if request_row.requester_id <> auth.uid() and not public.can_manage_reservation(request_row.id) then
    raise exception using errcode = '42501', message = 'Permit access denied';
  end if;
  if permit_row.status <> 'active' then
    raise exception using errcode = '22023', message = 'Only active permits can record a PDF';
  end if;
  if p_storage_path <> request_row.requester_id::text || '/' || request_row.id::text || '/' || permit_row.permit_number || '-v' || permit_row.version::text || '.pdf' then
    raise exception using errcode = '42501', message = 'Invalid permit PDF path';
  end if;
  if p_byte_size is null or p_byte_size <= 0 or p_byte_size > 10485760 then
    raise exception using errcode = '22023', message = 'Invalid permit PDF size';
  end if;
  if p_sha256 is null or p_sha256 !~ '^[0-9a-fA-F]{64}$' then
    raise exception using errcode = '22023', message = 'Invalid permit PDF hash';
  end if;
  update public.reservation_permits
  set storage_path = p_storage_path,
      pdf_sha256 = lower(p_sha256),
      pdf_byte_size = p_byte_size,
      pdf_generated_at = now()
  where id = permit_row.id
  returning * into result;
  return result;
end;
$$;

revoke all on function public.record_reservation_permit_pdf(uuid, text, text, integer) from public, anon;
grant execute on function public.record_reservation_permit_pdf(uuid, text, text, integer) to authenticated;

-- ---------------------------------------------------------------------
-- Submission gate for organization representatives
-- ---------------------------------------------------------------------

create or replace function public.enforce_reservation_requester_slot()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.require_campus_representative_slot(new.requester_id);
  return new;
end;
$$;

drop trigger if exists reservation_requests_representative_slot on public.reservation_requests;
create trigger reservation_requests_representative_slot
before insert on public.reservation_requests
for each row execute procedure public.enforce_reservation_requester_slot();

revoke all on function public.enforce_reservation_requester_slot() from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- Payment-expiry behavior for submitted/correction proofs
-- ---------------------------------------------------------------------

create or replace function public.expire_due_reservations(
  p_dry_run boolean default false
)
returns table(request_id uuid, reason text)
language plpgsql
security definer
set search_path = public
as $$
declare
  candidate record;
  event_id uuid;
begin
  for candidate in
    select
      request.id,
      case
        when exists (
          select 1
          from public.payment_transactions as payment
          where payment.request_id = request.id
            and payment.status = 'needs_correction'
            and payment.correction_due_at is not null
            and payment.correction_due_at < now()
        ) then 'Payment correction deadline missed'
        when request.reservation_status = 'awaiting_payment'
          then 'Down payment deadline missed'
        else 'Remaining balance deadline missed'
      end as reason_value,
      case
        when exists (
          select 1
          from public.payment_transactions as payment
          where payment.request_id = request.id
            and payment.status = 'needs_correction'
            and payment.correction_due_at is not null
            and payment.correction_due_at < now()
        ) then 'payment_correction_deadline'
        when request.reservation_status = 'awaiting_payment'
          then 'down_payment_deadline'
        else 'balance_payment_deadline'
      end as reason_code
    from public.reservation_requests as request
    where not request.legacy_financial_state
      and not exists (
        select 1
        from public.payment_transactions as payment
        where payment.request_id = request.id
          and payment.status = 'submitted'
      )
      and not exists (
        select 1
        from public.payment_transactions as payment
        where payment.request_id = request.id
          and payment.status = 'needs_correction'
          and coalesce(payment.correction_due_at, request.payment_due_at) >= now()
      )
      and (
        (
          request.reservation_status = 'awaiting_payment'
          and (
            request.payment_due_at < now()
            or exists (
              select 1
              from public.payment_transactions as payment
              where payment.request_id = request.id
                and payment.status = 'needs_correction'
                and payment.correction_due_at is not null
                and payment.correction_due_at < now()
            )
          )
        )
        or (
          request.reservation_status = 'confirmed'
          and request.total_amount_centavos > 0
          and (
            request.balance_due_at < now()
            or exists (
              select 1
              from public.payment_transactions as payment
              where payment.request_id = request.id
                and payment.status = 'needs_correction'
                and payment.correction_due_at is not null
                and payment.correction_due_at < now()
            )
          )
          and (
            select coalesce(sum(payment.amount_centavos), 0)
            from public.payment_transactions as payment
            where payment.request_id = request.id
              and payment.status = 'verified'
          ) < request.total_amount_centavos
        )
      )
    order by request.id
    for update
  loop
    request_id := candidate.id;
    reason := candidate.reason_value;

    if not p_dry_run then
      update public.reservation_occurrences as occurrence
      set booking_state = 'expired',
          exception_reason = candidate.reason_value
      where occurrence.request_id = candidate.id
        and occurrence.booking_state in ('held', 'booked');

      update public.reservation_requests as request
      set reservation_status = 'expired',
          status = 'expired',
          decision_reason = candidate.reason_value,
          terminal_at = now(),
          terminal_reason_code = candidate.reason_code,
          decided_at = now()
      where request.id = candidate.id;

      perform public.settle_loyalty_discount_for_reservation(candidate.id, 'release', candidate.reason_value);

      event_id := public.reservation_event(
        candidate.id,
        'expired automatically',
        candidate.reason_value,
        jsonb_build_object('terminal_reason_code', candidate.reason_code),
        null,
        true
      );
      perform public.notify_reservation_user(
        candidate.id,
        event_id,
        'reservation_expired',
        'Reservation expired',
        candidate.reason_value || '. The facility and time slot are available again.'
      );
    end if;

    return next;
  end loop;
end;
$$;

revoke all on function public.expire_due_reservations(boolean) from public, anon, authenticated;
grant execute on function public.expire_due_reservations(boolean) to service_role;

notify pgrst, 'reload schema';
