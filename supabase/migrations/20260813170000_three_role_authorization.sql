-- Consolidate authorization to user, internal_admin and external_admin.
-- Student/faculty/staff/none remain verification claim metadata only.

do $$
declare constraint_name text;
begin
  select c.conname into constraint_name
  from pg_constraint c
  where c.conrelid = 'public.profiles'::regclass
    and c.contype = 'c'
    and pg_get_constraintdef(c.oid) ilike '%role%student%';
  if constraint_name is not null then
    execute format('alter table public.profiles drop constraint %I', constraint_name);
  end if;
end $$;

update public.profiles
set role = 'user'
where role in ('student', 'faculty', 'staff', 'guest');

update public.reservation_requests
set requester_role = 'user'
where requester_role in ('student', 'faculty', 'staff', 'guest');

update public.reservation_events
set actor_role = 'user'
where actor_role in ('student', 'faculty', 'staff', 'guest');

update public.audit_entries
set actor_role = 'user'
where actor_role in ('student', 'faculty', 'staff', 'guest');

update public.account_admin_events
set before_values = case
      when before_values->>'role' in ('student','faculty','staff','guest')
        then jsonb_set(before_values, '{role}', '"user"'::jsonb)
      else before_values end,
    after_values = case
      when after_values->>'role' in ('student','faculty','staff','guest')
        then jsonb_set(after_values, '{role}', '"user"'::jsonb)
      else after_values end;

alter table public.profiles alter column role set default 'user';
alter table public.profiles
  add constraint profiles_role_check
  check (role in ('user', 'internal_admin', 'external_admin'));

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, email, full_name, role)
  values (new.id, new.email, coalesce(new.raw_user_meta_data ->> 'full_name', ''), 'user');
  return new;
end;
$$;

create or replace function public.complete_guest_onboarding()
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  update public.profiles
  set campus_claim='none', role='user', verification_status='none',
      onboarding_complete=true
  where id=auth.uid() and role='user';
end;
$$;

create or replace function public.sync_profile_from_verification()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  update public.profiles
  set campus_claim=new.claim_type, campus_id=new.campus_id, unit=new.unit,
      role='user', verification_status='pending', onboarding_complete=true
  where id=new.user_id and role='user';
  return new;
end;
$$;

create or replace function public.is_external_admin(target_id uuid default auth.uid())
returns boolean language sql stable security definer set search_path = public as $$
  select exists(select 1 from public.profiles
    where id=target_id and role='external_admin' and account_status='active');
$$;
revoke all on function public.is_external_admin(uuid) from public,anon;
grant execute on function public.is_external_admin(uuid) to authenticated;

-- External administrators may see only released requests which require payment.
create or replace function public.can_access_reservation(p_request_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists(
    select 1 from public.reservation_requests r
    where r.id=p_request_id and (
      r.requester_id=auth.uid()
      or public.is_internal_admin()
      or (public.is_external_admin() and not r.held_for_verification
          and r.payment_status <> 'not_required')
    )
  );
$$;
revoke all on function public.can_access_reservation(uuid) from public, anon;
grant execute on function public.can_access_reservation(uuid) to authenticated;

drop policy if exists facilities_insert_admin on public.facilities;
create policy facilities_insert_internal_admin on public.facilities
for insert to authenticated with check (public.is_internal_admin());
drop policy if exists facilities_update_admin on public.facilities;
create policy facilities_update_internal_admin on public.facilities
for update to authenticated using (public.is_internal_admin())
with check (public.is_internal_admin());

drop policy if exists facility_photos_insert_admin on storage.objects;
create policy facility_photos_insert_internal_admin on storage.objects
for insert to authenticated with check (
  bucket_id='facility-photos' and public.is_internal_admin());
drop policy if exists facility_photos_update_admin on storage.objects;
create policy facility_photos_update_internal_admin on storage.objects
for update to authenticated using (
  bucket_id='facility-photos' and public.is_internal_admin())
with check (bucket_id='facility-photos' and public.is_internal_admin());
drop policy if exists facility_photos_delete_admin on storage.objects;
create policy facility_photos_delete_internal_admin on storage.objects
for delete to authenticated using (
  bucket_id='facility-photos' and public.is_internal_admin());

drop policy if exists reservation_requests_read on public.reservation_requests;
create policy reservation_requests_read on public.reservation_requests
for select to authenticated using (public.can_access_reservation(id));
drop policy if exists reservation_occurrences_read on public.reservation_occurrences;
create policy reservation_occurrences_read on public.reservation_occurrences
for select to authenticated using (public.can_access_reservation(request_id));
drop policy if exists reservation_attachments_read on public.reservation_attachments;
create policy reservation_attachments_read on public.reservation_attachments
for select to authenticated using (public.can_access_reservation(request_id));
drop policy if exists reservation_events_read on public.reservation_events;
create policy reservation_events_read on public.reservation_events
for select to authenticated using (public.can_access_reservation(request_id));

drop policy if exists reservation_files_read on storage.objects;
create policy reservation_files_read on storage.objects for select to authenticated
using (
  bucket_id='reservation-attachments' and (
    (storage.foldername(name))[1]=auth.uid()::text
    or public.is_internal_admin()
    or (public.is_external_admin() and exists(
      select 1 from public.reservation_attachments a
      where a.storage_path=name and public.can_access_reservation(a.request_id)
    ))
  )
);
drop policy if exists reservation_files_delete_own on storage.objects;
create policy reservation_files_delete_own on storage.objects for delete to authenticated
using (bucket_id='reservation-attachments' and (
  (storage.foldername(name))[1]=auth.uid()::text or public.is_internal_admin()));

-- The client amount remains in the signature for old clients, but is ignored.
create or replace function public.reservation_quote_centavos(
  p_facility_id uuid, p_starts_at timestamptz[], p_ends_at timestamptz[]
) returns integer language plpgsql stable security definer set search_path=public as $$
declare capacity_value integer; multiplier integer; total numeric := 0; i integer;
begin
  select capacity into capacity_value from public.facilities where id=p_facility_id;
  if capacity_value is null then raise exception using errcode='P0002',message='Facility not found'; end if;
  if cardinality(p_starts_at) is null or cardinality(p_starts_at)<>cardinality(p_ends_at) then
    raise exception using errcode='22023',message='Invalid reservation occurrences';
  end if;
  multiplier := case when capacity_value>=400 then 3 when capacity_value>=80 then 2 else 1 end;
  for i in 1..cardinality(p_starts_at) loop
    if p_starts_at[i]>=p_ends_at[i] then raise exception using errcode='22023',message='End time must be after start time'; end if;
    total := total + extract(epoch from (p_ends_at[i]-p_starts_at[i]))/3600;
  end loop;
  return round(total * 50000 * multiplier)::integer;
end;
$$;
revoke all on function public.reservation_quote_centavos(uuid,timestamptz[],timestamptz[]) from public,anon,authenticated;

alter function public.submit_reservation(uuid,uuid,text,integer,timestamptz[],timestamptz[],jsonb,integer)
rename to submit_reservation_untrusted_amount;
revoke all on function public.submit_reservation_untrusted_amount(uuid,uuid,text,integer,timestamptz[],timestamptz[],jsonb,integer)
from public,anon,authenticated;

create function public.submit_reservation(
  p_request_id uuid, p_facility_id uuid, p_purpose text, p_headcount integer,
  p_starts_at timestamptz[], p_ends_at timestamptz[],
  p_attachment_metadata jsonb default '[]'::jsonb,
  p_payment_amount_centavos integer default 0
) returns public.reservation_requests
language plpgsql security definer set search_path=public,storage as $$
declare calculated integer; result public.reservation_requests%rowtype;
begin
  calculated := public.reservation_quote_centavos(p_facility_id,p_starts_at,p_ends_at);
  result := public.submit_reservation_untrusted_amount(
    p_request_id,p_facility_id,p_purpose,p_headcount,p_starts_at,p_ends_at,
    p_attachment_metadata,calculated);
  if result.payment_status='not_required' then
    delete from public.app_notifications n using public.profiles recipient
    where n.request_id=result.id and n.recipient_id=recipient.id
      and recipient.role='external_admin';
  end if;
  return result;
end;
$$;
revoke all on function public.submit_reservation(uuid,uuid,text,integer,timestamptz[],timestamptz[],jsonb,integer)
from public,anon;
grant execute on function public.submit_reservation(uuid,uuid,text,integer,timestamptz[],timestamptz[],jsonb,integer) to authenticated;

-- Put an authorization gate in front of the legacy action implementation.
alter function public.reservation_action(uuid,text,text,jsonb,integer,uuid)
rename to reservation_action_unscoped;
revoke all on function public.reservation_action_unscoped(uuid,text,text,jsonb,integer,uuid)
from public,anon,authenticated;
create function public.reservation_action(
  p_request_id uuid, p_action text, p_reason text default null,
  p_payload jsonb default '{}'::jsonb, p_expected_version integer default null,
  p_idempotency_key uuid default gen_random_uuid()
) returns jsonb language plpgsql security definer set search_path=public as $$
begin
  if p_action='approve_bump' and not public.is_internal_admin() then
    raise exception using errcode='42501',message='Only internal administrators may bump another booking';
  end if;
  if not public.is_internal_admin() and not (
    public.is_external_admin() and exists(select 1 from public.reservation_requests
      where id=p_request_id and not held_for_verification
        and payment_status<>'not_required')
  ) and not exists(select 1 from public.reservation_requests
      where id=p_request_id and requester_id=auth.uid()
        and p_action in ('cancel','accept_alternative','resubmit')) then
    raise exception using errcode='42501',message='Reservation access denied';
  end if;
  return public.reservation_action_unscoped(p_request_id,p_action,p_reason,p_payload,
    p_expected_version,p_idempotency_key);
end;
$$;
revoke all on function public.reservation_action(uuid,text,text,jsonb,integer,uuid)
from public,anon;
grant execute on function public.reservation_action(uuid,text,text,jsonb,integer,uuid) to authenticated;

alter function public.approve_and_bump_reservation(uuid,text,integer,uuid)
rename to approve_and_bump_reservation_unscoped;
revoke all on function public.approve_and_bump_reservation_unscoped(uuid,text,integer,uuid)
from public,anon,authenticated;
create function public.approve_and_bump_reservation(
  p_request_id uuid,p_reason text,p_expected_version integer,p_idempotency_key uuid
) returns jsonb language plpgsql security definer set search_path=public as $$
begin
  if not public.is_internal_admin() then
    raise exception using errcode='42501',message='Reservation access denied';
  end if;
  return public.approve_and_bump_reservation_unscoped(
    p_request_id,p_reason,p_expected_version,p_idempotency_key);
end;
$$;
revoke all on function public.approve_and_bump_reservation(uuid,text,integer,uuid)
from public,anon;
grant execute on function public.approve_and_bump_reservation(uuid,text,integer,uuid) to authenticated;

-- Verification decisions route held requests to the correct operational queue.
create or replace function public.release_verified_reservations()
returns trigger language plpgsql security definer set search_path=public as $$
declare request_row public.reservation_requests%rowtype; event_id uuid; quote_value integer;
begin
  if old.verification_status='verified' and new.verification_status in ('pending','rejected') then
    for request_row in select r.* from public.reservation_requests r
      where r.requester_id=new.id and r.status='pending'
        and exists(select 1 from public.reservation_occurrences o
          where o.request_id=r.id and o.starts_at>now()) for update
    loop
      select public.reservation_quote_centavos(request_row.facility_id,
        array_agg(o.starts_at order by o.starts_at),array_agg(o.ends_at order by o.starts_at))
      into quote_value from public.reservation_occurrences o where o.request_id=request_row.id;
      update public.reservation_requests set held_for_verification=true,
        payment_amount_centavos=quote_value,payment_status='quoted' where id=request_row.id;
    end loop;
  end if;

  if new.verification_status in ('verified','rejected')
      and old.verification_status is distinct from new.verification_status then
    for request_row in select * from public.reservation_requests
      where requester_id=new.id and held_for_verification and status='pending' for update
    loop
      if exists(select 1 from public.reservation_occurrences where request_id=request_row.id and starts_at>now()) then
        update public.reservation_requests set held_for_verification=false,
          payment_amount_centavos=case when new.verification_status='verified' then 0 else payment_amount_centavos end,
          payment_status=case when new.verification_status='verified' then 'not_required' else 'quoted' end
        where id=request_row.id;
        event_id:=public.reservation_event(request_row.id,
          case when new.verification_status='verified' then 'released after campus verification'
               else 'released as a paid reservation' end,null,'{}'::jsonb,null,false);
        insert into public.app_notifications(recipient_id,request_id,event_id,kind,title,body)
        select p.id,request_row.id,event_id,'reservation_released','Reservation released',
          request_row.requester_name||'''s request is ready for review.'
        from public.profiles p where p.account_status='active' and p.role=
          case when new.verification_status='verified' then 'internal_admin' else 'external_admin' end;
      else
        update public.reservation_requests set held_for_verification=false,status='expired',
          payment_status=case when payment_status='quoted' then 'voided' else payment_status end
        where id=request_row.id;
        update public.reservation_occurrences set booking_state='expired' where request_id=request_row.id;
      end if;
    end loop;
  end if;
  return new;
end;
$$;

-- SQL helper used only to raise a clean authorization error below.
create or replace function public.raise_external_clients_forbidden()
returns boolean language plpgsql volatile security definer set search_path=public as $$
begin raise exception using errcode='42501',message='External administrator access required'; end;
$$;
revoke all on function public.raise_external_clients_forbidden() from public,anon,authenticated;

-- Sanitized external client directory. Verification and campus fields never leave this RPC.
create or replace function public.get_external_clients()
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare result_value jsonb;
begin
  if not public.is_external_admin() then
    perform public.raise_external_clients_forbidden();
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',p.id,'email',p.email,'full_name',coalesce(nullif(p.full_name,''),p.email),
    'role','user','account_status',p.account_status,'created_at',p.created_at,
    'reservation_count',coalesce(metrics.reservation_count,0),
    'last_reservation_at',metrics.last_reservation_at
  ) order by metrics.last_reservation_at desc nulls last,p.created_at desc),'[]'::jsonb)
  into result_value
  from public.profiles p
  left join lateral (
    select count(*)::integer reservation_count,max(r.created_at) last_reservation_at
    from public.reservation_requests r where r.requester_id=p.id
      and not r.held_for_verification and r.payment_status<>'not_required'
  ) metrics on true
  where p.role='user' and p.verification_status in ('none','rejected')
    and metrics.reservation_count>0;
  return result_value;
end;
$$;
revoke all on function public.get_external_clients() from public,anon;
grant execute on function public.get_external_clients() to authenticated;

-- All direct account administration remains internal-admin-only, with three valid targets.
create or replace function public.validate_account_role_change(p_role text)
returns boolean language sql immutable as $$
  select p_role in ('user','internal_admin','external_admin');
$$;
revoke all on function public.validate_account_role_change(text) from public,anon;
grant execute on function public.validate_account_role_change(text) to authenticated;

alter function public.admin_manage_account(uuid,uuid,text,text,text,date)
rename to admin_manage_account_legacy_roles;
revoke all on function public.admin_manage_account_legacy_roles(uuid,uuid,text,text,text,date)
from public,anon,authenticated;
create function public.admin_manage_account(
  p_actor uuid,p_target uuid,p_action text,p_role text default null,
  p_reason text default null,p_suspended_until date default null
) returns jsonb language plpgsql security definer set search_path=public as $$
declare target public.profiles%rowtype; updated public.profiles%rowtype;
  active_internal_admins integer; event_reason text:=nullif(trim(coalesce(p_reason,'')),'');
begin
  if not public.is_internal_admin(p_actor) then
    raise exception using errcode='42501',message='Forbidden';
  end if;
  if p_action='change_role' then
    if p_role is null or not public.validate_account_role_change(p_role) then
      raise exception using errcode='22023',message='Invalid role: must be user, internal_admin, or external_admin';
    end if;
    if p_target=p_actor then raise exception using errcode='P0001',message='You cannot change your own role'; end if;
    perform id from public.profiles where role='internal_admin' order by id for update;
    select * into target from public.profiles where id=p_target for update;
    if not found then raise exception using errcode='P0002',message='Account not found'; end if;
    select count(*) into active_internal_admins from public.profiles
      where role='internal_admin' and account_status='active';
    if target.role='internal_admin' and target.account_status='active'
        and p_role<>'internal_admin' and active_internal_admins<=1 then
      raise exception using errcode='P0001',message='The last active internal admin cannot be demoted';
    end if;
    update public.profiles set role=p_role where id=p_target returning * into updated;
    insert into public.account_admin_events(actor_id,target_id,target_email,action,reason,before_values,after_values)
    values(p_actor,p_target,target.email,'change_role',event_reason,to_jsonb(target),to_jsonb(updated));
    return to_jsonb(updated);
  end if;
  return public.admin_manage_account_legacy_roles(
    p_actor,p_target,p_action,p_role,p_reason,p_suspended_until);
end;
$$;
revoke all on function public.admin_manage_account(uuid,uuid,text,text,text,date)
from public,anon,authenticated;
grant execute on function public.admin_manage_account(uuid,uuid,text,text,text,date)
to service_role;

-- External reports contain paid reservations only and never per-admin details.
create or replace function public.get_external_admin_report(
  p_from timestamptz,p_to timestamptz,p_category text default null
) returns jsonb language plpgsql stable security definer set search_path=public as $$
declare utilisation_value jsonb; summary_value jsonb; occurrences_value jsonb;
  demand_value jsonb; performance_value jsonb;
begin
  if not public.is_external_admin() then raise exception using errcode='42501',message='External administrator access required'; end if;
  if p_from is null or p_to is null or p_from>=p_to or p_to-p_from>interval '370 days' then
    raise exception using errcode='22023',message='Invalid report range';
  end if;
  with facility_scope as (
    select * from public.facilities f where f.archived_at is null and f.status='active'
      and (p_category is null or f.category=p_category)
  ), open_hours as (
    select f.id,coalesce(sum(greatest(0,extract(epoch from(
      least(((d::date+f.close_time) at time zone 'Asia/Manila'),p_to)-
      greatest(((d::date+f.open_time) at time zone 'Asia/Manila'),p_from)))/3600))
      filter(where f.open_days[extract(isodow from d)::integer]),0) available_hours
    from facility_scope f cross join generate_series(
      (p_from at time zone 'Asia/Manila')::date,
      ((p_to-interval '1 microsecond') at time zone 'Asia/Manila')::date,interval '1 day') d
    group by f.id
  ), booked as (
    select o.facility_id,sum(extract(epoch from(least(o.ends_at,p_to)-greatest(o.starts_at,p_from)))/3600) booked_hours
    from public.reservation_occurrences o join public.reservation_requests r on r.id=o.request_id
    where o.booking_state='booked' and o.starts_at<p_to and o.ends_at>p_from
      and not r.held_for_verification and r.payment_status<>'not_required'
    group by o.facility_id
  ) select coalesce(jsonb_agg(jsonb_build_object(
    'facility_id',f.id,'facility_name',f.name::text,'building',f.building,'category',f.category,
    'booked_hours',round(coalesce(b.booked_hours,0)::numeric,2),
    'available_hours',round(coalesce(h.available_hours,0)::numeric,2),
    'fraction',case when coalesce(h.available_hours,0)=0 then 0 else least(1,coalesce(b.booked_hours,0)/h.available_hours) end
  ) order by f.name),'[]'::jsonb) into utilisation_value
  from facility_scope f left join open_hours h on h.id=f.id left join booked b on b.facility_id=f.id;

  select jsonb_build_object(
    'booked_hours',coalesce(sum((elem->>'booked_hours')::numeric),0),
    'available_hours',coalesce(sum((elem->>'available_hours')::numeric),0),
    'fraction',case when coalesce(sum((elem->>'available_hours')::numeric),0)=0 then 0
      else least(1,coalesce(sum((elem->>'booked_hours')::numeric),0)/sum((elem->>'available_hours')::numeric)) end)
  into summary_value from jsonb_array_elements(utilisation_value) elem;

  select coalesce(jsonb_agg(jsonb_build_object(
    'occurrence_id',o.id,'request_id',r.id,'facility_id',o.facility_id,
    'requester',r.requester_name,'purpose',r.purpose,'request_status',r.status,
    'starts_at',o.starts_at,'ends_at',o.ends_at,
    'booked_hours',round((extract(epoch from(least(o.ends_at,p_to)-greatest(o.starts_at,p_from)))/3600)::numeric,2)
  ) order by o.starts_at,o.id),'[]'::jsonb) into occurrences_value
  from public.reservation_occurrences o join public.reservation_requests r on r.id=o.request_id
  join public.facilities f on f.id=o.facility_id
  where o.booking_state='booked' and o.starts_at<p_to and o.ends_at>p_from
    and not r.held_for_verification and r.payment_status<>'not_required'
    and (p_category is null or f.category=p_category);

  with blocks as (
    select day_number,hour_value from generate_series(1,7) day_number
      cross join generate_series(7,19,2) hour_value
  ), clipped as (
    select o.id,greatest(o.starts_at,p_from) at time zone 'Asia/Manila' local_start,
      least(o.ends_at,p_to) at time zone 'Asia/Manila' local_end
    from public.reservation_occurrences o join public.reservation_requests r on r.id=o.request_id
    join public.facilities f on f.id=o.facility_id
    where o.starts_at<p_to and o.ends_at>p_from and not r.held_for_verification
      and r.payment_status<>'not_required' and (p_category is null or f.category=p_category)
  ), occupied as (
    select distinct o.id,extract(isodow from d)::integer day_number,h.hour_value
    from clipped o cross join lateral generate_series(o.local_start::date,
      (o.local_end-interval '1 microsecond')::date,interval '1 day') d
    cross join lateral generate_series(7,19,2) h(hour_value)
    where o.local_start<d::date+make_interval(hours=>h.hour_value+2)
      and o.local_end>d::date+make_interval(hours=>h.hour_value)
  ), counts as (select day_number,hour_value,count(*)::integer request_count from occupied group by 1,2)
  select jsonb_agg(jsonb_build_object('day',b.day_number,'hour',b.hour_value,
    'count',coalesce(c.request_count,0)) order by b.day_number,b.hour_value)
  into demand_value from blocks b left join counts c using(day_number,hour_value);

  with decisions as (
    select r.*,extract(epoch from(r.decided_at-r.created_at))/3600 latency_hours
    from public.reservation_requests r join public.facilities f on f.id=r.facility_id
    where r.created_at>=p_from and r.created_at<p_to and not r.held_for_verification
      and r.payment_status<>'not_required' and (p_category is null or f.category=p_category)
  ), decided as (select * from decisions where decided_at is not null and latency_hours>=0)
  select jsonb_build_object(
    'declined',(select count(*) from decisions where status='declined'),
    'over_capacity',(select count(*) from decisions where headcount>facility_capacity),
    'expired',(select count(*) from decisions where status='expired'),
    'median_hours',(select percentile_cont(.5) within group(order by latency_hours) from decided),
    'within_48',(select case when count(*)=0 then null else count(*) filter(where latency_hours<=48)::double precision/count(*) end from decided),
    'per_admin','[]'::jsonb) into performance_value;

  return jsonb_build_object('from',p_from,'to',p_to,'category',p_category,'generated_at',now(),
    'summary',summary_value,'utilisation',utilisation_value,'booked_occurrences',occurrences_value,
    'demand',demand_value,'performance',performance_value);
end;
$$;
revoke all on function public.get_external_admin_report(timestamptz,timestamptz,text) from public,anon,authenticated;

alter function public.get_admin_report(timestamptz,timestamptz,text)
rename to get_internal_admin_report;
revoke all on function public.get_internal_admin_report(timestamptz,timestamptz,text)
from public,anon,authenticated;
create function public.get_admin_report(
  p_from timestamptz,p_to timestamptz,p_category text default null
) returns jsonb language plpgsql stable security definer set search_path=public as $$
begin
  if public.is_internal_admin() then
    return public.get_internal_admin_report(p_from,p_to,p_category);
  elsif public.is_external_admin() then
    return public.get_external_admin_report(p_from,p_to,p_category);
  end if;
  raise exception using errcode='42501',message='Administrator access required';
end;
$$;
revoke all on function public.get_admin_report(timestamptz,timestamptz,text)
from public,anon;
grant execute on function public.get_admin_report(timestamptz,timestamptz,text) to authenticated;
