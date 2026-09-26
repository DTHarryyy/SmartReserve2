-- Facility ownership and immutable requester administration lanes.
-- An administrator must both be assigned to the facility and match the
-- reservation's lane. Internal admins handle verified campus requesters;
-- external admins handle every other requester.

alter table public.reservation_requests
  add column if not exists admin_lane text;

update public.reservation_requests r
set admin_lane = case
  when p.verification_status = 'verified'
   and p.campus_claim in ('student', 'faculty', 'staff') then 'internal'
  else 'external'
end
from public.profiles p
where p.id = r.requester_id
  and r.admin_lane is null;

update public.reservation_requests
set admin_lane = 'external'
where admin_lane is null;

-- Lane is snapshotted now; verification changes must not move an in-flight
-- request between administrators or reprice it. Existing verification holds
-- join the lane derived during this migration.
drop trigger if exists profiles_release_verified_reservations on public.profiles;
update public.reservation_requests
set held_for_verification = false
where held_for_verification;

alter table public.reservation_requests
  alter column admin_lane set not null,
  add constraint reservation_requests_admin_lane_check
    check (admin_lane in ('internal', 'external'));

create index if not exists reservation_requests_facility_lane_queue_idx
  on public.reservation_requests(facility_id, admin_lane, status, created_at);

create table if not exists public.facility_admin_assignments (
  facility_id uuid not null references public.facilities(id) on delete cascade,
  admin_id uuid not null references public.profiles(id) on delete cascade,
  assignment_role text not null default 'manager'
    check (assignment_role in ('owner', 'manager')),
  assigned_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  primary key (facility_id, admin_id)
);

create index if not exists facility_admin_assignments_admin_idx
  on public.facility_admin_assignments(admin_id, facility_id);

alter table public.facility_admin_assignments enable row level security;
revoke all on public.facility_admin_assignments from public, anon, authenticated;
grant select on public.facility_admin_assignments to authenticated;

create or replace function public.requester_admin_lane(p_user_id uuid default auth.uid())
returns text
language sql
stable
security definer
set search_path = public
as $$
  select case
    when p.verification_status = 'verified'
     and p.campus_claim in ('student', 'faculty', 'staff') then 'internal'
    else 'external'
  end
  from public.profiles p
  where p.id = p_user_id;
$$;

create or replace function public.admin_lane(p_admin_id uuid default auth.uid())
returns text
language sql
stable
security definer
set search_path = public
as $$
  select case p.role
    when 'internal_admin' then 'internal'
    when 'external_admin' then 'external'
    else null
  end
  from public.profiles p
  where p.id = p_admin_id and p.account_status = 'active';
$$;

create or replace function public.can_manage_facility(
  p_facility_id uuid,
  p_admin_id uuid default auth.uid()
) returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.facility_admin_assignments a
    join public.profiles p on p.id = a.admin_id
    where a.facility_id = p_facility_id
      and a.admin_id = p_admin_id
      and p.role in ('internal_admin', 'external_admin')
      and p.account_status = 'active'
  );
$$;

create or replace function public.is_facility_owner(
  p_facility_id uuid,
  p_admin_id uuid default auth.uid()
) returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.facility_admin_assignments a
    join public.profiles p on p.id = a.admin_id
    where a.facility_id = p_facility_id
      and a.admin_id = p_admin_id
      and a.assignment_role = 'owner'
      and p.role in ('internal_admin', 'external_admin')
      and p.account_status = 'active'
  );
$$;

create or replace function public.has_facility_admin_lane(
  p_facility_id uuid,
  p_lane text
) returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select p_lane in ('internal', 'external') and exists (
    select 1
    from public.facility_admin_assignments a
    join public.profiles p on p.id = a.admin_id
    where a.facility_id = p_facility_id
      and p.account_status = 'active'
      and p.role = case p_lane
        when 'internal' then 'internal_admin'
        else 'external_admin'
      end
  );
$$;

create or replace function public.can_manage_reservation(
  p_request_id uuid,
  p_admin_id uuid default auth.uid()
) returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.reservation_requests r
    where r.id = p_request_id
      and public.can_manage_facility(r.facility_id, p_admin_id)
      and public.admin_lane(p_admin_id) = r.admin_lane
  );
$$;

create or replace function public.can_access_reservation(p_request_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.reservation_requests r
    where r.id = p_request_id
      and (r.requester_id = auth.uid() or public.can_manage_reservation(r.id))
  );
$$;

revoke all on function public.requester_admin_lane(uuid) from public, anon;
revoke all on function public.admin_lane(uuid) from public, anon;
revoke all on function public.can_manage_facility(uuid, uuid) from public, anon;
revoke all on function public.is_facility_owner(uuid, uuid) from public, anon;
revoke all on function public.has_facility_admin_lane(uuid, text) from public, anon;
revoke all on function public.can_manage_reservation(uuid, uuid) from public, anon;
revoke all on function public.can_access_reservation(uuid) from public, anon;
grant execute on function public.requester_admin_lane(uuid) to authenticated;
grant execute on function public.admin_lane(uuid) to authenticated;
grant execute on function public.can_manage_facility(uuid, uuid) to authenticated;
grant execute on function public.is_facility_owner(uuid, uuid) to authenticated;
grant execute on function public.has_facility_admin_lane(uuid, text) to authenticated;
grant execute on function public.can_manage_reservation(uuid, uuid) to authenticated;
grant execute on function public.can_access_reservation(uuid) to authenticated;

alter table public.reservation_requests
  alter column admin_lane set default 'external';

-- Preserve existing verified-user operations. External ownership must remain
-- explicit because the former global paid-reservation scope was unsafe.
insert into public.facility_admin_assignments(
  facility_id, admin_id, assignment_role, assigned_by
)
select f.id, p.id, 'owner', p.id
from public.facilities f
join public.profiles p
  on p.role = 'internal_admin' and p.account_status = 'active'
on conflict (facility_id, admin_id) do nothing;

create or replace function public.assign_facility_creator()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is not null and public.is_admin(auth.uid()) then
    insert into public.facility_admin_assignments(
      facility_id, admin_id, assignment_role, assigned_by
    ) values (new.id, auth.uid(), 'owner', auth.uid())
    on conflict (facility_id, admin_id) do update
      set assignment_role = 'owner';
  end if;
  return new;
end;
$$;

drop trigger if exists facilities_assign_creator on public.facilities;
create trigger facilities_assign_creator
after insert on public.facilities
for each row execute procedure public.assign_facility_creator();

create or replace function public.set_facility_admin_assignment(
  p_facility_id uuid,
  p_admin_id uuid,
  p_assignment_role text default 'manager'
) returns public.facility_admin_assignments
language plpgsql
security definer
set search_path = public
as $$
declare
  target public.profiles%rowtype;
  result public.facility_admin_assignments%rowtype;
begin
  if not public.is_facility_owner(p_facility_id) then
    raise exception using errcode = '42501', message = 'Facility owner access required';
  end if;
  if p_assignment_role not in ('owner', 'manager') then
    raise exception using errcode = '22023', message = 'Invalid facility assignment role';
  end if;
  select * into target from public.profiles where id = p_admin_id;
  if target.id is null or target.role not in ('internal_admin', 'external_admin')
     or target.account_status <> 'active' then
    raise exception using errcode = '22023', message = 'Choose an active administrator';
  end if;
  insert into public.facility_admin_assignments(
    facility_id, admin_id, assignment_role, assigned_by
  ) values (p_facility_id, p_admin_id, p_assignment_role, auth.uid())
  on conflict (facility_id, admin_id) do update
    set assignment_role = excluded.assignment_role,
        assigned_by = auth.uid()
  returning * into result;
  return result;
end;
$$;

create or replace function public.remove_facility_admin_assignment(
  p_facility_id uuid,
  p_admin_id uuid
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  owner_count integer;
  target_role text;
  remaining_lane_admins integer;
begin
  if not public.is_facility_owner(p_facility_id) then
    raise exception using errcode = '42501', message = 'Facility owner access required';
  end if;
  perform 1 from public.facility_admin_assignments
    where facility_id = p_facility_id for update;
  select count(*) into owner_count
  from public.facility_admin_assignments
  where facility_id = p_facility_id and assignment_role = 'owner';
  if exists (
    select 1 from public.facility_admin_assignments
    where facility_id = p_facility_id and admin_id = p_admin_id
      and assignment_role = 'owner'
  ) and owner_count <= 1 then
    raise exception using errcode = '22023', message = 'A facility must keep at least one owner';
  end if;
  select p.role into target_role
  from public.facility_admin_assignments a
  join public.profiles p on p.id = a.admin_id
  where a.facility_id = p_facility_id and a.admin_id = p_admin_id;
  if target_role in ('internal_admin','external_admin') then
    select count(*) into remaining_lane_admins
    from public.facility_admin_assignments a
    join public.profiles p on p.id = a.admin_id
    where a.facility_id = p_facility_id and a.admin_id <> p_admin_id
      and p.role = target_role and p.account_status = 'active';
    if remaining_lane_admins = 0 and exists(
      select 1 from public.reservation_requests r
      where r.facility_id = p_facility_id
        and r.admin_lane = case target_role
          when 'internal_admin' then 'internal' else 'external' end
        and r.status in ('pending','approved','changes_requested')
    ) then
      raise exception using errcode = '22023',
        message = 'Assign another administrator for this lane before removing the last active manager';
    end if;
  end if;
  delete from public.facility_admin_assignments
  where facility_id = p_facility_id and admin_id = p_admin_id;
end;
$$;

revoke all on function public.set_facility_admin_assignment(uuid, uuid, text)
  from public, anon;
revoke all on function public.remove_facility_admin_assignment(uuid, uuid)
  from public, anon;
grant execute on function public.set_facility_admin_assignment(uuid, uuid, text)
  to authenticated;
grant execute on function public.remove_facility_admin_assignment(uuid, uuid)
  to authenticated;

drop policy if exists facility_assignments_read on public.facility_admin_assignments;
create policy facility_assignments_read
on public.facility_admin_assignments for select to authenticated
using (
  admin_id = auth.uid()
  or public.is_facility_owner(facility_id)
);

-- Both administrator roles can create facilities. Updates are assignment-only.
drop policy if exists facilities_insert_admin on public.facilities;
drop policy if exists facilities_insert_internal_admin on public.facilities;
drop policy if exists facilities_update_admin on public.facilities;
drop policy if exists facilities_update_internal_admin on public.facilities;
drop policy if exists facilities_select on public.facilities;

create policy facilities_select on public.facilities
for select to authenticated
using (
  public.can_manage_facility(id)
  or (archived_at is null and public_listing and status <> 'draft')
);

create policy facilities_insert_assigned_admin on public.facilities
for insert to authenticated
with check (public.is_admin());

create policy facilities_update_assigned_admin on public.facilities
for update to authenticated
using (public.can_manage_facility(id))
with check (public.can_manage_facility(id));

-- Reservation reads are requester-owned or assignment+lane scoped.
drop policy if exists reservation_requests_read on public.reservation_requests;
create policy reservation_requests_read on public.reservation_requests
for select to authenticated
using (requester_id = auth.uid() or public.can_manage_reservation(id));

drop policy if exists reservation_occurrences_read on public.reservation_occurrences;
create policy reservation_occurrences_read on public.reservation_occurrences
for select to authenticated
using (public.can_access_reservation(request_id));

drop policy if exists reservation_attachments_read on public.reservation_attachments;
create policy reservation_attachments_read on public.reservation_attachments
for select to authenticated
using (owner_id = auth.uid() or public.can_manage_reservation(request_id));

drop policy if exists reservation_events_read on public.reservation_events;
create policy reservation_events_read on public.reservation_events
for select to authenticated
using (public.can_access_reservation(request_id));

-- Existing paths begin with uploader id. An assigned manager may also manage
-- a photo after it is attached to a facility row.
drop policy if exists facility_photos_insert_admin on storage.objects;
drop policy if exists facility_photos_insert_internal_admin on storage.objects;
drop policy if exists facility_photos_update_admin on storage.objects;
drop policy if exists facility_photos_update_internal_admin on storage.objects;
drop policy if exists facility_photos_delete_admin on storage.objects;
drop policy if exists facility_photos_delete_internal_admin on storage.objects;

create policy facility_photos_insert_assigned_admin on storage.objects
for insert to authenticated
with check (
  bucket_id = 'facility-photos'
  and public.is_admin()
  and (storage.foldername(name))[1] = auth.uid()::text
);

create policy facility_photos_update_assigned_admin on storage.objects
for update to authenticated
using (
  bucket_id = 'facility-photos' and (
    (storage.foldername(name))[1] = auth.uid()::text
    or exists (
      select 1 from public.facilities f
      where f.photo_paths @> array[storage.objects.name]
        and public.can_manage_facility(f.id)
    )
  )
)
with check (bucket_id = 'facility-photos');

create policy facility_photos_delete_assigned_admin on storage.objects
for delete to authenticated
using (
  bucket_id = 'facility-photos' and (
    (storage.foldername(name))[1] = auth.uid()::text
    or exists (
      select 1 from public.facilities f
      where f.photo_paths @> array[storage.objects.name]
        and public.can_manage_facility(f.id)
    )
  )
);

drop policy if exists reservation_files_read on storage.objects;
create policy reservation_files_read on storage.objects
for select to authenticated
using (
  bucket_id = 'reservation-attachments' and (
    (storage.foldername(name))[1] = auth.uid()::text
    or exists (
      select 1 from public.reservation_attachments a
      where a.storage_path = name and public.can_manage_reservation(a.request_id)
    )
  )
);

drop policy if exists reservation_files_delete_own on storage.objects;
create policy reservation_files_delete_own on storage.objects
for delete to authenticated
using (
  bucket_id = 'reservation-attachments'
  and (storage.foldername(name))[1] = auth.uid()::text
);

-- Capability summary keeps assignment rows private while letting the client
-- distinguish editable and bookable facilities.
create or replace function public.my_facility_access()
returns table (
  facility_id uuid,
  can_manage boolean,
  assignment_role text,
  supports_internal boolean,
  supports_external boolean,
  bookable boolean
)
language sql
stable
security definer
set search_path = public
as $$
  select f.id,
    public.can_manage_facility(f.id),
    (select a.assignment_role from public.facility_admin_assignments a
      where a.facility_id = f.id and a.admin_id = auth.uid()),
    public.has_facility_admin_lane(f.id, 'internal'),
    public.has_facility_admin_lane(f.id, 'external'),
    case when public.admin_lane() is null
      then f.archived_at is null and f.public_listing and f.status = 'active'
        and public.has_facility_admin_lane(f.id, public.requester_admin_lane())
      else false end
  from public.facilities f
  where f.archived_at is null;
$$;

revoke all on function public.my_facility_access() from public, anon;
grant execute on function public.my_facility_access() to authenticated;

-- Scope the existing reservation action wrapper before it reaches the legacy
-- mutation implementation. Phase 3 will intercept payment-aware approval.
create or replace function public.reservation_action(
  p_request_id uuid, p_action text, p_reason text default null,
  p_payload jsonb default '{}'::jsonb, p_expected_version integer default null,
  p_idempotency_key uuid default gen_random_uuid()
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_action in (
    'approve','approve_partial','approve_bump','decline','request_changes',
    'offer_alternative','reopen','expire','check_in','complete','no_show'
  ) and not public.can_manage_reservation(p_request_id) then
    raise exception using errcode = '42501', message = 'Reservation access denied';
  end if;
  if p_action in ('cancel','accept_alternative','resubmit') and not (
    public.can_manage_reservation(p_request_id)
    or exists (
      select 1 from public.reservation_requests r
      where r.id = p_request_id and r.requester_id = auth.uid()
    )
  ) then
    raise exception using errcode = '42501', message = 'Reservation access denied';
  end if;
  return public.reservation_action_unscoped(
    p_request_id, p_action, p_reason, p_payload,
    p_expected_version, p_idempotency_key
  );
end;
$$;

create or replace function public.approve_and_bump_reservation(
  p_request_id uuid, p_reason text, p_expected_version integer,
  p_idempotency_key uuid
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.can_manage_reservation(p_request_id) then
    raise exception using errcode = '42501', message = 'Reservation access denied';
  end if;
  return public.approve_and_bump_reservation_unscoped(
    p_request_id, p_reason, p_expected_version, p_idempotency_key
  );
end;
$$;

revoke all on function public.reservation_action(uuid,text,text,jsonb,integer,uuid)
  from public, anon;
revoke all on function public.approve_and_bump_reservation(uuid,text,integer,uuid)
  from public, anon;
grant execute on function public.reservation_action(uuid,text,text,jsonb,integer,uuid)
  to authenticated;
grant execute on function public.approve_and_bump_reservation(uuid,text,integer,uuid)
  to authenticated;

notify pgrst, 'reload schema';
