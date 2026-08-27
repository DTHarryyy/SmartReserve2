-- Printable approved facility reservation permits: sequence-backed permit
-- numbers, a random QR verification token that carries no personal or
-- financial data, a frozen snapshot of everything printed on the document,
-- automatic issuance the instant a reservation becomes eligible, and
-- automatic voiding the instant it stops being confirmed.

create table if not exists public.institution_settings (
  id boolean primary key default true check (id),
  institution_name text not null,
  form_code text not null,
  signatory_name text not null,
  signatory_title text not null,
  updated_by uuid references public.profiles(id) on delete set null,
  updated_at timestamptz not null default now()
);

insert into public.institution_settings(
  id, institution_name, form_code, signatory_name, signatory_title
) values (
  true, 'Cagayan State University - Aparri Campus', 'F-UCEO-8001',
  'AUDY R. QUEBRAL, PECE, JD, DPA', 'Campus Executive Officer'
) on conflict (id) do nothing;

alter table public.institution_settings enable row level security;
grant select on public.institution_settings to authenticated;
create policy institution_settings_read
on public.institution_settings for select to authenticated using (true);
grant update on public.institution_settings to authenticated;
create policy institution_settings_update
on public.institution_settings for update to authenticated
using (public.is_internal_admin())
with check (public.is_internal_admin());

create trigger institution_settings_set_updated_at
before update on public.institution_settings
for each row execute procedure public.set_updated_at();

create sequence if not exists public.reservation_permit_seq;

create table if not exists public.reservation_permits (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null references public.reservation_requests(id) on delete cascade,
  permit_number text not null unique,
  version integer not null default 1 check (version > 0),
  status text not null default 'active' check (status in ('active','void','superseded')),
  verification_token text not null unique,
  snapshot jsonb not null,
  content_hash text not null,
  storage_path text unique,
  issued_by uuid references public.profiles(id) on delete set null,
  issued_at timestamptz not null default now(),
  voided_at timestamptz,
  void_reason text,
  unique (request_id, version),
  check ((status = 'void') = (voided_at is not null))
);

create unique index if not exists reservation_permits_one_active_idx
  on public.reservation_permits(request_id) where status = 'active';
create index if not exists reservation_permits_request_idx
  on public.reservation_permits(request_id, version desc);

alter table public.reservation_permits enable row level security;
grant select on public.reservation_permits to authenticated;
create policy reservation_permits_read
on public.reservation_permits for select to authenticated
using (public.can_access_reservation(request_id));

-- Permits are append-only from the client's point of view: rows are only
-- ever written by issue_reservation_permit / void_reservation_permits
-- (both SECURITY DEFINER), never by direct table access.
revoke insert, update, delete on public.reservation_permits from authenticated;

insert into storage.buckets(id, name, public, file_size_limit, allowed_mime_types)
values ('reservation-permits', 'reservation-permits', false, 10485760, array['application/pdf'])
on conflict (id) do update set
  public = false, file_size_limit = 10485760, allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists reservation_permits_storage_insert on storage.objects;
create policy reservation_permits_storage_insert
on storage.objects for insert to authenticated
with check (
  bucket_id = 'reservation-permits'
  and public.can_access_reservation((storage.foldername(name))[2]::uuid)
);

drop policy if exists reservation_permits_storage_read on storage.objects;
create policy reservation_permits_storage_read
on storage.objects for select to authenticated
using (
  bucket_id = 'reservation-permits'
  and public.can_access_reservation((storage.foldername(name))[2]::uuid)
);

-- The eligibility gate. Nothing in the client decides whether a permit may
-- be issued: a down-payment-only renter is refused regardless of what is
-- requested, and re-issuing after a material change (schedule, amounts,
-- approver) supersedes the previous version rather than editing it in place.
create or replace function public.issue_reservation_permit(p_request_id uuid)
returns public.reservation_permits
language plpgsql
security definer
set search_path = public
as $$
declare
  request_row public.reservation_requests%rowtype;
  facility public.facilities%rowtype;
  settings public.institution_settings%rowtype;
  verified_value integer;
  existing public.reservation_permits%rowtype;
  next_version integer;
  material jsonb;
  computed_hash text;
  occurrences_value jsonb;
  amenities_value jsonb;
  requester_type text;
  result public.reservation_permits%rowtype;
  event_id uuid;
begin
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'Sign in required';
  end if;
  select * into request_row from public.reservation_requests where id = p_request_id for update;
  if request_row.id is null then
    raise exception using errcode = 'P0002', message = 'Reservation not found';
  end if;
  if request_row.requester_id <> auth.uid() and not public.can_manage_reservation(p_request_id) then
    raise exception using errcode = '42501', message = 'Reservation access denied';
  end if;
  if request_row.reservation_status <> 'confirmed' then
    raise exception using errcode = '22023',
      message = 'A permit is only available once the reservation is confirmed';
  end if;
  if request_row.total_amount_centavos > 0 then
    select coalesce(sum(amount_centavos), 0) into verified_value
    from public.payment_transactions
    where request_id = p_request_id and status = 'verified' and purpose <> 'refund';
    if verified_value < request_row.total_amount_centavos then
      raise exception using errcode = '22023',
        message = 'The permit is released only once the reservation is fully paid';
    end if;
  else
    verified_value := 0;
  end if;

  select * into facility from public.facilities where id = request_row.facility_id;
  select * into settings from public.institution_settings where id = true;

  select coalesce(jsonb_agg(jsonb_build_object(
    'starts_at', o.starts_at, 'ends_at', o.ends_at
  ) order by o.starts_at), '[]'::jsonb)
  into occurrences_value
  from public.reservation_occurrences o
  where o.request_id = p_request_id and o.booking_state in ('held', 'booked', 'checked_in');

  select coalesce(jsonb_agg(a.name_snapshot order by a.name_snapshot), to_jsonb(request_row.amenities))
  into amenities_value
  from public.reservation_amenities a
  where a.request_id = p_request_id;

  requester_type := case request_row.payment_exemption
    when 'verified_student' then 'Verified Student'
    when 'verified_faculty' then 'Verified Faculty'
    else 'External Renter'
  end;

  material := jsonb_build_object(
    'reservation_id', request_row.id,
    'facility_name', request_row.facility_name,
    'facility_building', request_row.facility_building,
    'facility_room', request_row.facility_room,
    'requester_name', request_row.requester_name,
    'requester_type', requester_type,
    'office', request_row.requester_unit,
    'purpose', request_row.purpose,
    'headcount', request_row.headcount,
    'occurrences', occurrences_value,
    'amenities', amenities_value,
    'payment_exemption', request_row.payment_exemption,
    'payment_required', request_row.total_amount_centavos > 0,
    'total_amount_centavos', request_row.total_amount_centavos,
    'amount_paid_centavos', verified_value,
    'remaining_balance_centavos', greatest(0, request_row.total_amount_centavos - verified_value),
    'approved_by_name', request_row.decided_by_name,
    'approved_by_role', request_row.requester_role,
    'approved_at', request_row.decided_at
  );
  computed_hash := encode(extensions.digest(material::text, 'sha256'), 'hex');

  select * into existing from public.reservation_permits
  where request_id = p_request_id and status = 'active';
  if existing.id is not null then
    if existing.content_hash = computed_hash then
      return existing;
    end if;
    update public.reservation_permits
    set status = 'superseded'
    where id = existing.id;
  end if;

  select coalesce(max(version), 0) + 1 into next_version
  from public.reservation_permits where request_id = p_request_id;

  insert into public.reservation_permits(
    request_id, permit_number, version, verification_token, snapshot,
    content_hash, issued_by
  ) values (
    p_request_id,
    'SR-' || to_char(now() at time zone 'Asia/Manila', 'YYYY') || '-'
      || lpad(nextval('public.reservation_permit_seq')::text, 6, '0'),
    next_version,
    encode(extensions.gen_random_bytes(16), 'hex'),
    material || jsonb_build_object(
      'institution_name', settings.institution_name,
      'form_code', settings.form_code,
      'signatory_name', settings.signatory_name,
      'signatory_title', settings.signatory_title,
      'facility_location', trim(both ' · ' from
        concat_ws(' · ', nullif(request_row.facility_building, ''), nullif(request_row.facility_room, ''))
      )
    ),
    computed_hash,
    auth.uid()
  ) returning * into result;

  update public.reservation_permits
  set snapshot = snapshot || jsonb_build_object(
    'permit_number', result.permit_number, 'version', result.version,
    'issued_at', result.issued_at, 'verification_token', result.verification_token
  )
  where id = result.id
  returning * into result;

  event_id := public.reservation_event(
    p_request_id, 'issued reservation permit', null,
    jsonb_build_object('permit_id', result.id, 'permit_number', result.permit_number), null, true
  );
  perform public.notify_reservation_user(
    p_request_id, event_id, 'permit_available', 'Your reservation permit is ready',
    'Your reservation has been confirmed and your approved facility reservation permit ' ||
    result.permit_number || ' is now available. Please download and print the document ' ||
    'and bring the printed copy when you arrive at the facility.'
  );
  return result;
end;
$$;

revoke all on function public.issue_reservation_permit(uuid) from public, anon;
grant execute on function public.issue_reservation_permit(uuid) to authenticated;

create or replace function public.void_reservation_permits(p_request_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  voided_permit public.reservation_permits%rowtype;
begin
  update public.reservation_permits
  set status = 'void', voided_at = now(), void_reason = coalesce(nullif(trim(p_reason), ''), 'Reservation is no longer confirmed')
  where request_id = p_request_id and status = 'active'
  returning * into voided_permit;
  if voided_permit.id is not null then
    perform public.reservation_event(
      p_request_id, 'voided reservation permit', p_reason,
      jsonb_build_object('permit_id', voided_permit.id, 'permit_number', voided_permit.permit_number),
      null, true
    );
    perform public.notify_reservation_user(
      p_request_id, null, 'permit_voided', 'Reservation permit voided',
      'Permit ' || voided_permit.permit_number || ' is no longer valid because the reservation was cancelled.'
    );
  end if;
end;
$$;

revoke all on function public.void_reservation_permits(uuid, text) from public, anon, authenticated;

-- Belt-and-braces: whichever code path moves a reservation into a terminal,
-- non-confirmed state, this trigger voids any active permit. Defense in
-- depth against a future write path that forgets to call
-- void_reservation_permits explicitly.
create or replace function public.auto_void_reservation_permit()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.reservation_status in ('declined', 'cancelled', 'expired')
     and old.reservation_status is distinct from new.reservation_status then
    perform public.void_reservation_permits(new.id, new.decision_reason);
  end if;
  return null;
end;
$$;

drop trigger if exists reservation_requests_auto_void_permit on public.reservation_requests;
create trigger reservation_requests_auto_void_permit
after update of reservation_status on public.reservation_requests
for each row execute procedure public.auto_void_reservation_permit();

-- Auto-issue at the two points a reservation can newly become eligible: the
-- payment-exempt approval path, and a payment being verified (whether that
-- verification completes the down payment on a fully-covering single
-- payment, or completes the remaining balance on an already-confirmed
-- reservation).
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
    perform public.issue_reservation_permit(p_request_id);
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
    balance_due_at=first_start-make_interval(mins=>facility.balance_due_lead_minutes)
  where id=p_request_id;
end;
$$;

revoke all on function public.apply_reservation_payment_gate(uuid)
  from public, anon, authenticated;

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
  current_status text;
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
    select reservation_status into current_status
    from public.reservation_requests where id=request_row.id;
    if current_status='confirmed' and verified_value>=request_row.total_amount_centavos
        and request_row.total_amount_centavos>0 then
      perform public.issue_reservation_permit(request_row.id);
    end if;
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

revoke all on function public.decide_payment(uuid,text,text) from public,anon;
grant execute on function public.decide_payment(uuid,text,text) to authenticated;

-- Callable without a session, so facility staff can verify a printed permit
-- at the door with nothing more than the QR's token. The response is a
-- fixed whitelist -- no amounts, no reference numbers, no email, no user id.
-- Unknown, void, and superseded tokens all return the same shape with a
-- short delay, so the endpoint cannot be used to enumerate valid tokens.
create or replace function public.verify_permit(p_token text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  permit_row public.reservation_permits%rowtype;
  request_row public.reservation_requests%rowtype;
begin
  if p_token is null or length(trim(p_token)) <> 32 then
    perform pg_sleep(0.4);
    return jsonb_build_object('valid', false);
  end if;
  select * into permit_row from public.reservation_permits
  where verification_token = trim(p_token);
  if permit_row.id is null then
    perform pg_sleep(0.4);
    return jsonb_build_object('valid', false);
  end if;
  select * into request_row from public.reservation_requests where id = permit_row.request_id;
  return jsonb_build_object(
    'valid', permit_row.status = 'active',
    'permit_number', permit_row.permit_number,
    'permit_status', permit_row.status,
    'reservation_status', request_row.reservation_status,
    'facility', request_row.facility_name,
    'location', permit_row.snapshot->>'facility_location',
    'schedule', permit_row.snapshot->'occurrences',
    'requester_name', request_row.requester_name,
    'requester_type', permit_row.snapshot->>'requester_type',
    'office', request_row.requester_unit,
    'payment_cleared', request_row.total_amount_centavos = 0
      or (permit_row.snapshot->>'remaining_balance_centavos')::integer = 0
  );
end;
$$;

revoke all on function public.verify_permit(text) from public;
grant execute on function public.verify_permit(text) to anon, authenticated;

notify pgrst, 'reload schema';
