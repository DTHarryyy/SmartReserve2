-- Configurable audience pricing, structured amenities, immutable quote
-- snapshots, and versioned terms acceptance.

create extension if not exists pgcrypto with schema extensions;

alter table public.facilities
  add column if not exists facility_classification text not null default 'shared'
    check (facility_classification in ('internal', 'external', 'shared')),
  add column if not exists deposit_window_minutes integer not null default 1440
    check (deposit_window_minutes between 30 and 10080),
  add column if not exists balance_due_lead_days integer not null default 3
    check (balance_due_lead_days between 0 and 90);

create table if not exists public.facility_rates (
  id uuid primary key default gen_random_uuid(),
  facility_id uuid not null references public.facilities(id) on delete cascade,
  audience text not null check (audience in ('student', 'faculty', 'staff', 'guest')),
  hourly_rate_centavos integer not null check (hourly_rate_centavos >= 0),
  enabled boolean not null default true,
  created_by uuid references public.profiles(id) on delete set null,
  updated_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (facility_id, audience)
);

create table if not exists public.facility_amenities (
  id uuid primary key default gen_random_uuid(),
  facility_id uuid not null references public.facilities(id) on delete cascade,
  name citext not null check (length(trim(name::text)) between 2 and 80),
  description text not null default '',
  price_centavos integer not null default 0 check (price_centavos >= 0),
  pricing_unit text not null default 'per_occurrence'
    check (pricing_unit in ('per_reservation', 'per_occurrence')),
  enabled boolean not null default true,
  created_by uuid references public.profiles(id) on delete set null,
  updated_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (facility_id, name)
);

create index if not exists facility_rates_facility_idx
  on public.facility_rates(facility_id, enabled, audience);
create index if not exists facility_amenities_facility_idx
  on public.facility_amenities(facility_id, enabled, name);

create or replace function public.set_scoped_facility_actor()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  new.updated_at = now();
  new.updated_by = auth.uid();
  if tg_op = 'INSERT' then new.created_by = auth.uid(); end if;
  return new;
end;
$$;

drop trigger if exists facility_rates_set_actor on public.facility_rates;
create trigger facility_rates_set_actor
before insert or update on public.facility_rates
for each row execute procedure public.set_scoped_facility_actor();

drop trigger if exists facility_amenities_set_actor on public.facility_amenities;
create trigger facility_amenities_set_actor
before insert or update on public.facility_amenities
for each row execute procedure public.set_scoped_facility_actor();

alter table public.facility_rates enable row level security;
alter table public.facility_amenities enable row level security;
grant select, insert, update, delete on public.facility_rates to authenticated;
grant select, insert, update, delete on public.facility_amenities to authenticated;

create policy facility_rates_read
on public.facility_rates for select to authenticated
using (
  public.can_manage_facility(facility_id)
  or (enabled and exists (
    select 1 from public.facilities f
    where f.id = facility_id and f.archived_at is null
      and f.public_listing and f.status <> 'draft'
  ))
);
create policy facility_rates_insert
on public.facility_rates for insert to authenticated
with check (public.can_manage_facility(facility_id));
create policy facility_rates_update
on public.facility_rates for update to authenticated
using (public.can_manage_facility(facility_id))
with check (public.can_manage_facility(facility_id));
create policy facility_rates_delete
on public.facility_rates for delete to authenticated
using (public.can_manage_facility(facility_id));

create policy facility_amenities_read
on public.facility_amenities for select to authenticated
using (
  public.can_manage_facility(facility_id)
  or (enabled and exists (
    select 1 from public.facilities f
    where f.id = facility_id and f.archived_at is null
      and f.public_listing and f.status <> 'draft'
  ))
);

create policy facility_amenities_assigned_insert
on public.facility_amenities for insert to authenticated
with check (public.can_manage_facility(facility_id));
create policy facility_amenities_assigned_update
on public.facility_amenities for update to authenticated
using (public.can_manage_facility(facility_id))
with check (public.can_manage_facility(facility_id));
create policy facility_amenities_assigned_delete
on public.facility_amenities for delete to authenticated
using (public.can_manage_facility(facility_id));

-- Preserve today's capacity-derived amount as the initial explicit policy.
insert into public.facility_rates(facility_id, audience, hourly_rate_centavos)
select f.id, audience,
  50000 * case when f.capacity >= 400 then 3 when f.capacity >= 80 then 2 else 1 end
from public.facilities f
cross join unnest(array['student','faculty','staff','guest']) audience
on conflict (facility_id, audience) do nothing;

create or replace function public.seed_new_facility_rates()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.facility_rates(facility_id, audience, hourly_rate_centavos)
  select new.id, audience,
    50000 * case when new.capacity >= 400 then 3
      when new.capacity >= 80 then 2 else 1 end
  from unnest(array['student','faculty','staff','guest']) audience
  on conflict (facility_id, audience) do nothing;
  return new;
end;
$$;

drop trigger if exists facilities_seed_rates on public.facilities;
create trigger facilities_seed_rates
after insert on public.facilities
for each row execute function public.seed_new_facility_rates();

insert into public.facility_amenities(facility_id, name, price_centavos)
select f.id, trim(amenity), 0
from public.facilities f
cross join lateral unnest(f.amenities) amenity
where trim(amenity) <> ''
on conflict (facility_id, name) do nothing;

-- Transitional compatibility for the existing facility editor. New labels
-- become structured, included amenities; priced rows are never overwritten.
create or replace function public.sync_legacy_facility_amenities()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.facility_amenities(facility_id, name, price_centavos, enabled)
  select new.id, trim(label), 0, true
  from unnest(coalesce(new.amenities, '{}'::text[])) label
  where trim(label) <> ''
  on conflict (facility_id, name) do update set enabled = true;

  update public.facility_amenities a
  set enabled = false, updated_at = now()
  where a.facility_id = new.id
    and a.price_centavos = 0
    and not (a.name = any(coalesce(new.amenities, '{}'::text[])));
  return new;
end;
$$;

drop trigger if exists facilities_sync_legacy_amenities on public.facilities;
create trigger facilities_sync_legacy_amenities
after insert or update of amenities on public.facilities
for each row execute function public.sync_legacy_facility_amenities();

create table if not exists public.terms_versions (
  id uuid primary key default gen_random_uuid(),
  scope text not null check (scope in ('global', 'facility')),
  facility_id uuid references public.facilities(id) on delete cascade,
  version integer not null check (version > 0),
  title text not null check (length(trim(title)) between 3 and 120),
  content text not null check (length(trim(content)) >= 20),
  content_hash text not null,
  active boolean not null default false,
  published_by uuid references public.profiles(id) on delete set null,
  published_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  check ((scope = 'global' and facility_id is null)
      or (scope = 'facility' and facility_id is not null))
);

create unique index if not exists terms_versions_scope_version_key
  on public.terms_versions(
    scope, coalesce(facility_id, '00000000-0000-0000-0000-000000000000'::uuid), version
  );
create unique index if not exists terms_versions_single_active_idx
  on public.terms_versions(
    scope, coalesce(facility_id, '00000000-0000-0000-0000-000000000000'::uuid)
  ) where active;

insert into public.terms_versions(
  scope, version, title, content, content_hash, active
) values (
  'global', 1, 'SmartReserve reservation and payment terms',
  'A reservation is secured only after the required payment is verified. The remaining balance is due by the displayed deadline. Missed deadlines may expire the reservation and release the schedule. Cancellation and refund eligibility follow the facility policy, and verified down payments may be non-refundable. The renter accepts responsibility for facility rules, equipment, and damage caused during use.',
  encode(extensions.digest(
    'A reservation is secured only after the required payment is verified. The remaining balance is due by the displayed deadline. Missed deadlines may expire the reservation and release the schedule. Cancellation and refund eligibility follow the facility policy, and verified down payments may be non-refundable. The renter accepts responsibility for facility rules, equipment, and damage caused during use.',
    'sha256'
  ), 'hex'), true
) on conflict do nothing;

alter table public.terms_versions enable row level security;
grant select on public.terms_versions to authenticated;
create policy terms_versions_read
on public.terms_versions for select to authenticated
using (
  active or public.is_internal_admin()
  or (facility_id is not null and public.can_manage_facility(facility_id))
);

alter table public.reservation_requests
  add column if not exists pricing_audience text,
  add column if not exists currency text not null default 'PHP',
  add column if not exists facility_amount_centavos integer not null default 0,
  add column if not exists amenity_amount_centavos integer not null default 0,
  add column if not exists discount_amount_centavos integer not null default 0,
  add column if not exists total_amount_centavos integer not null default 0,
  add column if not exists required_down_payment_centavos integer not null default 0,
  add column if not exists pricing_fingerprint text,
  add column if not exists legacy_financial_state boolean not null default false;

update public.reservation_requests r
set pricing_audience = case
      when p.verification_status = 'verified'
       and p.campus_claim in ('student','faculty','staff') then p.campus_claim
      else 'guest' end,
    facility_amount_centavos = case
      when r.payment_status = 'not_required' then 0
      else r.payment_amount_centavos end,
    total_amount_centavos = case
      when r.payment_status = 'not_required' then 0
      else r.payment_amount_centavos end,
    required_down_payment_centavos = case
      when r.payment_status = 'not_required' then 0
      else (r.payment_amount_centavos + 1) / 2 end,
    pricing_fingerprint = coalesce(r.pricing_fingerprint, 'legacy:' || r.id::text),
    legacy_financial_state = r.status = 'approved' and r.payment_status <> 'not_required'
from public.profiles p
where p.id = r.requester_id;

update public.reservation_requests
set pricing_audience = 'guest'
where pricing_audience is null;

alter table public.reservation_requests
  alter column pricing_audience set not null,
  alter column pricing_fingerprint set not null,
  add constraint reservation_requests_pricing_audience_check
    check (pricing_audience in ('student','faculty','staff','guest')),
  add constraint reservation_requests_money_check check (
    currency = 'PHP'
    and facility_amount_centavos >= 0
    and amenity_amount_centavos >= 0
    and discount_amount_centavos >= 0
    and total_amount_centavos >= 0
    and required_down_payment_centavos >= 0
    and required_down_payment_centavos <= total_amount_centavos
    and total_amount_centavos =
      facility_amount_centavos + amenity_amount_centavos - discount_amount_centavos
    and required_down_payment_centavos = (total_amount_centavos + 1) / 2
  );

create or replace function public.protect_reservation_quote_snapshot()
returns trigger language plpgsql set search_path = public as $$
begin
  if new.admin_lane is distinct from old.admin_lane
      or new.pricing_audience is distinct from old.pricing_audience
      or new.currency is distinct from old.currency
      or new.facility_amount_centavos is distinct from old.facility_amount_centavos
      or new.amenity_amount_centavos is distinct from old.amenity_amount_centavos
      or new.discount_amount_centavos is distinct from old.discount_amount_centavos
      or new.total_amount_centavos is distinct from old.total_amount_centavos
      or new.required_down_payment_centavos is distinct from old.required_down_payment_centavos
      or new.pricing_fingerprint is distinct from old.pricing_fingerprint then
    raise exception using errcode = '22023',
      message = 'Reservation lane and pricing snapshots are immutable';
  end if;
  return new;
end;
$$;

drop trigger if exists reservation_requests_protect_quote_snapshot
  on public.reservation_requests;
create trigger reservation_requests_protect_quote_snapshot
before update on public.reservation_requests
for each row execute function public.protect_reservation_quote_snapshot();

create table if not exists public.reservation_amenities (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null references public.reservation_requests(id) on delete cascade,
  facility_amenity_id uuid references public.facility_amenities(id) on delete set null,
  name_snapshot text not null,
  unit_price_centavos integer not null check (unit_price_centavos >= 0),
  quantity integer not null default 1 check (quantity > 0),
  line_total_centavos integer not null check (line_total_centavos >= 0),
  created_at timestamptz not null default now(),
  unique (request_id, facility_amenity_id)
);

create table if not exists public.reservation_price_lines (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null references public.reservation_requests(id) on delete cascade,
  line_type text not null check (line_type in ('facility','amenity','discount','adjustment')),
  source_id uuid,
  label text not null,
  quantity numeric(12,2) not null default 1,
  unit_amount_centavos integer not null,
  line_total_centavos integer not null,
  created_at timestamptz not null default now()
);

create index if not exists reservation_amenities_request_idx
  on public.reservation_amenities(request_id);
create index if not exists reservation_price_lines_request_idx
  on public.reservation_price_lines(request_id, line_type);

alter table public.reservation_amenities enable row level security;
alter table public.reservation_price_lines enable row level security;
grant select on public.reservation_amenities, public.reservation_price_lines to authenticated;

create policy reservation_amenities_read
on public.reservation_amenities for select to authenticated
using (public.can_access_reservation(request_id));
create policy reservation_price_lines_read
on public.reservation_price_lines for select to authenticated
using (public.can_access_reservation(request_id));

-- Backfill the compatibility amenity arrays introduced by the preceding
-- reservation-amenities migration as zero-price historical snapshots.
insert into public.reservation_amenities(
  request_id, facility_amenity_id, name_snapshot,
  unit_price_centavos, quantity, line_total_centavos
)
select r.id, fa.id, trim(label), 0, 1, 0
from public.reservation_requests r
cross join lateral unnest(r.amenities) label
left join public.facility_amenities fa
  on fa.facility_id = r.facility_id and lower(fa.name::text) = lower(trim(label))
where trim(label) <> ''
on conflict (request_id, facility_amenity_id) do nothing;

insert into public.reservation_price_lines(
  request_id, line_type, source_id, label, quantity,
  unit_amount_centavos, line_total_centavos
)
select r.id, 'facility', r.facility_id, r.facility_name, 1,
  r.facility_amount_centavos, r.facility_amount_centavos
from public.reservation_requests r
where not exists (
  select 1 from public.reservation_price_lines l
  where l.request_id = r.id and l.line_type = 'facility'
);

create table if not exists public.reservation_terms_acceptances (
  request_id uuid not null references public.reservation_requests(id) on delete cascade,
  terms_version_id uuid not null references public.terms_versions(id) on delete restrict,
  user_id uuid not null references public.profiles(id) on delete restrict,
  content_hash text not null,
  accepted_at timestamptz not null default now(),
  primary key (request_id, terms_version_id)
);

alter table public.reservation_terms_acceptances enable row level security;
grant select on public.reservation_terms_acceptances to authenticated;
create policy reservation_terms_acceptances_read
on public.reservation_terms_acceptances for select to authenticated
using (user_id = auth.uid() or public.can_manage_reservation(request_id));

create policy terms_versions_accepted_read
on public.terms_versions for select to authenticated
using (exists (
  select 1 from public.reservation_terms_acceptances acceptance
  where acceptance.terms_version_id = terms_versions.id
    and public.can_access_reservation(acceptance.request_id)
));

create or replace function public.requester_pricing_audience(p_user_id uuid default auth.uid())
returns text
language sql
stable
security definer
set search_path = public
as $$
  select case
    when p.verification_status = 'verified'
     and p.campus_claim in ('student','faculty','staff') then p.campus_claim
    else 'guest'
  end
  from public.profiles p where p.id = p_user_id;
$$;

alter table public.reservation_requests
  alter column pricing_audience set default 'guest',
  alter column pricing_fingerprint set default 'legacy';

create or replace function public.get_reservation_quote(
  p_facility_id uuid,
  p_starts_at timestamptz[],
  p_ends_at timestamptz[],
  p_amenity_ids uuid[] default '{}'::uuid[],
  p_headcount integer default null
) returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  facility public.facilities%rowtype;
  audience_value text;
  lane_value text;
  rate_value integer;
  facility_total integer := 0;
  amenity_total integer := 0;
  total_value integer;
  total_minutes numeric := 0;
  lines_value jsonb := '[]'::jsonb;
  amenities_value jsonb := '[]'::jsonb;
  terms_value jsonb := '[]'::jsonb;
  payload jsonb;
  item record;
  local_start timestamp;
  local_end timestamp;
  i integer;
begin
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'Sign in required';
  end if;
  select * into facility from public.facilities
  where id = p_facility_id and archived_at is null and public_listing
    and status = 'active';
  if facility.id is null then
    raise exception using errcode = 'P0002', message = 'Facility not found or unavailable';
  end if;
  audience_value := public.requester_pricing_audience();
  lane_value := public.requester_admin_lane();
  if not public.has_facility_admin_lane(p_facility_id, lane_value) then
    raise exception using errcode = '22023',
      message = 'This facility does not yet have an administrator for your account type';
  end if;
  if cardinality(p_starts_at) is null or cardinality(p_starts_at) not between 1 and 12
     or cardinality(p_starts_at) <> cardinality(p_ends_at) then
    raise exception using errcode = '22023', message = 'Provide between one and twelve valid occurrences';
  end if;
  if p_headcount is not null and p_headcount not between 1 and facility.capacity then
    raise exception using errcode = '22023', message = 'Attendee count exceeds facility capacity';
  end if;
  select hourly_rate_centavos into rate_value
  from public.facility_rates
  where facility_id = p_facility_id and audience = audience_value and enabled;
  if rate_value is null then
    raise exception using errcode = '22023', message = 'No active rate is configured for your account type';
  end if;
  for i in 1..cardinality(p_starts_at) loop
    local_start := p_starts_at[i] at time zone 'Asia/Manila';
    local_end := p_ends_at[i] at time zone 'Asia/Manila';
    if p_starts_at[i] >= p_ends_at[i] or local_start::date <> local_end::date then
      raise exception using errcode = '22023', message = 'Choose a valid same-day time range';
    end if;
    if not facility.open_days[extract(isodow from local_start)::integer]
       or local_start::time < facility.open_time or local_end::time > facility.close_time then
      raise exception using errcode = '22023', message = 'Reservation is outside facility operating hours';
    end if;
    if extract(epoch from (p_ends_at[i] - p_starts_at[i])) / 60
        > facility.max_duration_minutes then
      raise exception using errcode = '22023', message = 'Reservation exceeds the facility maximum duration';
    end if;
    if p_starts_at[i] < now()
       or p_starts_at[i] > now() + make_interval(days => facility.advance_booking_days) then
      raise exception using errcode = '22023', message = 'Reservation date is outside the booking window';
    end if;
    total_minutes := total_minutes + extract(epoch from (p_ends_at[i] - p_starts_at[i])) / 60;
  end loop;
  facility_total := round(total_minutes * rate_value / 60)::integer;
  lines_value := jsonb_build_array(jsonb_build_object(
    'line_type','facility','source_id',facility.id,'label',facility.name::text,
    'quantity',round(total_minutes / 60, 2),'unit_amount_centavos',rate_value,
    'line_total_centavos',facility_total
  ));
  if cardinality(coalesce(p_amenity_ids, '{}'::uuid[]))
      <> cardinality(array(
        select distinct amenity_id
        from unnest(coalesce(p_amenity_ids, '{}'::uuid[])) amenity_id
      )) then
    raise exception using errcode = '22023', message = 'Duplicate amenities are not allowed';
  end if;
  for item in
    select a.*,
      case a.pricing_unit when 'per_occurrence' then cardinality(p_starts_at) else 1 end quantity_value
    from public.facility_amenities a
    where a.id = any(coalesce(p_amenity_ids, '{}'::uuid[]))
      and a.facility_id = p_facility_id and a.enabled
    order by a.name
  loop
    amenity_total := amenity_total + item.price_centavos * item.quantity_value;
    amenities_value := amenities_value || jsonb_build_array(jsonb_build_object(
      'id',item.id,'name',item.name::text,'price_centavos',item.price_centavos,
      'quantity',item.quantity_value,
      'line_total_centavos',item.price_centavos * item.quantity_value
    ));
    lines_value := lines_value || jsonb_build_array(jsonb_build_object(
      'line_type','amenity','source_id',item.id,'label',item.name::text,
      'quantity',item.quantity_value,'unit_amount_centavos',item.price_centavos,
      'line_total_centavos',item.price_centavos * item.quantity_value
    ));
  end loop;
  if jsonb_array_length(amenities_value) <> cardinality(coalesce(p_amenity_ids, '{}'::uuid[])) then
    raise exception using errcode = '22023', message = 'One or more amenities are unavailable for this facility';
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',t.id,'title',t.title,'version',t.version,'content',t.content,
    'content_hash',t.content_hash
  ) order by t.scope,t.version),'[]'::jsonb)
  into terms_value
  from public.terms_versions t
  where t.active and (t.scope = 'global' or t.facility_id = p_facility_id);
  total_value := facility_total + amenity_total;
  payload := jsonb_build_object(
    'facility_id',facility.id,'audience',audience_value,'admin_lane',lane_value,
    'currency','PHP','facility_amount_centavos',facility_total,
    'amenity_amount_centavos',amenity_total,'discount_amount_centavos',0,
    'total_amount_centavos',total_value,
    'required_down_payment_centavos',(total_value + 1) / 2,
    'lines',lines_value,'amenities',amenities_value,'terms',terms_value
  );
  return payload || jsonb_build_object(
    'pricing_fingerprint', encode(extensions.digest(payload::text, 'sha256'), 'hex')
  );
end;
$$;

revoke all on function public.requester_pricing_audience(uuid) from public, anon;
revoke all on function public.get_reservation_quote(uuid,timestamptz[],timestamptz[],uuid[],integer)
  from public, anon;
grant execute on function public.requester_pricing_audience(uuid) to authenticated;
grant execute on function public.get_reservation_quote(uuid,timestamptz[],timestamptz[],uuid[],integer)
  to authenticated;

-- The legacy writer accepts client-side prices and free-text amenities. Keep
-- its columns readable for one compatibility release, but require new writes
-- to use the authoritative v2 quote + terms endpoint.
revoke execute on function public.submit_reservation(
  uuid,uuid,text,integer,timestamptz[],timestamptz[],jsonb,integer,text[]
) from authenticated;

create or replace function public.submit_reservation_v2(
  p_request_id uuid,
  p_facility_id uuid,
  p_purpose text,
  p_headcount integer,
  p_starts_at timestamptz[],
  p_ends_at timestamptz[],
  p_amenity_ids uuid[] default '{}'::uuid[],
  p_terms_version_ids uuid[] default '{}'::uuid[],
  p_pricing_fingerprint text default null,
  p_attachment_metadata jsonb default '[]'::jsonb
) returns public.reservation_requests
language plpgsql
security definer
set search_path = public, storage
as $$
declare
  profile public.profiles%rowtype;
  facility public.facilities%rowtype;
  quote jsonb;
  result public.reservation_requests%rowtype;
  attachment jsonb;
  line jsonb;
  amenity jsonb;
  term_row public.terms_versions%rowtype;
  required_terms uuid[];
  selected_names text[];
  local_start timestamp;
  local_end timestamp;
  event_id uuid;
  i integer;
begin
  if auth.uid() is null then raise exception using errcode='42501',message='Sign in required'; end if;
  select * into profile from public.profiles where id = auth.uid() for update;
  if profile.id is null or profile.account_status <> 'active' or profile.role <> 'user' then
    raise exception using errcode='42501',message='This account cannot submit reservations';
  end if;
  perform 1
  from public.facility_admin_assignments a
  join public.profiles admin on admin.id = a.admin_id
  where a.facility_id = p_facility_id
    and admin.account_status = 'active'
    and admin.role = case public.requester_admin_lane(profile.id)
      when 'internal' then 'internal_admin' else 'external_admin' end
  for share of a, admin;
  if not found then
    raise exception using errcode='22023',
      message='This facility does not yet have an administrator for your account type';
  end if;
  select * into facility from public.facilities
  where id = p_facility_id and archived_at is null and public_listing and status = 'active'
  for share;
  if facility.id is null then raise exception using errcode='P0002',message='Facility not found or unavailable'; end if;
  perform 1 from public.facility_rates
    where facility_id = p_facility_id and enabled for share;
  perform 1 from public.facility_amenities
    where id = any(coalesce(p_amenity_ids,'{}'::uuid[])) for share;
  perform 1 from public.terms_versions
    where active and (scope='global' or facility_id=p_facility_id) for share;
  quote := public.get_reservation_quote(
    p_facility_id,p_starts_at,p_ends_at,p_amenity_ids,p_headcount
  );
  if p_pricing_fingerprint is null
     or p_pricing_fingerprint <> quote->>'pricing_fingerprint' then
    raise exception using errcode='40001',message='Pricing changed. Review the updated quote and try again';
  end if;
  if p_headcount not between 1 and facility.capacity then
    raise exception using errcode='22023',message='Attendee count exceeds facility capacity';
  end if;
  if length(trim(p_purpose)) not between 3 and 1000 then
    raise exception using errcode='22023',message='Provide a reservation purpose';
  end if;
  if jsonb_array_length(coalesce(p_attachment_metadata,'[]'::jsonb)) > 3 then
    raise exception using errcode='22023',message='A maximum of three supporting files is allowed';
  end if;
  select coalesce(array_agg(id order by id),'{}'::uuid[]) into required_terms
  from public.terms_versions
  where active and (scope='global' or facility_id=p_facility_id);
  if cardinality(required_terms) <> cardinality(array(
      select distinct id from unnest(coalesce(p_terms_version_ids,'{}'::uuid[])) id
    )) or not required_terms @> coalesce(p_terms_version_ids,'{}'::uuid[]) then
    raise exception using errcode='22023',message='Accept the current reservation terms before submitting';
  end if;
  for i in 1..cardinality(p_starts_at) loop
    local_start := p_starts_at[i] at time zone 'Asia/Manila';
    local_end := p_ends_at[i] at time zone 'Asia/Manila';
    if p_starts_at[i] >= p_ends_at[i] or local_start::date <> local_end::date then
      raise exception using errcode='22023',message='Choose a valid same-day time range';
    end if;
    if not facility.open_days[extract(isodow from local_start)::integer]
       or local_start::time < facility.open_time or local_end::time > facility.close_time then
      raise exception using errcode='22023',message='Reservation is outside facility operating hours';
    end if;
    if extract(epoch from (p_ends_at[i]-p_starts_at[i]))/60 > facility.max_duration_minutes then
      raise exception using errcode='22023',message='Reservation exceeds the facility maximum duration';
    end if;
    if p_starts_at[i] < now()
       or p_starts_at[i] > now()+make_interval(days=>facility.advance_booking_days) then
      raise exception using errcode='22023',message='Reservation date is outside the booking window';
    end if;
  end loop;
  select coalesce(array_agg(a.name::text order by a.name),'{}'::text[])
  into selected_names
  from public.facility_amenities a
  where a.id=any(coalesce(p_amenity_ids,'{}'::uuid[]));
  insert into public.reservation_requests(
    id,requester_id,facility_id,requester_name,requester_role,requester_unit,
    facility_name,facility_building,facility_room,facility_capacity,purpose,headcount,
    status,held_for_verification,recurrence,payment_amount_centavos,payment_status,
    amenities,admin_lane,pricing_audience,currency,facility_amount_centavos,
    amenity_amount_centavos,discount_amount_centavos,total_amount_centavos,
    required_down_payment_centavos,pricing_fingerprint
  ) values (
    p_request_id,profile.id,facility.id,coalesce(nullif(profile.full_name,''),profile.email),
    profile.role,coalesce(profile.unit,''),facility.name::text,facility.building,facility.room,
    facility.capacity,trim(p_purpose),p_headcount,'pending',false,
    case when cardinality(p_starts_at)>1 then 'weekly' else 'none' end,
    (quote->>'total_amount_centavos')::integer,
    case when (quote->>'total_amount_centavos')::integer=0 then 'not_required' else 'quoted' end,
    selected_names,quote->>'admin_lane',quote->>'audience','PHP',
    (quote->>'facility_amount_centavos')::integer,
    (quote->>'amenity_amount_centavos')::integer,0,
    (quote->>'total_amount_centavos')::integer,
    (quote->>'required_down_payment_centavos')::integer,
    quote->>'pricing_fingerprint'
  ) returning * into result;
  for i in 1..cardinality(p_starts_at) loop
    insert into public.reservation_occurrences(
      request_id,facility_id,starts_at,ends_at,buffer_minutes
    ) values (result.id,facility.id,p_starts_at[i],p_ends_at[i],facility.booking_buffer_minutes);
  end loop;
  for amenity in select value from jsonb_array_elements(quote->'amenities') loop
    insert into public.reservation_amenities(
      request_id,facility_amenity_id,name_snapshot,unit_price_centavos,quantity,line_total_centavos
    ) values (
      result.id,(amenity->>'id')::uuid,amenity->>'name',
      (amenity->>'price_centavos')::integer,(amenity->>'quantity')::integer,
      (amenity->>'line_total_centavos')::integer
    );
  end loop;
  for line in select value from jsonb_array_elements(quote->'lines') loop
    insert into public.reservation_price_lines(
      request_id,line_type,source_id,label,quantity,unit_amount_centavos,line_total_centavos
    ) values (
      result.id,line->>'line_type',(line->>'source_id')::uuid,line->>'label',
      (line->>'quantity')::numeric,(line->>'unit_amount_centavos')::integer,
      (line->>'line_total_centavos')::integer
    );
  end loop;
  for term_row in select * from public.terms_versions where id=any(required_terms) loop
    insert into public.reservation_terms_acceptances(
      request_id,terms_version_id,user_id,content_hash
    ) values (result.id,term_row.id,profile.id,term_row.content_hash);
  end loop;
  for attachment in select value from jsonb_array_elements(coalesce(p_attachment_metadata,'[]'::jsonb)) loop
    if attachment->>'storage_path' not like auth.uid()::text||'/%' then
      raise exception using errcode='42501',message='Invalid attachment path';
    end if;
    insert into public.reservation_attachments(
      request_id,owner_id,storage_path,file_name,mime_type,byte_size
    ) values (
      result.id,auth.uid(),attachment->>'storage_path',attachment->>'file_name',
      attachment->>'mime_type',(attachment->>'byte_size')::integer
    );
  end loop;
  event_id := public.reservation_event(result.id,'submitted a reservation request',null,
    jsonb_build_object('admin_lane',result.admin_lane,'total_amount_centavos',result.total_amount_centavos),null,false);
  insert into public.app_notifications(recipient_id,request_id,event_id,kind,title,body)
  select a.admin_id,result.id,event_id,'reservation_submitted','New reservation request',
    result.requester_name||' requested '||result.facility_name
  from public.facility_admin_assignments a
  join public.profiles p on p.id=a.admin_id and p.account_status='active'
  where a.facility_id=result.facility_id
    and p.role=case result.admin_lane when 'internal' then 'internal_admin' else 'external_admin' end;
  return result;
end;
$$;

revoke all on function public.submit_reservation_v2(
  uuid,uuid,text,integer,timestamptz[],timestamptz[],uuid[],uuid[],text,jsonb
) from public, anon;
grant execute on function public.submit_reservation_v2(
  uuid,uuid,text,integer,timestamptz[],timestamptz[],uuid[],uuid[],text,jsonb
) to authenticated;

notify pgrst, 'reload schema';
