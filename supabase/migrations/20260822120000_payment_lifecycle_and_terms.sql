-- Payment-aware reservation lifecycle. The existing status column remains as
-- the approval compatibility layer; reservation_status is the authoritative
-- operational lifecycle during the rolling client migration.

alter table public.facilities
  add column if not exists payment_correction_window_minutes integer not null default 1440
    check (payment_correction_window_minutes between 30 and 10080);

create table if not exists public.facility_payment_methods (
  id uuid primary key default gen_random_uuid(),
  facility_id uuid not null references public.facilities(id) on delete cascade,
  method_type text not null default 'gcash' check (method_type in ('gcash')),
  account_name text not null check (length(trim(account_name)) between 2 and 120),
  account_number text not null check (length(regexp_replace(account_number,'[^0-9]','','g')) between 10 and 15),
  instructions text not null default '',
  enabled boolean not null default true,
  created_by uuid references public.profiles(id) on delete set null,
  updated_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index if not exists facility_payment_methods_active_gcash_idx
  on public.facility_payment_methods(facility_id, method_type) where enabled;
create index if not exists facility_payment_methods_facility_idx
  on public.facility_payment_methods(facility_id, enabled);

drop trigger if exists facility_payment_methods_set_actor on public.facility_payment_methods;
create trigger facility_payment_methods_set_actor
before insert or update on public.facility_payment_methods
for each row execute procedure public.set_scoped_facility_actor();

alter table public.facility_payment_methods enable row level security;
grant select, insert, update, delete on public.facility_payment_methods to authenticated;

create policy facility_payment_methods_read
on public.facility_payment_methods for select to authenticated
using (
  public.can_manage_facility(facility_id)
  or (enabled and exists (
    select 1 from public.facilities f
    where f.id = facility_id and f.archived_at is null and f.public_listing
  ))
);
create policy facility_payment_methods_insert
on public.facility_payment_methods for insert to authenticated
with check (public.can_manage_facility(facility_id));
create policy facility_payment_methods_update
on public.facility_payment_methods for update to authenticated
using (public.can_manage_facility(facility_id))
with check (public.can_manage_facility(facility_id));
create policy facility_payment_methods_delete
on public.facility_payment_methods for delete to authenticated
using (public.can_manage_facility(facility_id));

alter table public.reservation_requests
  add column if not exists reservation_status text,
  add column if not exists payment_method_id uuid references public.facility_payment_methods(id) on delete restrict,
  add column if not exists payment_due_at timestamptz,
  add column if not exists balance_due_at timestamptz;

create policy facility_payment_methods_reservation_read
on public.facility_payment_methods for select to authenticated
using (exists (
  select 1 from public.reservation_requests r
  where r.payment_method_id = facility_payment_methods.id
    and (r.requester_id = auth.uid() or public.can_manage_reservation(r.id))
));

create or replace function public.protect_referenced_payment_method()
returns trigger language plpgsql set search_path = public as $$
begin
  if exists(select 1 from public.reservation_requests r
      where r.payment_method_id = old.id)
      and (new.facility_id is distinct from old.facility_id
        or new.method_type is distinct from old.method_type
        or new.account_name is distinct from old.account_name
        or new.account_number is distinct from old.account_number
        or new.instructions is distinct from old.instructions) then
    raise exception using errcode = '22023',
      message = 'Payment instructions used by a reservation are immutable';
  end if;
  return new;
end;
$$;

drop trigger if exists facility_payment_methods_protect_referenced
  on public.facility_payment_methods;
create trigger facility_payment_methods_protect_referenced
before update on public.facility_payment_methods
for each row execute function public.protect_referenced_payment_method();

update public.reservation_requests
set reservation_status = case status
  when 'pending' then 'pending_approval'
  when 'approved' then 'confirmed'
  when 'changes_requested' then 'changes_requested'
  when 'declined' then 'declined'
  when 'cancelled' then 'cancelled'
  when 'expired' then 'expired'
  else 'pending_approval'
end
where reservation_status is null;

alter table public.reservation_requests
  alter column reservation_status set not null,
  alter column reservation_status set default 'pending_approval',
  add constraint reservation_requests_lifecycle_status_check check (
    reservation_status in (
      'pending_approval','changes_requested','awaiting_payment','confirmed',
      'declined','cancelled','expired','completed'
    )
  );

create index if not exists reservation_requests_lifecycle_deadline_idx
  on public.reservation_requests(reservation_status, payment_due_at, balance_due_at);

alter table public.reservation_occurrences
  drop constraint if exists reservation_occurrences_booking_state_check;
alter table public.reservation_occurrences
  add constraint reservation_occurrences_booking_state_check
  check (booking_state in ('requested','held','booked','changes_requested','cancelled','expired','bumped'));

alter table public.reservation_occurrences
  drop constraint if exists reservation_occurrences_no_overlap;
alter table public.reservation_occurrences
  add constraint reservation_occurrences_no_overlap
  exclude using gist (facility_id with =, blocked_window with &&)
  where (booking_state in ('held','booked'));

create table if not exists public.payment_transactions (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null references public.reservation_requests(id) on delete restrict,
  payer_id uuid not null references public.profiles(id) on delete restrict,
  payment_method_id uuid not null references public.facility_payment_methods(id) on delete restrict,
  purpose text not null check (purpose in ('down_payment','balance','adjustment','refund')),
  amount_centavos integer not null check (amount_centavos > 0),
  currency text not null default 'PHP' check (currency = 'PHP'),
  reference_number text not null check (length(trim(reference_number)) between 6 and 80),
  proof_path text not null unique,
  status text not null default 'submitted'
    check (status in ('submitted','verified','rejected','voided','refunded')),
  submitted_at timestamptz not null default now(),
  verified_by uuid references public.profiles(id) on delete set null,
  verified_at timestamptz,
  rejection_reason text,
  idempotency_key uuid not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (payer_id, idempotency_key),
  check (
    (status = 'verified' and verified_by is not null and verified_at is not null and rejection_reason is null)
    or (status = 'rejected' and verified_by is not null and verified_at is not null and length(trim(rejection_reason)) >= 3)
    or status in ('submitted','voided','refunded')
  )
);

create unique index if not exists payment_transactions_active_reference_idx
  on public.payment_transactions(lower(regexp_replace(reference_number,'\s','','g')))
  where status in ('submitted','verified');
create index if not exists payment_transactions_request_idx
  on public.payment_transactions(request_id, submitted_at desc);
create index if not exists payment_transactions_review_idx
  on public.payment_transactions(status, submitted_at) where status = 'submitted';

create or replace function public.protect_verified_payment()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.updated_at = now();
  if old.status in ('verified','refunded') and (
    new.status is distinct from old.status
    or new.request_id is distinct from old.request_id
    or new.payer_id is distinct from old.payer_id
    or new.payment_method_id is distinct from old.payment_method_id
    or new.purpose is distinct from old.purpose
    or new.amount_centavos is distinct from old.amount_centavos
    or new.reference_number is distinct from old.reference_number
    or new.proof_path is distinct from old.proof_path
  ) then
    raise exception using errcode='22023',message='Verified payment details are immutable';
  end if;
  return new;
end;
$$;

drop trigger if exists payment_transactions_protect on public.payment_transactions;
create trigger payment_transactions_protect
before update on public.payment_transactions
for each row execute procedure public.protect_verified_payment();

alter table public.payment_transactions enable row level security;
grant select on public.payment_transactions to authenticated;
create policy payment_transactions_read
on public.payment_transactions for select to authenticated
using (payer_id = auth.uid() or public.can_manage_reservation(request_id));

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values(
  'payment-proofs','payment-proofs',false,10485760,
  array['image/jpeg','image/png','application/pdf']
)
on conflict(id) do update set
  public=false,file_size_limit=10485760,allowed_mime_types=excluded.allowed_mime_types;

drop policy if exists payment_proofs_insert_own on storage.objects;
create policy payment_proofs_insert_own
on storage.objects for insert to authenticated
with check (
  bucket_id='payment-proofs'
  and (storage.foldername(name))[1]=auth.uid()::text
);

drop policy if exists payment_proofs_read on storage.objects;
create policy payment_proofs_read
on storage.objects for select to authenticated
using (
  bucket_id='payment-proofs' and (
    (storage.foldername(name))[1]=auth.uid()::text
    or exists (
      select 1 from public.payment_transactions p
      where p.proof_path=storage.objects.name
        and public.can_manage_reservation(p.request_id)
    )
  )
);

drop policy if exists payment_proofs_delete_unsubmitted on storage.objects;
create policy payment_proofs_delete_unsubmitted
on storage.objects for delete to authenticated
using (
  bucket_id='payment-proofs'
  and (storage.foldername(name))[1]=auth.uid()::text
  and not exists (
    select 1 from public.payment_transactions p
    where p.proof_path=storage.objects.name
  )
);

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
  status_value text;
begin
  select * into request_row from public.reservation_requests where id=p_request_id;
  if request_row.id is null or not public.can_access_reservation(p_request_id) then
    raise exception using errcode='42501',message='Reservation access denied';
  end if;
  select coalesce(sum(amount_centavos) filter(where status='verified' and purpose<>'refund'),0),
         coalesce(sum(amount_centavos) filter(where status='submitted'),0)
  into verified_value,submitted_value
  from public.payment_transactions where request_id=p_request_id;
  status_value := case
    when request_row.total_amount_centavos=0 then 'not_required'
    when verified_value>=request_row.total_amount_centavos then 'fully_paid'
    when verified_value>=request_row.required_down_payment_centavos then 'down_payment_verified'
    when submitted_value>0 then 'submitted'
    when verified_value>0 then 'partially_paid'
    else 'unpaid' end;
  return jsonb_build_object(
    'status',status_value,'total_amount_centavos',request_row.total_amount_centavos,
    'required_down_payment_centavos',request_row.required_down_payment_centavos,
    'verified_amount_centavos',verified_value,'submitted_amount_centavos',submitted_value,
    'outstanding_amount_centavos',greatest(0,request_row.total_amount_centavos-verified_value),
    'payment_due_at',request_row.payment_due_at,'balance_due_at',request_row.balance_due_at
  );
end;
$$;

revoke all on function public.reservation_payment_summary(uuid) from public,anon;
grant execute on function public.reservation_payment_summary(uuid) to authenticated;

create or replace function public.lock_reservation_admin_scope(p_request_id uuid)
returns boolean
language plpgsql
volatile
security definer
set search_path = public
as $$
begin
  perform 1
  from public.reservation_requests r
  join public.facility_admin_assignments a
    on a.facility_id = r.facility_id and a.admin_id = auth.uid()
  join public.profiles p on p.id = a.admin_id
  where r.id = p_request_id
    and p.account_status = 'active'
    and p.role = case r.admin_lane
      when 'internal' then 'internal_admin' else 'external_admin' end
  for share of a, p;
  return found;
end;
$$;

revoke all on function public.lock_reservation_admin_scope(uuid) from public, anon;
grant execute on function public.lock_reservation_admin_scope(uuid) to authenticated;

-- Apply the payment gate after the legacy approval implementation has made
-- its conflict-safe occurrence decision and journal entry.
create or replace function public.apply_reservation_payment_gate(p_request_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  request_row public.reservation_requests%rowtype;
  facility public.facilities%rowtype;
  method_id uuid;
  first_start timestamptz;
begin
  select * into request_row from public.reservation_requests where id=p_request_id for update;
  if request_row.id is null then raise exception using errcode='P0002',message='Reservation not found'; end if;
  if not public.lock_reservation_admin_scope(p_request_id)
      and request_row.requester_id <> auth.uid() then
    raise exception using errcode='42501',message='Reservation access denied';
  end if;
  select * into facility from public.facilities where id=request_row.facility_id;
  select min(starts_at) into first_start from public.reservation_occurrences
    where request_id=p_request_id and booking_state='booked';
  if request_row.total_amount_centavos=0 then
    update public.reservation_requests
      set reservation_status='confirmed',payment_due_at=null,balance_due_at=null
      where id=p_request_id;
    return;
  end if;
  select id into method_id from public.facility_payment_methods
  where facility_id=request_row.facility_id and enabled and method_type='gcash'
  order by updated_at desc limit 1;
  if method_id is null then
    raise exception using errcode='22023',message='Configure an active GCash payment method before approving paid reservations';
  end if;
  update public.reservation_occurrences set booking_state='held'
  where request_id=p_request_id and booking_state='booked';
  update public.reservation_requests set
    reservation_status='awaiting_payment',payment_method_id=method_id,
    payment_due_at=now()+make_interval(mins=>facility.deposit_window_minutes),
    balance_due_at=first_start-make_interval(days=>facility.balance_due_lead_days)
  where id=p_request_id;
end;
$$;

revoke all on function public.apply_reservation_payment_gate(uuid)
  from public, anon, authenticated;

create or replace function public.reservation_action(
  p_request_id uuid,p_action text,p_reason text default null,
  p_payload jsonb default '{}'::jsonb,p_expected_version integer default null,
  p_idempotency_key uuid default gen_random_uuid()
) returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare result jsonb;
begin
  if p_action in (
    'approve','approve_partial','approve_bump','decline','request_changes',
    'offer_alternative','reopen','expire','check_in','complete','no_show'
  ) and not public.lock_reservation_admin_scope(p_request_id) then
    raise exception using errcode='42501',message='Reservation access denied';
  end if;
  if p_action in ('cancel','accept_alternative','resubmit') and not (
    public.lock_reservation_admin_scope(p_request_id) or exists(
      select 1 from public.reservation_requests where id=p_request_id and requester_id=auth.uid()
    )
  ) then raise exception using errcode='42501',message='Reservation access denied'; end if;
  if p_action='reopen' then
    raise exception using errcode='22023',message='Declined and terminal reservations cannot be reopened';
  end if;
  if p_action in ('check_in','complete','no_show') and not exists(
    select 1 from public.reservation_requests
    where id=p_request_id and reservation_status='confirmed'
  ) then
    raise exception using errcode='22023',message='Only a confirmed reservation can enter facility use';
  end if;
  result:=public.reservation_action_unscoped(
    p_request_id,p_action,p_reason,p_payload,p_expected_version,p_idempotency_key);
  if p_action in ('approve','approve_partial','accept_alternative') then
    perform public.apply_reservation_payment_gate(p_request_id);
  elsif p_action in ('request_changes','offer_alternative') then
    update public.reservation_requests set reservation_status='changes_requested' where id=p_request_id;
  elsif p_action='decline' then
    update public.reservation_requests set reservation_status='declined' where id=p_request_id;
  elsif p_action='reopen' then
    update public.reservation_requests set reservation_status='pending_approval' where id=p_request_id;
  elsif p_action='expire' then
    update public.reservation_requests set reservation_status='expired' where id=p_request_id;
  elsif p_action='cancel' then
    if exists(select 1 from public.reservation_occurrences
      where request_id=p_request_id
        and booking_state in ('requested','held','booked','changes_requested')) then
      update public.reservation_requests
      set status=case when reservation_status in ('awaiting_payment','confirmed')
        then 'approved' else 'pending' end
      where id=p_request_id;
    else
      update public.reservation_requests set reservation_status='cancelled' where id=p_request_id;
    end if;
  elsif p_action in ('complete','no_show') and not exists(
    select 1 from public.reservation_occurrences
    where request_id=p_request_id and lifecycle_stage not in ('completed','no_show')
  ) then
    update public.reservation_requests set reservation_status='completed' where id=p_request_id;
  end if;
  return result;
end;
$$;

create or replace function public.approve_and_bump_reservation(
  p_request_id uuid,p_reason text,p_expected_version integer,p_idempotency_key uuid
) returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare result jsonb; conflict_request_id uuid;
begin
  if not public.lock_reservation_admin_scope(p_request_id) then
    raise exception using errcode='42501',message='Reservation access denied';
  end if;
  for conflict_request_id in
    select distinct other.request_id
    from public.reservation_occurrences wanted
    join public.reservation_occurrences other
      on other.facility_id = wanted.facility_id
      and other.booking_state = 'booked'
      and other.blocked_window && wanted.blocked_window
      and other.request_id <> wanted.request_id
    where wanted.request_id = p_request_id
  loop
    if not public.lock_reservation_admin_scope(conflict_request_id) then
      raise exception using errcode='42501',
        message='A conflicting booking belongs to another administrator lane and cannot be bumped';
    end if;
  end loop;
  result:=public.approve_and_bump_reservation_unscoped(
    p_request_id,p_reason,p_expected_version,p_idempotency_key);
  perform public.apply_reservation_payment_gate(p_request_id);
  return result;
end;
$$;

alter function public.resubmit_reservation(
  uuid,text,integer,uuid,timestamptz,timestamptz,integer,uuid
) rename to resubmit_reservation_legacy;

create function public.resubmit_reservation(
  p_request_id uuid,p_purpose text,p_headcount integer,p_occurrence_id uuid,
  p_starts_at timestamptz,p_ends_at timestamptz,p_expected_version integer,
  p_idempotency_key uuid
) returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare result jsonb;
begin
  result:=public.resubmit_reservation_legacy(
    p_request_id,p_purpose,p_headcount,p_occurrence_id,p_starts_at,p_ends_at,
    p_expected_version,p_idempotency_key);
  update public.reservation_requests set reservation_status='pending_approval'
  where id=p_request_id and requester_id=auth.uid();
  return result;
end;
$$;

revoke all on function public.reservation_action(uuid,text,text,jsonb,integer,uuid) from public,anon;
revoke all on function public.approve_and_bump_reservation(uuid,text,integer,uuid) from public,anon;
revoke all on function public.resubmit_reservation(uuid,text,integer,uuid,timestamptz,timestamptz,integer,uuid) from public,anon;
grant execute on function public.reservation_action(uuid,text,text,jsonb,integer,uuid) to authenticated;
grant execute on function public.approve_and_bump_reservation(uuid,text,integer,uuid) to authenticated;
grant execute on function public.resubmit_reservation(uuid,text,integer,uuid,timestamptz,timestamptz,integer,uuid) to authenticated;

create or replace function public.undo_reservation_action(p_action_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  journal public.reservation_action_journal%rowtype;
  item jsonb;
  snapshot public.reservation_requests%rowtype;
  occurrence public.reservation_occurrences%rowtype;
  request_id_value uuid;
begin
  select * into journal from public.reservation_action_journal
  where id = p_action_id for update;
  if journal.id is null or journal.actor_id <> auth.uid() then
    raise exception using errcode='42501',message='Undo is not available';
  end if;
  if journal.undone_at is not null or now() > journal.undo_until then
    raise exception using errcode='22023',message='The undo window has ended';
  end if;
  foreach request_id_value in array journal.request_ids loop
    if not public.lock_reservation_admin_scope(request_id_value) then
      raise exception using errcode='42501',message='Reservation access denied';
    end if;
    if exists(select 1 from public.payment_transactions p
      where p.request_id = request_id_value
        and p.status in ('submitted','verified','refunded')) then
      raise exception using errcode='22023',
        message='An action with payment activity cannot be undone';
    end if;
  end loop;
  for item in select value from jsonb_array_elements(journal.before_requests) loop
    snapshot := jsonb_populate_record(null::public.reservation_requests, item);
    update public.reservation_requests set
      status = snapshot.status,
      reservation_status = snapshot.reservation_status,
      held_for_verification = snapshot.held_for_verification,
      decision_reason = snapshot.decision_reason,
      decided_by = snapshot.decided_by,
      decided_by_name = snapshot.decided_by_name,
      decided_at = snapshot.decided_at,
      payment_status = snapshot.payment_status,
      payment_method_id = snapshot.payment_method_id,
      payment_due_at = snapshot.payment_due_at,
      balance_due_at = snapshot.balance_due_at
    where id = snapshot.id;
  end loop;
  delete from public.reservation_occurrences
  where request_id = any(journal.request_ids);
  for item in select value from jsonb_array_elements(journal.before_occurrences) loop
    occurrence := jsonb_populate_record(null::public.reservation_occurrences, item);
    insert into public.reservation_occurrences(
      id,request_id,facility_id,starts_at,ends_at,buffer_minutes,
      booking_state,lifecycle_stage,proposed_starts_at,proposed_ends_at,
      exception_reason,created_at,updated_at
    ) values (
      occurrence.id,occurrence.request_id,occurrence.facility_id,
      occurrence.starts_at,occurrence.ends_at,occurrence.buffer_minutes,
      occurrence.booking_state,occurrence.lifecycle_stage,
      occurrence.proposed_starts_at,occurrence.proposed_ends_at,
      occurrence.exception_reason,occurrence.created_at,now()
    );
  end loop;
  update public.reservation_action_journal set undone_at = now()
  where id = journal.id;
  perform public.reservation_event(
    journal.request_ids[1], 'undid ' || replace(journal.action,'_',' '),
    null, jsonb_build_object('action_id',journal.id)
  );
  return jsonb_build_object('ok',true);
end;
$$;

revoke all on function public.undo_reservation_action(uuid) from public, anon;
grant execute on function public.undo_reservation_action(uuid) to authenticated;

create or replace function public.submit_payment(
  p_transaction_id uuid,p_request_id uuid,p_purpose text,p_amount_centavos integer,
  p_reference_number text,p_proof_path text,p_idempotency_key uuid
) returns public.payment_transactions
language plpgsql
security definer
set search_path=public,storage
as $$
declare
  request_row public.reservation_requests%rowtype;
  result public.payment_transactions%rowtype;
  committed_value integer;
  event_id uuid;
begin
  select * into request_row from public.reservation_requests where id=p_request_id for update;
  if request_row.id is null or request_row.requester_id<>auth.uid() then
    raise exception using errcode='42501',message='Reservation access denied';
  end if;
  if request_row.reservation_status not in ('awaiting_payment','confirmed') then
    raise exception using errcode='22023',message='This reservation is not accepting payments';
  end if;
  if p_purpose not in ('down_payment','balance') or p_amount_centavos<=0 then
    raise exception using errcode='22023',message='Provide a valid payment amount and purpose';
  end if;
  if request_row.payment_method_id is null then
    raise exception using errcode='22023',message='No payment method is configured for this reservation';
  end if;
  if length(trim(p_reference_number))<6 then
    raise exception using errcode='22023',message='Provide the GCash reference number';
  end if;
  if p_proof_path not like auth.uid()::text||'/'||p_request_id::text||'/%' then
    raise exception using errcode='42501',message='Invalid payment proof path';
  end if;
  select coalesce(sum(amount_centavos),0) into committed_value
  from public.payment_transactions
  where request_id=p_request_id and status in ('submitted','verified');
  if p_amount_centavos>request_row.total_amount_centavos-committed_value then
    raise exception using errcode='22023',message='Payment is greater than the outstanding balance';
  end if;
  insert into public.payment_transactions(
    id,request_id,payer_id,payment_method_id,purpose,amount_centavos,
    reference_number,proof_path,idempotency_key
  ) values (
    p_transaction_id,p_request_id,auth.uid(),request_row.payment_method_id,
    p_purpose,p_amount_centavos,trim(p_reference_number),p_proof_path,p_idempotency_key
  ) returning * into result;
  event_id:=public.reservation_event(p_request_id,'submitted payment proof',null,
    jsonb_build_object('payment_id',result.id,'purpose',result.purpose,
      'amount_centavos',result.amount_centavos),null,true);
  insert into public.app_notifications(recipient_id,request_id,event_id,kind,title,body)
  select a.admin_id,p_request_id,event_id,'payment_submitted','Payment needs review',
    request_row.requester_name||' submitted GCash payment proof.'
  from public.facility_admin_assignments a
  join public.profiles p on p.id=a.admin_id and p.account_status='active'
  where a.facility_id=request_row.facility_id
    and p.role=case request_row.admin_lane when 'internal' then 'internal_admin' else 'external_admin' end;
  return result;
exception when unique_violation then
  raise exception using errcode='23505',message='That payment reference or submission was already used';
end;
$$;

create or replace function public.decide_payment(
  p_payment_id uuid,p_decision text,p_reason text default null
) returns public.payment_transactions
language plpgsql
security definer
set search_path=public
as $$
declare
  payment_row public.payment_transactions%rowtype;
  request_row public.reservation_requests%rowtype;
  result public.payment_transactions%rowtype;
  verified_value integer;
  amount_due_now integer;
  event_id uuid;
begin
  select * into payment_row from public.payment_transactions where id=p_payment_id for update;
  if payment_row.id is null then raise exception using errcode='P0002',message='Payment not found'; end if;
  select * into request_row from public.reservation_requests where id=payment_row.request_id for update;
  if not public.lock_reservation_admin_scope(request_row.id) then
    raise exception using errcode='42501',message='Payment review access denied';
  end if;
  if request_row.reservation_status not in ('awaiting_payment','confirmed') then
    raise exception using errcode='22023',message='This reservation is no longer accepting payment decisions';
  end if;
  if payment_row.status<>'submitted' then
    raise exception using errcode='22023',message='This payment has already been reviewed';
  end if;
  if p_decision='reject' then
    if length(trim(coalesce(p_reason,'')))<3 then
      raise exception using errcode='22023',message='A rejection reason is required';
    end if;
    update public.payment_transactions set status='rejected',verified_by=auth.uid(),
      verified_at=now(),rejection_reason=trim(p_reason)
    where id=p_payment_id returning * into result;
    update public.reservation_requests set
      payment_due_at=greatest(
        coalesce(payment_due_at,now()),
        now()+make_interval(mins=>(select f.payment_correction_window_minutes
          from public.facilities f where f.id=request_row.facility_id))
      )
    where id=request_row.id and reservation_status='awaiting_payment';
    event_id:=public.reservation_event(request_row.id,'rejected payment',trim(p_reason),
      jsonb_build_object('payment_id',payment_row.id),null,true);
  elsif p_decision='verify' then
    update public.payment_transactions set status='verified',verified_by=auth.uid(),
      verified_at=now(),rejection_reason=null
    where id=p_payment_id returning * into result;
    select coalesce(sum(amount_centavos),0) into verified_value
    from public.payment_transactions where request_id=request_row.id and status='verified';
    amount_due_now:=case when request_row.balance_due_at is not null and request_row.balance_due_at<=now()
      then request_row.total_amount_centavos else request_row.required_down_payment_centavos end;
    if request_row.reservation_status='awaiting_payment' and verified_value>=amount_due_now then
      update public.reservation_occurrences set booking_state='booked'
      where request_id=request_row.id and booking_state='held';
      update public.reservation_requests set reservation_status='confirmed',payment_due_at=null
      where id=request_row.id;
    end if;
    event_id:=public.reservation_event(request_row.id,'verified payment',null,
      jsonb_build_object('payment_id',payment_row.id,'amount_centavos',payment_row.amount_centavos,
        'verified_total_centavos',verified_value),null,true);
  else
    raise exception using errcode='22023',message='Decision must be verify or reject';
  end if;
  perform public.notify_reservation_user(request_row.id,event_id,'payment_'||p_decision,
    case p_decision when 'verify' then 'Payment verified' else 'Payment needs correction' end,
    coalesce(nullif(trim(p_reason),''),'Your GCash payment was verified.'));
  return result;
exception when exclusion_violation then
  raise exception using errcode='23P01',message='The held schedule is no longer available';
end;
$$;

revoke all on function public.submit_payment(uuid,uuid,text,integer,text,text,uuid) from public,anon;
revoke all on function public.decide_payment(uuid,text,text) from public,anon;
grant execute on function public.submit_payment(uuid,uuid,text,integer,text,text,uuid) to authenticated;
grant execute on function public.decide_payment(uuid,text,text) to authenticated;

create or replace function public.expire_due_reservations(p_dry_run boolean default false)
returns table(request_id uuid,reason text)
language plpgsql
security definer
set search_path=public
as $$
declare row record;
begin
  for row in
    select r.id,
      case when r.reservation_status='awaiting_payment' then 'Down payment deadline missed'
           else 'Remaining balance deadline missed' end reason_value
    from public.reservation_requests r
    where not r.legacy_financial_state and (
      (r.reservation_status='awaiting_payment' and r.payment_due_at<now()
       and not exists(select 1 from public.payment_transactions p where p.request_id=r.id and p.status='submitted'))
      or
      (r.reservation_status='confirmed' and r.total_amount_centavos>0
       and r.balance_due_at<now()
       and not exists(select 1 from public.payment_transactions p
         where p.request_id=r.id and p.status='submitted')
       and (select coalesce(sum(p.amount_centavos),0) from public.payment_transactions p
            where p.request_id=r.id and p.status='verified')<r.total_amount_centavos)
    )
    order by r.id for update
  loop
    request_id:=row.id; reason:=row.reason_value;
    if not p_dry_run then
      update public.reservation_occurrences set booking_state='expired',exception_reason=reason
      where request_id=row.id and booking_state in ('held','booked');
      update public.reservation_requests set reservation_status='expired',status='expired',
        decision_reason=reason,decided_at=now()
      where id=row.id;
      perform public.reservation_event(row.id,'expired automatically',reason,'{}'::jsonb,null,true);
    end if;
    return next;
  end loop;
end;
$$;

revoke all on function public.expire_due_reservations(boolean) from public,anon,authenticated;
grant execute on function public.expire_due_reservations(boolean) to service_role;

create extension if not exists pg_cron;
do $$
begin
  if not exists(select 1 from cron.job where jobname='smartreserve-expire-payments') then
    perform cron.schedule(
      'smartreserve-expire-payments','*/5 * * * *',
      'select public.expire_due_reservations(false);'
    );
  end if;
end $$;

notify pgrst, 'reload schema';
