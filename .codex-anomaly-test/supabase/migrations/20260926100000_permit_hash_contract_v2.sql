-- Permit signatures bind to printable reservation content, not to the
-- optimistic-concurrency version of the reservation row. The old hash
-- included reservation_requests.version, so a check-in/payment-status update
-- could make an otherwise unchanged signature appear stale.

begin;

alter table public.reservation_signature_requests
  add column if not exists hash_version integer not null default 1;
alter table public.reservation_user_signatures
  add column if not exists hash_version integer not null default 1;
alter table public.reservation_permits
  add column if not exists hash_version integer not null default 1;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'reservation_signature_requests_hash_version_check'
  ) then
    alter table public.reservation_signature_requests
      add constraint reservation_signature_requests_hash_version_check
      check (hash_version in (1, 2));
  end if;
  if not exists (
    select 1 from pg_constraint
    where conname = 'reservation_user_signatures_hash_version_check'
  ) then
    alter table public.reservation_user_signatures
      add constraint reservation_user_signatures_hash_version_check
      check (hash_version in (1, 2));
  end if;
  if not exists (
    select 1 from pg_constraint
    where conname = 'reservation_permits_hash_version_check'
  ) then
    alter table public.reservation_permits
      add constraint reservation_permits_hash_version_check
      check (hash_version in (1, 2));
  end if;
end;
$$;

-- Contract v2 contains only values that can affect the official PDF. The
-- explicit contract marker prevents hashes from different material schemas
-- from being mistaken for each other.
create or replace function public.permit_printable_material(p_request_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  r public.reservation_requests%rowtype;
  result jsonb;
begin
  select * into r from public.reservation_requests where id = p_request_id;
  if not found then
    raise exception using errcode = 'P0002', message = 'Reservation not found';
  end if;

  select jsonb_build_object(
    'hash_contract_version', 2,
    'request_id', r.id,
    'requester_id', r.requester_id,
    'requester_name', r.requester_name,
    'requester_type', r.requester_category,
    'requester_unit', r.requester_unit,
    'admin_lane', r.admin_lane,
    'template_kind', r.admin_lane,
    'template_sha256', case r.admin_lane
      when 'internal' then '4732b1b07c455531615faa3de2b6e2dd2631ec2e4fa609c34ff99e241f64cb58'
      else 'bf328cc2b7eadafae9be130e2ec93342c05dea78a3579f1fccbb58ce1d5767aa'
    end,
    'facility_name', r.facility_name,
    'purpose', r.purpose,
    'headcount', r.headcount,
    'external_company_organization', r.external_company_organization,
    'external_complete_address', r.external_complete_address,
    'external_contact_numbers', to_jsonb(r.external_contact_numbers),
    'external_admission_fee_centavos', r.external_admission_fee_centavos,
    'total_amount_centavos', r.total_amount_centavos,
    'occurrences', coalesce((
      select jsonb_agg(
        jsonb_build_object('starts_at', o.starts_at, 'ends_at', o.ends_at)
        order by o.starts_at
      )
      from public.reservation_occurrences o
      where o.request_id = r.id
        and o.booking_state in ('held', 'booked', 'checked_in')
    ), '[]'::jsonb),
    'items', coalesce((
      select jsonb_agg(jsonb_build_object(
        'row_code', i.row_code,
        'label', i.label,
        'requested_quantity', i.requested_quantity,
        'duration_minutes', i.duration_minutes,
        'billing_basis', i.billing_basis,
        'unit_amount_centavos', i.unit_amount_centavos,
        'line_total_centavos', i.line_total_centavos
      ) order by i.display_order, i.label)
      from public.reservation_permit_items i
      where i.request_id = r.id
    ), '[]'::jsonb),
    'terms', coalesce((
      select jsonb_agg(jsonb_build_object(
        'terms_version_id', a.terms_version_id,
        'content_hash', a.content_hash
      ) order by a.terms_version_id)
      from public.reservation_terms_acceptances a
      where a.request_id = r.id
    ), '[]'::jsonb)
  ) into result;
  return result;
end;
$$;

revoke all on function public.permit_printable_material(uuid)
  from public, anon, authenticated;
grant execute on function public.permit_printable_material(uuid)
  to service_role;

create or replace function public.permit_printable_hash(p_request_id uuid)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select encode(
    extensions.digest(public.permit_printable_material(p_request_id)::text, 'sha256'),
    'hex'
  )
$$;

revoke all on function public.permit_printable_hash(uuid)
  from public, anon, authenticated;
grant execute on function public.permit_printable_hash(uuid)
  to service_role;

-- Prove which v1 signatures represent exactly the current printable fields.
-- Reconstructing the old material with the recorded reservation_version makes
-- this conservative: any real content change prevents automatic repair.
create temporary table permit_v2_safe_signatures on commit drop as
select
  s.id,
  s.signature_request_id,
  s.request_id,
  s.reservation_version,
  s.printable_content_hash as old_hash,
  public.permit_printable_hash(s.request_id) as new_hash
from public.reservation_user_signatures s
where s.hash_version = 1
  and s.reservation_version is not null
  and s.printable_content_hash = encode(
    extensions.digest((
      (public.permit_printable_material(s.request_id) - 'hash_contract_version')
      || jsonb_build_object('version', s.reservation_version)
    )::text, 'sha256'),
    'hex'
  );

create temporary table permit_v2_safe_requests on commit drop as
select
  q.id,
  q.request_id,
  public.permit_printable_hash(q.request_id) as new_hash
from public.reservation_signature_requests q
where q.hash_version = 1
  and q.status = 'requested'
  and q.reservation_version is not null
  and q.printable_content_hash = encode(
    extensions.digest((
      (public.permit_printable_material(q.request_id) - 'hash_contract_version')
      || jsonb_build_object('version', q.reservation_version)
    )::text, 'sha256'),
    'hex'
  );

update public.reservation_user_signatures s
set printable_content_hash = safe.new_hash,
    hash_version = 2
from permit_v2_safe_signatures safe
where s.id = safe.id;

update public.reservation_signature_requests q
set printable_content_hash = safe.new_hash,
    hash_version = 2
from permit_v2_safe_signatures safe
where q.id = safe.signature_request_id;

update public.reservation_signature_requests q
set printable_content_hash = safe.new_hash,
    hash_version = 2
from permit_v2_safe_requests safe
where q.id = safe.id;

-- Generated permits are preserved only when their bound user signature was
-- safely repaired and their old content hash is the same proven v1 hash.
update public.reservation_permits p
set content_hash = safe.new_hash,
    hash_version = 2
from permit_v2_safe_signatures safe
where p.status = 'active'
  and p.user_signature_id = safe.id
  and p.content_hash = safe.old_hash;

create temporary table permit_v2_affected_requests on commit drop as
select distinct q.request_id
from public.reservation_signature_requests q
where q.status in ('requested', 'signed')
  and q.printable_content_hash is distinct from public.permit_printable_hash(q.request_id)
union
select distinct p.request_id
from public.reservation_permits p
where p.status = 'active'
  and p.content_hash is distinct from public.permit_printable_hash(p.request_id);

update public.reservation_signature_requests q
set status = 'superseded',
    signed_at = null,
    superseded_at = coalesce(q.superseded_at, now())
where q.status in ('requested', 'signed')
  and q.printable_content_hash is distinct from public.permit_printable_hash(q.request_id);

update public.reservation_permits p
set status = 'superseded',
    generation_status = 'failed',
    generation_error_code = 'printable_content_changed'
where p.status = 'active'
  and p.content_hash is distinct from public.permit_printable_hash(p.request_id);

do $$
declare
  affected record;
  current_hash text;
  event_id uuid;
begin
  for affected in
    select r.*
    from public.reservation_requests r
    join permit_v2_affected_requests a on a.request_id = r.id
    where r.reservation_status in ('awaiting_payment', 'confirmed')
  loop
    if not exists (
      select 1 from public.reservation_permit_items where request_id = affected.id
    ) then
      perform public.populate_reservation_permit_items(affected.id);
    end if;
    if exists (
      select 1 from public.reservation_permit_items
      where request_id = affected.id and row_code like '%:unmapped'
    ) then
      continue;
    end if;
    current_hash := public.permit_printable_hash(affected.id);
    if not exists (
      select 1 from public.reservation_signature_requests
      where request_id = affected.id and status = 'requested'
        and printable_content_hash = current_hash
    ) and not exists (
      select 1 from public.reservation_user_signatures
      where request_id = affected.id and printable_content_hash = current_hash
    ) then
      insert into public.reservation_signature_requests(
        request_id, requester_id, requested_by, reservation_version,
        printable_content_hash, hash_version
      ) values (
        affected.id, affected.requester_id,
        coalesce(affected.decided_by, affected.requester_id), affected.version,
        current_hash, 2
      );
      event_id := public.reservation_event(
        affected.id,
        'requested updated reservation e-signature',
        'The previous signature could not be safely rebound to the current printable details.',
        jsonb_build_object('hash_contract_version', 2),
        null,
        false
      );
      perform public.notify_reservation_user(
        affected.id, event_id, 'signature_requested',
        'Updated e-signature required',
        'Reservation details changed. Please sign the updated reservation details.'
      );
    end if;
  end loop;

  for affected in
    select distinct request_id from (
      select request_id from permit_v2_safe_signatures
      union all
      select request_id from permit_v2_safe_requests
    ) repaired
  loop
    perform public.reservation_event(
      affected.request_id,
      'upgraded reservation e-signature hash',
      null,
      jsonb_build_object('from_hash_contract', 1, 'to_hash_contract', 2),
      null,
      false
    );
  end loop;
end;
$$;

alter table public.reservation_signature_requests
  alter column hash_version set default 2;
alter table public.reservation_user_signatures
  alter column hash_version set default 2;
alter table public.reservation_permits
  alter column hash_version set default 2;

-- A readiness response owns the signature truth consumed by every client.
create or replace function public.get_reservation_permit_readiness(
  p_request_id uuid
) returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  r public.reservation_requests%rowtype;
  blockers jsonb := '[]'::jsonb;
  paid integer;
  hash_value text;
  configuration jsonb;
  signature_state text;
  has_current_signature boolean;
begin
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'Sign in required';
  end if;
  select * into r from public.reservation_requests where id = p_request_id;
  if not found or (
    r.requester_id <> auth.uid() and not public.can_manage_reservation(r.id)
  ) then
    raise exception using errcode = '42501', message = 'Reservation access denied';
  end if;

  configuration := public.get_reservation_permit_configuration(r.id);
  if not (configuration->>'ready')::boolean then
    blockers := blockers || '"unmapped_permit_item"'::jsonb;
  end if;
  if r.admin_lane = 'internal' and r.reservation_status <> 'confirmed' then
    blockers := blockers || '"not_confirmed"'::jsonb;
  end if;
  if r.admin_lane = 'external'
     and r.reservation_status not in ('confirmed', 'completed') then
    blockers := blockers || '"not_confirmed"'::jsonb;
  end if;
  select coalesce(sum(amount_centavos), 0) into paid
  from public.payment_transactions
  where request_id = r.id and status = 'verified' and purpose <> 'refund';
  if r.admin_lane = 'external' and paid < r.total_amount_centavos then
    blockers := blockers || '"full_payment_required"'::jsonb;
  end if;
  if trim(r.requester_unit) = '' and r.admin_lane = 'internal' then
    blockers := blockers || '"requester_unit_required"'::jsonb;
  end if;
  if r.admin_lane = 'external' and (
    nullif(trim(r.external_company_organization), '') is null
    or nullif(trim(r.external_complete_address), '') is null
    or cardinality(coalesce(r.external_contact_numbers, '{}')) = 0
    or r.external_admission_fee_centavos is null
  ) then
    blockers := blockers || '"external_details_required"'::jsonb;
  end if;
  if not exists (
    select 1 from public.reservation_permit_items
    where request_id = r.id and source_kind = 'facility'
  ) then
    blockers := blockers || '"permit_items_required"'::jsonb;
  end if;
  if not exists (
    select 1 from public.reservation_occurrences
    where request_id = r.id and booking_state in ('held', 'booked', 'checked_in')
  ) then
    blockers := blockers || '"schedule_required"'::jsonb;
  end if;
  if r.admin_lane = 'external' and (
    select count(*) from public.reservation_permit_items where request_id = r.id
  ) > 8 then
    blockers := blockers || '"external_row_limit"'::jsonb;
  end if;
  if r.admin_lane = 'external' and exists (
    select 1 from public.reservation_permit_items
    where request_id = r.id group by row_code having count(*) > 1
  ) then
    blockers := blockers || '"duplicate_external_row"'::jsonb;
  end if;
  if r.admin_lane = 'external' and exists (
    select 1 from public.reservation_permit_items
    where request_id = r.id and row_code = 'external:tables_chairs'
      and requested_quantity is null
  ) then
    blockers := blockers || '"item_quantity_required"'::jsonb;
  end if;

  hash_value := public.permit_printable_hash(r.id);
  select exists (
    select 1 from public.reservation_user_signatures s
    where s.request_id = r.id and s.printable_content_hash = hash_value
  ) into has_current_signature;
  signature_state := case
    when has_current_signature then 'current'
    when exists (
      select 1 from public.reservation_signature_requests q
      where q.request_id = r.id and q.status = 'requested'
        and q.printable_content_hash = hash_value
    ) then 'requested'
    when exists (
      select 1 from public.reservation_user_signatures s where s.request_id = r.id
    ) or exists (
      select 1 from public.reservation_signature_requests q
      where q.request_id = r.id and q.signed_at is not null
    ) then 'stale'
    else 'missing'
  end;
  if not has_current_signature then
    blockers := blockers || '"requester_signature_required"'::jsonb;
  end if;
  if r.admin_lane = 'internal' and not exists (
    select 1 from public.permit_official_signature_revisions
    where slot = 'internal_approver' and active
  ) then
    blockers := blockers || '"internal_approver_signature_required"'::jsonb;
  end if;
  if r.admin_lane = 'external' and not exists (
    select 1 from public.permit_official_signature_revisions
    where slot = 'external_recommender' and active
  ) then
    blockers := blockers || '"external_recommender_signature_required"'::jsonb;
  end if;
  if r.admin_lane = 'external' and not exists (
    select 1 from public.permit_official_signature_revisions
    where slot = 'external_authorized_official' and active
  ) then
    blockers := blockers || '"external_authorized_signature_required"'::jsonb;
  end if;

  return jsonb_build_object(
    'ready', jsonb_array_length(blockers) = 0,
    'template_kind', r.admin_lane,
    'blockers', blockers,
    'printable_content_hash', hash_value,
    'printable_hash_version', 2,
    'requester_signature_state', signature_state,
    'configuration', configuration
  );
end;
$$;

-- Re-requesting is idempotent for the current printable hash and supersedes
-- only signatures bound to older content.
create or replace function public.request_reservation_signature(p_request_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.reservation_requests%rowtype;
  actor uuid := auth.uid();
  hash_value text;
  existing_request uuid;
  event_id uuid;
begin
  select * into r from public.reservation_requests where id = p_request_id for update;
  if not found or not public.can_manage_reservation(r.id) then
    raise exception using errcode = '42501', message = 'Reservation management access required';
  end if;
  if r.reservation_status not in ('awaiting_payment', 'confirmed') then
    raise exception using errcode = '22023', message = 'A signature can be requested only after approval';
  end if;
  if not exists (
    select 1 from public.reservation_permit_items where request_id = r.id
  ) then
    perform public.populate_reservation_permit_items(r.id);
  end if;
  if not (public.get_reservation_permit_configuration(r.id)->>'ready')::boolean then
    raise exception using errcode = '22023', message = 'Complete the required facility permit mappings before requesting a signature';
  end if;

  hash_value := public.permit_printable_hash(r.id);
  select id into existing_request
  from public.reservation_signature_requests
  where request_id = r.id and status = 'requested'
    and printable_content_hash = hash_value;
  if existing_request is not null then
    event_id := public.reservation_event(
      r.id, 'resent reservation e-signature request', null,
      jsonb_build_object('signature_request_id', existing_request), null, true
    );
    perform public.notify_reservation_user(
      r.id, event_id, 'signature_requested', 'E-signature reminder',
      'Your reservation is waiting for your e-signature. Open My reservations to sign it.'
    );
    return;
  end if;

  update public.reservation_signature_requests
  set status = 'superseded', signed_at = null,
      superseded_at = coalesce(superseded_at, now())
  where request_id = r.id and status in ('requested', 'signed')
    and printable_content_hash is distinct from hash_value;
  insert into public.reservation_signature_requests(
    request_id, requester_id, requested_by, reservation_version,
    printable_content_hash, hash_version
  ) values (r.id, r.requester_id, actor, r.version, hash_value, 2);
  event_id := public.reservation_event(
    r.id, 'requested reservation e-signature', null,
    jsonb_build_object('printable_content_hash', hash_value, 'hash_version', 2),
    null, true
  );
  perform public.notify_reservation_user(
    r.id, event_id, 'signature_requested', 'E-signature requested',
    'Your approved reservation is ready for its reservation-specific signature.'
  );
end;
$$;

revoke all on function public.request_reservation_signature(uuid)
  from public, anon;
grant execute on function public.request_reservation_signature(uuid)
  to authenticated;

-- The trigger now checks the content hash itself. It runs for every request
-- update because reservation_requests.version is advanced by a BEFORE trigger
-- and therefore is not visible to an UPDATE OF version trigger declaration.
create or replace function public.invalidate_permit_for_material_version_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  hash_value text;
  actor uuid;
  event_id uuid;
begin
  hash_value := public.permit_printable_hash(new.id);
  if exists (
    select 1 from public.reservation_user_signatures
    where request_id = new.id and printable_content_hash = hash_value
  ) or exists (
    select 1 from public.reservation_signature_requests
    where request_id = new.id and status = 'requested'
      and printable_content_hash = hash_value
  ) or exists (
    select 1 from public.reservation_permits
    where request_id = new.id and status = 'active' and content_hash = hash_value
  ) then
    return new;
  end if;
  if not exists (
    select 1 from public.reservation_signature_requests where request_id = new.id
  ) and not exists (
    select 1 from public.reservation_permits where request_id = new.id
  ) then
    return new;
  end if;

  update public.reservation_signature_requests
  set status = 'superseded', signed_at = null,
      superseded_at = coalesce(superseded_at, now())
  where request_id = new.id and status in ('requested', 'signed');
  update public.reservation_permits
  set status = 'superseded', generation_status = 'failed',
      generation_error_code = 'reservation_changed'
  where request_id = new.id and status = 'active';

  if new.reservation_status in ('awaiting_payment', 'confirmed')
     and not exists (
       select 1 from public.reservation_permit_items
       where request_id = new.id and row_code like '%:unmapped'
     ) then
    hash_value := public.permit_printable_hash(new.id);
    actor := coalesce(auth.uid(), new.decided_by, new.requester_id);
    insert into public.reservation_signature_requests(
      request_id, requester_id, requested_by, reservation_version,
      printable_content_hash, hash_version
    ) values (new.id, new.requester_id, actor, new.version, hash_value, 2);
    event_id := public.reservation_event(
      new.id, 'requested updated reservation e-signature', null,
      jsonb_build_object('hash_version', 2), null, true
    );
    perform public.notify_reservation_user(
      new.id, event_id, 'signature_requested', 'Updated e-signature required',
      'Reservation details changed. Please sign the updated reservation details.'
    );
  end if;
  return new;
end;
$$;

drop trigger if exists reservation_invalidate_permit_version
  on public.reservation_requests;
create trigger reservation_invalidate_permit_version
after update on public.reservation_requests
for each row execute function public.invalidate_permit_for_material_version_change();

notify pgrst, 'reload schema';

commit;
