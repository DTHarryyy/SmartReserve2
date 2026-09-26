-- Official reservation permits. The supplied PDFs are immutable visual
-- templates; PostgreSQL owns eligibility and immutable printable snapshots,
-- while the generate-permit Edge Function stamps and stores the final bytes.

alter table public.facilities
  add column if not exists internal_permit_row_code text
    check (internal_permit_row_code in ('audio_visual_main_hall','conference_room','other')),
  add column if not exists external_permit_row_code text
    check (external_permit_row_code in ('gym_auditorium','tables_chairs','lcd_projector','avr','led_video_wall','accommodation','love_hall','other'));

update public.facilities
set internal_permit_row_code = 'conference_room'
where lower(trim(name::text)) = 'faculty conference room';
update public.facilities
set external_permit_row_code = 'gym_auditorium'
where lower(trim(name::text)) = 'university auditorium';

alter table public.facility_amenities
  add column if not exists internal_permit_row_code text
    check (internal_permit_row_code in ('sound_system','overhead_projector','lcd_accessories','other')),
  add column if not exists external_permit_row_code text
    check (external_permit_row_code in ('gym_auditorium','tables_chairs','lcd_projector','avr','led_video_wall','accommodation','love_hall','other')),
  add column if not exists permit_quantity_required boolean not null default false;

update public.facility_amenities set internal_permit_row_code = 'sound_system'
where lower(trim(name::text)) = 'sound system';
update public.facility_amenities set internal_permit_row_code = 'overhead_projector'
where lower(trim(name::text)) = 'overhead projector';
update public.facility_amenities set internal_permit_row_code = 'lcd_accessories', external_permit_row_code = 'lcd_projector'
where lower(trim(name::text)) in ('lcd projector','lcd and accessories');
update public.facility_amenities set external_permit_row_code = 'tables_chairs', permit_quantity_required = true
where lower(trim(name::text)) in ('tables/chairs','tables and chairs','tables / chairs');
update public.facility_amenities set external_permit_row_code = 'led_video_wall'
where lower(trim(name::text)) = 'led video wall';

alter table public.reservation_requests
  add column if not exists requester_category text not null default 'external_renter'
    check (requester_category in ('student','faculty','staff','organization_representative','verified_internal_user','external_renter')),
  add column if not exists external_company_organization text,
  add column if not exists external_complete_address text,
  add column if not exists external_contact_numbers text[],
  add column if not exists external_admission_fee_centavos integer
    check (external_admission_fee_centavos is null or external_admission_fee_centavos >= 0);

update reservation_requests r set requester_category=case
  when r.admin_lane='external' then 'external_renter'
  when p.account_access_type='organization_representative' then 'organization_representative'
  when p.campus_claim in ('student','faculty','staff') then p.campus_claim
  else 'verified_internal_user' end,
  requester_unit=case when p.account_access_type='organization_representative' then coalesce((
    select ou.name from organization_account_slots os join organizational_units ou on ou.id=os.unit_id
    where os.id=p.organization_slot_id
  ),r.requester_unit) else r.requester_unit end
from profiles p where p.id=r.requester_id;

create table if not exists public.reservation_permit_items (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null references public.reservation_requests(id) on delete cascade,
  source_kind text not null check (source_kind in ('facility','amenity','requested_amenity')),
  source_id uuid,
  label text not null check (length(trim(label)) between 1 and 160),
  row_code text not null,
  requested_quantity integer check (requested_quantity is null or requested_quantity > 0),
  duration_minutes integer not null check (duration_minutes > 0),
  billing_basis text not null check (billing_basis in ('hourly','per_occurrence','per_reservation','included')),
  unit_amount_centavos integer not null default 0 check (unit_amount_centavos >= 0),
  line_total_centavos integer not null default 0 check (line_total_centavos >= 0),
  display_order integer not null default 0,
  unique(request_id, source_kind, source_id, label)
);
alter table public.reservation_permit_items enable row level security;
grant select on public.reservation_permit_items to authenticated;
create policy reservation_permit_items_read on public.reservation_permit_items
  for select to authenticated using (public.can_access_reservation(request_id));
revoke insert, update, delete on public.reservation_permit_items from authenticated;

create table if not exists public.permit_official_signature_revisions (
  id uuid primary key default gen_random_uuid(),
  slot text not null check (slot in ('internal_approver','external_recommender','external_authorized_official')),
  storage_path text not null unique,
  file_name text not null,
  mime_type text not null check (mime_type in ('image/png','image/jpeg')),
  byte_size integer not null check (byte_size between 1 and 5242880),
  sha256 text not null check (sha256 ~ '^[0-9a-f]{64}$'),
  active boolean not null default true,
  uploaded_by uuid not null references public.profiles(id) on delete restrict,
  uploaded_at timestamptz not null default now(),
  replaced_at timestamptz
);
create unique index if not exists permit_official_signature_one_active_idx
  on public.permit_official_signature_revisions(slot) where active;
alter table public.permit_official_signature_revisions enable row level security;
revoke all on public.permit_official_signature_revisions from anon, authenticated;

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values ('permit-official-signatures','permit-official-signatures',false,5242880,array['image/png','image/jpeg'])
on conflict(id) do update set public=false,file_size_limit=excluded.file_size_limit,allowed_mime_types=excluded.allowed_mime_types;

alter table public.reservation_signature_requests
  add column if not exists reservation_version integer,
  add column if not exists printable_content_hash text;
alter table public.reservation_user_signatures
  add column if not exists reservation_version integer,
  add column if not exists printable_content_hash text;

alter table public.reservation_permits
  add column if not exists template_kind text
    check (template_kind in ('internal','external')),
  add column if not exists template_sha256 text,
  add column if not exists generation_status text not null default 'pending'
    check (generation_status in ('pending','generating','ready','blocked_data','failed')),
  add column if not exists generation_error_code text,
  add column if not exists internal_approver_signature_id uuid references public.permit_official_signature_revisions(id) on delete restrict,
  add column if not exists external_recommender_signature_id uuid references public.permit_official_signature_revisions(id) on delete restrict,
  add column if not exists external_authorized_signature_id uuid references public.permit_official_signature_revisions(id) on delete restrict;

-- Existing permits used a recreated layout and signatures not bound to the
-- printable reservation version. They cannot be represented as official.
update public.reservation_permits
set status='superseded', generation_status='failed',
    generation_error_code='legacy_layout'
where status='active' and template_kind is null;
update public.reservation_signature_requests
set status='superseded', signed_at=null, superseded_at=coalesce(superseded_at,now())
where printable_content_hash is null and status in ('requested','signed');

-- Permit generation is service-owned. Authenticated users retain scoped read.
drop policy if exists reservation_permits_storage_insert on storage.objects;
drop policy if exists reservation_permits_storage_read on storage.objects;
create policy reservation_permits_storage_read on storage.objects
for select to authenticated using (
  bucket_id='reservation-permits' and exists(
    select 1 from public.reservation_permits p
    where p.storage_path=name and p.status='active' and p.generation_status='ready'
      and public.can_access_reservation(p.request_id)
  )
);
revoke insert, update, delete on public.reservation_permits from authenticated;
-- Retire the legacy authenticated metadata recorder. It allowed a caller to
-- attach bytes assembled outside the official-template generation function.
revoke all on function public.record_reservation_permit_pdf(uuid,text,text,integer)
  from public,anon,authenticated;

create or replace function public.permit_printable_material(p_request_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare r public.reservation_requests%rowtype; result jsonb;
begin
  select * into r from public.reservation_requests where id=p_request_id;
  if not found then raise exception using errcode='P0002',message='Reservation not found'; end if;
  select jsonb_build_object(
    'request_id',r.id,'requester_id',r.requester_id,'requester_name',r.requester_name,
    'requester_type',r.requester_category,'requester_unit',r.requester_unit,
    'admin_lane',r.admin_lane,'template_kind',r.admin_lane,
    'template_sha256',case r.admin_lane when 'internal' then '4732b1b07c455531615faa3de2b6e2dd2631ec2e4fa609c34ff99e241f64cb58'
      else 'bf328cc2b7eadafae9be130e2ec93342c05dea78a3579f1fccbb58ce1d5767aa' end,
    'facility_name',r.facility_name,'purpose',r.purpose,
    'headcount',r.headcount,'version',r.version,
    'external_company_organization',r.external_company_organization,
    'external_complete_address',r.external_complete_address,
    'external_contact_numbers',to_jsonb(r.external_contact_numbers),
    'external_admission_fee_centavos',r.external_admission_fee_centavos,
    'total_amount_centavos',r.total_amount_centavos,
    'occurrences',coalesce((select jsonb_agg(jsonb_build_object('starts_at',o.starts_at,'ends_at',o.ends_at) order by o.starts_at)
      from public.reservation_occurrences o where o.request_id=r.id and o.booking_state in ('held','booked','checked_in')), '[]'::jsonb),
    'items',coalesce((select jsonb_agg(jsonb_build_object(
      'row_code',i.row_code,'label',i.label,'requested_quantity',i.requested_quantity,
      'duration_minutes',i.duration_minutes,'billing_basis',i.billing_basis,
      'unit_amount_centavos',i.unit_amount_centavos,'line_total_centavos',i.line_total_centavos
    ) order by i.display_order,i.label) from public.reservation_permit_items i where i.request_id=r.id),'[]'::jsonb),
    'terms',coalesce((select jsonb_agg(jsonb_build_object('terms_version_id',a.terms_version_id,'content_hash',a.content_hash) order by a.terms_version_id)
      from public.reservation_terms_acceptances a where a.request_id=r.id),'[]'::jsonb)
  ) into result;
  return result;
end $$;
revoke all on function public.permit_printable_material(uuid) from public,anon,authenticated;
grant execute on function public.permit_printable_material(uuid) to service_role;

create or replace function public.permit_printable_hash(p_request_id uuid)
returns text language sql stable security definer set search_path=public as $$
  select encode(extensions.digest(public.permit_printable_material(p_request_id)::text,'sha256'),'hex')
$$;
revoke all on function public.permit_printable_hash(uuid) from public,anon,authenticated;
grant execute on function public.permit_printable_hash(uuid) to service_role;

create or replace function public.populate_reservation_permit_items(p_request_id uuid)
returns void language plpgsql security definer set search_path=public as $$
declare r public.reservation_requests%rowtype; duration_value integer; facility public.facilities%rowtype; line record; item record; ord integer:=0;
begin
  select * into r from reservation_requests where id=p_request_id;
  select * into facility from facilities where id=r.facility_id;
  select greatest(1,coalesce(sum(extract(epoch from (ends_at-starts_at))/60)::integer,1)) into duration_value
  from reservation_occurrences where request_id=r.id
    and booking_state in ('requested','held','booked','checked_in');
  delete from reservation_permit_items where request_id=r.id;
  select * into line from reservation_price_lines where request_id=r.id and line_type='facility' order by created_at limit 1;
  insert into reservation_permit_items(request_id,source_kind,source_id,label,row_code,duration_minutes,billing_basis,unit_amount_centavos,line_total_centavos,display_order)
  values(r.id,'facility',facility.id,r.facility_name,
    case r.admin_lane when 'internal' then 'facility:'||coalesce(facility.internal_permit_row_code,'unmapped') else 'external:'||coalesce(facility.external_permit_row_code,'unmapped') end,
    duration_value,'hourly',coalesce(line.unit_amount_centavos,0),coalesce(line.line_total_centavos,0),ord);
  for item in
    select a.*,fa.internal_permit_row_code,fa.external_permit_row_code,fa.permit_quantity_required,fa.pricing_unit
    from reservation_amenities a join facility_amenities fa on fa.id=a.facility_amenity_id
    where a.request_id=r.id order by a.name_snapshot
  loop
    ord:=ord+1;
    insert into reservation_permit_items(request_id,source_kind,source_id,label,row_code,requested_quantity,duration_minutes,billing_basis,unit_amount_centavos,line_total_centavos,display_order)
    values(r.id,'amenity',item.facility_amenity_id,item.name_snapshot,
      case r.admin_lane when 'internal' then 'equipment:'||coalesce(item.internal_permit_row_code,'unmapped') else 'external:'||coalesce(item.external_permit_row_code,'unmapped') end,
      case when item.permit_quantity_required then item.quantity else null end,duration_value,item.pricing_unit,
      item.unit_price_centavos,item.line_total_centavos,ord);
  end loop;
  for item in select value label from unnest(coalesce(r.amenities,'{}'::text[])) value
    where not exists(select 1 from reservation_permit_items pi where pi.request_id=r.id and lower(pi.label)=lower(value))
  loop
    ord:=ord+1;
    insert into reservation_permit_items(request_id,source_kind,label,row_code,duration_minutes,billing_basis,display_order)
    values(r.id,'requested_amenity',item.label,
      case r.admin_lane when 'internal' then
        case lower(item.label) when 'sound system' then 'equipment:sound_system' else 'equipment:unmapped' end
      else 'external:unmapped' end,duration_value,'included',ord);
  end loop;
end $$;
revoke all on function public.populate_reservation_permit_items(uuid) from public,anon,authenticated;
grant execute on function public.populate_reservation_permit_items(uuid) to service_role;

create or replace function public.get_reservation_permit_readiness(p_request_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare r reservation_requests%rowtype; blockers jsonb:='[]'::jsonb; paid integer; hash_value text; sig record;
begin
  if auth.uid() is null then raise exception using errcode='42501',message='Sign in required'; end if;
  select * into r from reservation_requests where id=p_request_id;
  if not found or (r.requester_id<>auth.uid() and not public.can_manage_reservation(r.id)) then
    raise exception using errcode='42501',message='Reservation access denied';
  end if;
  if r.admin_lane='internal' and r.reservation_status<>'confirmed' then blockers:=blockers||'"not_confirmed"'::jsonb; end if;
  if r.admin_lane='external' and r.reservation_status not in ('confirmed','completed') then blockers:=blockers||'"not_confirmed"'::jsonb; end if;
  select coalesce(sum(amount_centavos),0) into paid from payment_transactions where request_id=r.id and status='verified' and purpose<>'refund';
  if r.admin_lane='external' and paid<r.total_amount_centavos then blockers:=blockers||'"full_payment_required"'::jsonb; end if;
  if trim(r.requester_unit)='' and r.admin_lane='internal' then blockers:=blockers||'"requester_unit_required"'::jsonb; end if;
  if r.admin_lane='external' and (nullif(trim(r.external_company_organization),'') is null or nullif(trim(r.external_complete_address),'') is null
      or cardinality(coalesce(r.external_contact_numbers,'{}'))=0 or r.external_admission_fee_centavos is null) then
    blockers:=blockers||'"external_details_required"'::jsonb;
  end if;
  if not exists(select 1 from reservation_permit_items where request_id=r.id and source_kind='facility') then blockers:=blockers||'"permit_items_required"'::jsonb; end if;
  if exists(select 1 from reservation_permit_items where request_id=r.id and row_code like '%:unmapped') then blockers:=blockers||'"unmapped_permit_item"'::jsonb; end if;
  if not exists(select 1 from reservation_occurrences where request_id=r.id and booking_state in ('held','booked','checked_in')) then blockers:=blockers||'"schedule_required"'::jsonb; end if;
  if r.admin_lane='external' and (select count(*) from reservation_permit_items where request_id=r.id)>8 then blockers:=blockers||'"external_row_limit"'::jsonb; end if;
  if r.admin_lane='external' and exists(select 1 from reservation_permit_items where request_id=r.id group by row_code having count(*)>1) then blockers:=blockers||'"duplicate_external_row"'::jsonb; end if;
  if r.admin_lane='external' and exists(select 1 from reservation_permit_items where request_id=r.id and row_code='external:tables_chairs' and requested_quantity is null) then blockers:=blockers||'"item_quantity_required"'::jsonb; end if;
  hash_value:=public.permit_printable_hash(r.id);
  select s.id,s.printable_content_hash into sig from reservation_user_signatures s where s.request_id=r.id order by submitted_at desc limit 1;
  if sig.id is null or sig.printable_content_hash is distinct from hash_value then blockers:=blockers||'"requester_signature_required"'::jsonb; end if;
  if r.admin_lane='internal' and not exists(select 1 from permit_official_signature_revisions where slot='internal_approver' and active) then blockers:=blockers||'"internal_approver_signature_required"'::jsonb; end if;
  if r.admin_lane='external' and not exists(select 1 from permit_official_signature_revisions where slot='external_recommender' and active) then blockers:=blockers||'"external_recommender_signature_required"'::jsonb; end if;
  if r.admin_lane='external' and not exists(select 1 from permit_official_signature_revisions where slot='external_authorized_official' and active) then blockers:=blockers||'"external_authorized_signature_required"'::jsonb; end if;
  return jsonb_build_object('ready',jsonb_array_length(blockers)=0,'template_kind',r.admin_lane,'blockers',blockers,'printable_content_hash',hash_value);
end $$;
grant execute on function public.get_reservation_permit_readiness(uuid) to authenticated;

-- The deployed predecessor returned reservation_signature_requests while an
-- earlier checked-in revision returned void. PostgreSQL cannot change a
-- function return type through CREATE OR REPLACE, so replace this RPC
-- explicitly and restore its grant below.
drop function if exists public.request_reservation_signature(uuid);
create function public.request_reservation_signature(p_request_id uuid)
returns void language plpgsql security definer set search_path=public as $$
declare r reservation_requests%rowtype; actor uuid:=auth.uid(); hash_value text;
begin
  select * into r from reservation_requests where id=p_request_id for update;
  if not found or not public.can_manage_reservation(r.id) then raise exception 'Reservation management access required' using errcode='42501'; end if;
  if r.reservation_status not in ('awaiting_payment','confirmed') then raise exception 'A signature can be requested only after approval' using errcode='22023'; end if;
  if not exists(select 1 from reservation_permit_items where request_id=r.id) then
    perform public.populate_reservation_permit_items(r.id);
  end if;
  hash_value:=public.permit_printable_hash(r.id);
  if exists(select 1 from reservation_signature_requests where request_id=r.id and status='requested' and printable_content_hash=hash_value) then return; end if;
  update reservation_signature_requests set status='superseded',superseded_at=now() where request_id=r.id and status='requested';
  insert into reservation_signature_requests(request_id,requester_id,requested_by,reservation_version,printable_content_hash)
  values(r.id,r.requester_id,actor,r.version,hash_value);
  perform public.notify_reservation_user(r.id,public.reservation_event(r.id,'requested reservation e-signature'),
    'signature_requested','E-signature requested','Your approved reservation is ready for its reservation-specific signature.');
end $$;
grant execute on function public.request_reservation_signature(uuid) to authenticated;

-- The deployed predecessor returned reservation_user_signatures. Replace it
-- explicitly for the same return-type compatibility reason as the request RPC.
drop function if exists public.submit_reservation_signature(uuid,text,text,text,integer,text);
create function public.submit_reservation_signature(
  p_signature_request_id uuid,p_storage_path text,p_file_name text,p_mime_type text,p_byte_size integer,p_sha256 text
) returns void language plpgsql security definer set search_path=public as $$
declare sr reservation_signature_requests%rowtype; actor uuid:=auth.uid(); current_hash text;
begin
  select * into sr from reservation_signature_requests where id=p_signature_request_id for update;
  if not found or sr.requester_id<>actor or sr.status<>'requested' then raise exception 'This signature request is no longer available' using errcode='42501'; end if;
  current_hash:=public.permit_printable_hash(sr.request_id);
  if sr.printable_content_hash is distinct from current_hash then
    update reservation_signature_requests set status='superseded',superseded_at=now() where id=sr.id;
    raise exception 'Reservation details changed; request a new signature' using errcode='40001';
  end if;
  if p_mime_type not in ('image/png','image/jpeg') or p_byte_size not between 1 and 5242880 or split_part(p_storage_path,'/',1)<>actor::text or lower(p_sha256)!~'^[0-9a-f]{64}$' then
    raise exception 'Invalid signature upload' using errcode='22023';
  end if;
  insert into reservation_user_signatures(signature_request_id,request_id,requester_id,storage_path,file_name,mime_type,byte_size,sha256,reservation_version,printable_content_hash)
  values(sr.id,sr.request_id,actor,p_storage_path,p_file_name,p_mime_type,p_byte_size,lower(p_sha256),sr.reservation_version,current_hash);
  update reservation_signature_requests set status='signed',signed_at=now() where id=sr.id;
  perform public.notify_reservation_user(sr.request_id,public.reservation_event(sr.request_id,'submitted reservation e-signature'),
    'signature_submitted','E-signature submitted','Your signature was recorded for this reservation.');
end $$;
grant execute on function public.submit_reservation_signature(uuid,text,text,text,integer,text) to authenticated;

create or replace function public.prepare_reservation_permit(p_request_id uuid,p_actor_id uuid)
returns public.reservation_permits language plpgsql security definer set search_path=public as $$
declare r reservation_requests%rowtype; readiness jsonb; hash_value text; existing reservation_permits%rowtype; result reservation_permits%rowtype;
  next_version integer; material jsonb; user_sig reservation_user_signatures%rowtype; internal_sig uuid; recommender_sig uuid; authorized_sig uuid; template text; template_hash text;
begin
  if p_actor_id is null then raise exception using errcode='42501',message='Actor required'; end if;
  select * into r from reservation_requests where id=p_request_id for update;
  perform set_config('request.jwt.claim.sub',p_actor_id::text,true);
  if r.id is null or (r.requester_id<>p_actor_id and not public.can_manage_reservation(r.id)) then raise exception using errcode='42501',message='Reservation access denied'; end if;
  readiness:=public.get_reservation_permit_readiness(r.id);
  -- The Edge Function checks readiness before asking for an issuance row;
  -- this second check closes races with concurrent reservation changes.
  if not (readiness->>'ready')::boolean then return null; end if;
  hash_value:=readiness->>'printable_content_hash';
  select * into user_sig from reservation_user_signatures where request_id=r.id and printable_content_hash=hash_value order by submitted_at desc limit 1;
  template:=case r.admin_lane when 'internal' then 'internal' else 'external' end;
  template_hash:=case template when 'internal' then '4732b1b07c455531615faa3de2b6e2dd2631ec2e4fa609c34ff99e241f64cb58' else 'bf328cc2b7eadafae9be130e2ec93342c05dea78a3579f1fccbb58ce1d5767aa' end;
  select id into internal_sig from permit_official_signature_revisions where slot='internal_approver' and active;
  select id into recommender_sig from permit_official_signature_revisions where slot='external_recommender' and active;
  select id into authorized_sig from permit_official_signature_revisions where slot='external_authorized_official' and active;
  material:=public.permit_printable_material(r.id)||jsonb_build_object('template_kind',template,'template_sha256',template_hash,'user_signed_at',user_sig.submitted_at);
  select * into existing from reservation_permits where request_id=r.id and status='active';
  if found and existing.content_hash=hash_value and existing.template_sha256=template_hash then return existing; end if;
  if found then update reservation_permits set status='superseded' where id=existing.id; end if;
  select coalesce(max(version),0)+1 into next_version from reservation_permits where request_id=r.id;
  insert into reservation_permits(request_id,permit_number,version,status,verification_token,snapshot,content_hash,issued_by,
    template_kind,template_sha256,generation_status,user_signature_id,internal_approver_signature_id,external_recommender_signature_id,external_authorized_signature_id)
  values(r.id,'SR-'||to_char(now() at time zone 'Asia/Manila','YYYY')||'-'||lpad(nextval('reservation_permit_seq')::text,6,'0'),next_version,'active',
    encode(extensions.gen_random_bytes(16),'hex'),material,hash_value,p_actor_id,template,template_hash,'generating',user_sig.id,
    case when template='internal' then internal_sig end,case when template='external' then recommender_sig end,case when template='external' then authorized_sig end)
  returning * into result;
  return result;
end $$;
revoke all on function public.prepare_reservation_permit(uuid,uuid) from public,anon,authenticated;
grant execute on function public.prepare_reservation_permit(uuid,uuid) to service_role;

-- Compatibility no-op for older approval/payment functions. Generation is
-- exclusively initiated through the authenticated Edge Function above.
create or replace function public.issue_reservation_permit(p_request_id uuid)
returns public.reservation_permits language plpgsql security definer set search_path=public as $$
begin return null; end $$;
revoke all on function public.issue_reservation_permit(uuid) from public,anon,authenticated;

create or replace function public.record_generated_permit(p_permit_id uuid,p_storage_path text,p_sha256 text,p_byte_size integer)
returns public.reservation_permits language plpgsql security definer set search_path=public as $$
declare p reservation_permits%rowtype; r reservation_requests%rowtype; result reservation_permits%rowtype;
begin
  select * into p from reservation_permits where id=p_permit_id for update;
  select * into r from reservation_requests where id=p.request_id;
  if p.id is null or p.status<>'active' then raise exception 'Permit is no longer active' using errcode='22023'; end if;
  if p.generation_status='ready' then return p; end if;
  if p_storage_path<>r.requester_id::text||'/'||r.id::text||'/'||p.permit_number||'-v'||p.version::text||'.pdf' then raise exception 'Invalid permit path' using errcode='42501'; end if;
  if p_byte_size not between 1 and 10485760 or lower(p_sha256)!~'^[0-9a-f]{64}$' then raise exception 'Invalid permit file metadata' using errcode='22023'; end if;
  update reservation_permits set storage_path=p_storage_path,pdf_sha256=lower(p_sha256),pdf_byte_size=p_byte_size,pdf_generated_at=now(),generation_status='ready',generation_error_code=null
  where id=p.id returning * into result;
  insert into audit_entries(entity_type,entity_id,target_label,actor_id,actor_name,actor_role,action,source_type,source_id,details)
  select 'reservation',r.id,p.permit_number,p.issued_by,coalesce(nullif(profile.full_name,''),profile.email),profile.role,
    'embedded official signatures and generated permit','reservation_permit_generation',p.id,
    jsonb_build_object('template_kind',p.template_kind,'template_sha256',p.template_sha256,'pdf_sha256',lower(p_sha256),'byte_size',p_byte_size)
  from profiles profile where profile.id=p.issued_by
  on conflict(source_type,source_id) do nothing;
  perform public.notify_reservation_user(r.id,public.reservation_event(r.id,'issued official reservation permit',null,jsonb_build_object('permit_id',p.id),null,true),
    'permit_available','Your reservation permit is ready','Download and print your official permit and bring it on your reservation date.');
  return result;
end $$;
revoke all on function public.record_generated_permit(uuid,text,text,integer) from public,anon,authenticated;
grant execute on function public.record_generated_permit(uuid,text,text,integer) to service_role;

create or replace function public.mark_permit_generation_failed(p_request_id uuid,p_error text)
returns void language plpgsql security definer set search_path=public as $$
begin
  update reservation_permits set generation_status=case when coalesce(p_error,'') ilike '%fit%' then 'blocked_data' else 'failed' end,
    generation_error_code=left(coalesce(p_error,'generation_failed'),240)
  where request_id=p_request_id and status='active' and generation_status<>'ready';
end $$;
revoke all on function public.mark_permit_generation_failed(uuid,text) from public,anon,authenticated;
grant execute on function public.mark_permit_generation_failed(uuid,text) to service_role;

create or replace function public.auto_request_permit_signature_after_approval()
returns trigger language plpgsql security definer set search_path=public as $$
declare hash_value text; actor uuid;
begin
  if new.reservation_status not in ('awaiting_payment','confirmed')
     or old.reservation_status is not distinct from new.reservation_status then return new; end if;
  if not exists(select 1 from reservation_permit_items where request_id=new.id) then
    perform public.populate_reservation_permit_items(new.id);
  end if;
  hash_value:=public.permit_printable_hash(new.id);
  actor:=coalesce(auth.uid(),new.decided_by,new.requester_id);
  update reservation_signature_requests set status='superseded',superseded_at=now()
    where request_id=new.id and status='requested' and printable_content_hash is distinct from hash_value;
  if not exists(select 1 from reservation_signature_requests where request_id=new.id and status='requested' and printable_content_hash=hash_value) then
    insert into reservation_signature_requests(request_id,requester_id,requested_by,reservation_version,printable_content_hash)
    values(new.id,new.requester_id,actor,new.version,hash_value);
    perform public.notify_reservation_user(new.id,public.reservation_event(new.id,'requested reservation e-signature'),
      'signature_requested','E-signature requested','Your approved reservation is ready for its reservation-specific signature.');
  end if;
  return new;
end $$;

drop trigger if exists reservation_auto_request_permit_signature on public.reservation_requests;
create trigger reservation_auto_request_permit_signature
after update of reservation_status on public.reservation_requests
for each row execute function public.auto_request_permit_signature_after_approval();

create or replace function public.invalidate_permit_for_material_version_change()
returns trigger language plpgsql security definer set search_path=public as $$
declare hash_value text; actor uuid;
begin
  if old.version is not distinct from new.version then return new; end if;
  update reservation_signature_requests set status='superseded',signed_at=null,superseded_at=now()
    where request_id=new.id and status in ('requested','signed');
  update reservation_permits set status='superseded',generation_status='failed',generation_error_code='reservation_changed'
    where request_id=new.id and status='active';
  if new.reservation_status in ('awaiting_payment','confirmed') then
    if exists(select 1 from reservation_permit_items where request_id=new.id) then
      update reservation_permit_items set duration_minutes=greatest(1,coalesce((
        select sum(extract(epoch from (o.ends_at-o.starts_at))/60)::integer
        from reservation_occurrences o where o.request_id=new.id
      ),1)) where request_id=new.id;
    else
      perform public.populate_reservation_permit_items(new.id);
    end if;
    hash_value:=public.permit_printable_hash(new.id);
    actor:=coalesce(auth.uid(),new.decided_by,new.requester_id);
    insert into reservation_signature_requests(request_id,requester_id,requested_by,reservation_version,printable_content_hash)
    values(new.id,new.requester_id,actor,new.version,hash_value);
    perform public.notify_reservation_user(new.id,public.reservation_event(new.id,'requested reservation e-signature'),
      'signature_requested','E-signature requested','Reservation details changed. Please sign the updated reservation details.');
  end if;
  return new;
end $$;

drop trigger if exists reservation_invalidate_permit_version on public.reservation_requests;
create trigger reservation_invalidate_permit_version
after update of version on public.reservation_requests
for each row execute function public.invalidate_permit_for_material_version_change();

create or replace function public.record_official_permit_signature(
  p_slot text,p_storage_path text,p_file_name text,p_mime_type text,p_byte_size integer,p_sha256 text,p_actor_id uuid
) returns public.permit_official_signature_revisions language plpgsql security definer set search_path=public as $$
declare role_value text; result permit_official_signature_revisions;
begin
  select role into role_value from profiles where id=p_actor_id and account_status='active';
  if (p_slot='internal_approver' and role_value<>'internal_admin') or
     (p_slot in ('external_recommender','external_authorized_official') and role_value<>'external_admin') then
    raise exception 'This admin role cannot manage that signature slot' using errcode='42501';
  end if;
  if p_slot not in ('internal_approver','external_recommender','external_authorized_official') or p_mime_type not in ('image/png','image/jpeg')
     or p_byte_size not between 1 and 5242880 or lower(p_sha256)!~'^[0-9a-f]{64}$' then raise exception 'Invalid signature upload' using errcode='22023'; end if;
  update permit_official_signature_revisions set active=false,replaced_at=now() where slot=p_slot and active;
  insert into permit_official_signature_revisions(slot,storage_path,file_name,mime_type,byte_size,sha256,uploaded_by)
  values(p_slot,p_storage_path,p_file_name,p_mime_type,p_byte_size,lower(p_sha256),p_actor_id) returning * into result;
  insert into audit_entries(entity_type,target_label,actor_id,actor_name,actor_role,action,source_type,source_id,details)
  select 'system','Official permit signature',p_actor_id,coalesce(nullif(full_name,''),email),role,
    'replaced official permit signature','permit_official_signature_revision',result.id,jsonb_build_object('slot',p_slot)
  from profiles where id=p_actor_id;
  return result;
end $$;
revoke all on function public.record_official_permit_signature(text,text,text,text,integer,text,uuid) from public,anon,authenticated;
grant execute on function public.record_official_permit_signature(text,text,text,text,integer,text,uuid) to service_role;

-- Preserve the immutable quote rule, but permit the v3 submission wrapper to
-- normalize every internal-lane reservation to a free reservation.
create or replace function public.protect_reservation_quote_snapshot()
returns trigger language plpgsql set search_path=public as $$
begin
  if current_setting('app.internal_price_normalization',true)='on' and old.admin_lane='internal' then return new; end if;
  if new.admin_lane is distinct from old.admin_lane or new.pricing_audience is distinct from old.pricing_audience
      or new.currency is distinct from old.currency or new.facility_amount_centavos is distinct from old.facility_amount_centavos
      or new.amenity_amount_centavos is distinct from old.amenity_amount_centavos or new.discount_amount_centavos is distinct from old.discount_amount_centavos
      or new.total_amount_centavos is distinct from old.total_amount_centavos or new.required_down_payment_centavos is distinct from old.required_down_payment_centavos
      or new.pricing_fingerprint is distinct from old.pricing_fingerprint then
    raise exception using errcode='22023',message='Reservation lane and pricing snapshots are immutable';
  end if;
  return new;
end $$;

alter table public.reservation_requests drop constraint if exists reservation_requests_payment_exemption_check;
alter table public.reservation_requests add constraint reservation_requests_payment_exemption_check
  check (payment_exemption in ('none','verified_student','verified_faculty','internal_user'));

select set_config('app.internal_price_normalization','on',true);
update reservation_requests set payment_amount_centavos=0,payment_status='not_required',
  facility_amount_centavos=0,amenity_amount_centavos=0,discount_amount_centavos=0,
  total_amount_centavos=0,required_down_payment_centavos=0,payment_exemption='internal_user'
where admin_lane='internal';
update reservation_price_lines l set unit_amount_centavos=0,line_total_centavos=0
where exists(select 1 from reservation_requests r where r.id=l.request_id and r.admin_lane='internal');

do $$ declare request_row record; begin
  for request_row in select id from reservation_requests loop
    if not exists(select 1 from reservation_permit_items where request_id=request_row.id) then
      perform public.populate_reservation_permit_items(request_row.id);
    end if;
  end loop;
end $$;

insert into reservation_signature_requests(
  request_id,requester_id,requested_by,reservation_version,printable_content_hash
)
select r.id,r.requester_id,coalesce(r.decided_by,r.requester_id),r.version,
  public.permit_printable_hash(r.id)
from reservation_requests r
where r.reservation_status in ('awaiting_payment','confirmed')
  and not exists(select 1 from reservation_signature_requests s
    where s.request_id=r.id and s.status='requested');

create or replace function public.submit_reservation_v3(
  p_request_id uuid,p_facility_id uuid,p_purpose text,p_headcount integer,p_starts_at timestamptz[],p_ends_at timestamptz[],
  p_amenity_ids uuid[] default '{}'::uuid[],p_terms_version_ids uuid[] default '{}'::uuid[],p_pricing_fingerprint text default null,
  p_attachment_metadata jsonb default '[]'::jsonb,p_requested_amenities text[] default '{}'::text[],p_discount_claim_id uuid default null,
  p_external_company_organization text default null,p_external_complete_address text default null,
  p_external_contact_numbers text[] default null,p_external_admission_fee_centavos integer default null,
  p_item_quantities jsonb default '{}'::jsonb
) returns public.reservation_requests language plpgsql security definer set search_path=public,storage as $$
declare result reservation_requests%rowtype; category text;
begin
  result:=public.submit_reservation_v2(p_request_id,p_facility_id,p_purpose,p_headcount,p_starts_at,p_ends_at,p_amenity_ids,
    p_terms_version_ids,p_pricing_fingerprint,p_attachment_metadata,p_requested_amenities,p_discount_claim_id);
  if result.admin_lane='external' then
    if nullif(trim(p_external_company_organization),'') is null or nullif(trim(p_external_complete_address),'') is null
       or cardinality(coalesce(p_external_contact_numbers,'{}'))=0 or p_external_admission_fee_centavos is null or p_external_admission_fee_centavos<0 then
      raise exception 'Complete all external permit details' using errcode='22023';
    end if;
    category:='external_renter';
  else
    select case when p.account_access_type='organization_representative' then 'organization_representative'
      when p.campus_claim in ('student','faculty','staff') then p.campus_claim else 'verified_internal_user' end
    into category from profiles p where p.id=result.requester_id;
    perform set_config('app.internal_price_normalization','on',true);
    update reservation_requests set payment_amount_centavos=0,payment_status='not_required',facility_amount_centavos=0,
      amenity_amount_centavos=0,discount_amount_centavos=0,total_amount_centavos=0,required_down_payment_centavos=0,
      payment_exemption='internal_user' where id=result.id returning * into result;
    update reservation_price_lines set unit_amount_centavos=0,line_total_centavos=0 where request_id=result.id;
  end if;
  update reservation_requests set requester_category=category,
    requester_unit=case when category='organization_representative' then coalesce((
      select ou.name from profiles p join organization_account_slots os on os.id=p.organization_slot_id
      join organizational_units ou on ou.id=os.unit_id where p.id=result.requester_id
    ),result.requester_unit) else result.requester_unit end,
    external_company_organization=case when result.admin_lane='external' then trim(p_external_company_organization) end,
    external_complete_address=case when result.admin_lane='external' then trim(p_external_complete_address) end,
    external_contact_numbers=case when result.admin_lane='external' then p_external_contact_numbers end,
    external_admission_fee_centavos=case when result.admin_lane='external' then p_external_admission_fee_centavos end
  where id=result.id returning * into result;
  perform public.populate_reservation_permit_items(result.id);
  update reservation_permit_items i set requested_quantity=(p_item_quantities->>i.source_id::text)::integer
  where i.request_id=result.id and i.row_code='external:tables_chairs'
    and p_item_quantities ? i.source_id::text
    and (p_item_quantities->>i.source_id::text) ~ '^[1-9][0-9]*$';
  if result.admin_lane='external' and exists(
    select 1 from reservation_permit_items where request_id=result.id
      and row_code='external:tables_chairs' and requested_quantity is null
  ) then raise exception 'Enter the requested tables/chairs quantity' using errcode='22023'; end if;
  return result;
end $$;
revoke all on function public.submit_reservation_v3(uuid,uuid,text,integer,timestamptz[],timestamptz[],uuid[],uuid[],text,jsonb,text[],uuid,text,text,text[],integer,jsonb) from public,anon;
grant execute on function public.submit_reservation_v3(uuid,uuid,text,integer,timestamptz[],timestamptz[],uuid[],uuid[],text,jsonb,text[],uuid,text,text,text[],integer,jsonb) to authenticated;

create or replace function public.update_external_permit_details(
  p_request_id uuid,p_company_organization text,p_complete_address text,
  p_contact_numbers text[],p_admission_fee_centavos integer
) returns void language plpgsql security definer set search_path=public as $$
declare r reservation_requests%rowtype;
begin
  select * into r from reservation_requests where id=p_request_id for update;
  if not found or r.requester_id<>auth.uid() or r.admin_lane<>'external' then
    raise exception 'External reservation access required' using errcode='42501';
  end if;
  if r.reservation_status not in ('pending_approval','changes_requested','awaiting_payment','confirmed') then
    raise exception 'Permit details can no longer be changed' using errcode='22023';
  end if;
  if nullif(trim(p_company_organization),'') is null or length(trim(p_company_organization))>120
     or nullif(trim(p_complete_address),'') is null or length(trim(p_complete_address))>110
     or cardinality(coalesce(p_contact_numbers,'{}'))=0 or cardinality(p_contact_numbers)>4
     or p_admission_fee_centavos is null or p_admission_fee_centavos<0 then
    raise exception 'Enter complete external permit details that fit the official form' using errcode='22023';
  end if;
  update reservation_requests set external_company_organization=trim(p_company_organization),
    external_complete_address=trim(p_complete_address),
    external_contact_numbers=array(select trim(value) from unnest(p_contact_numbers) value where trim(value)<>''),
    external_admission_fee_centavos=p_admission_fee_centavos,version=version+1
  where id=r.id;
end $$;
revoke all on function public.update_external_permit_details(uuid,text,text,text[],integer) from public,anon;
grant execute on function public.update_external_permit_details(uuid,text,text,text[],integer) to authenticated;

create or replace function public.save_facility_configuration_v3(
  p_facility_id uuid,p_rates jsonb,p_amenities jsonb,p_account_name text,p_account_number text,
  p_instructions text default '',p_deposit_window_minutes integer default 1440,
  p_balance_due_lead_minutes integer default 1440,p_correction_window_minutes integer default 1440,
  p_down_payment_percent integer default 50,p_internal_permit_row_code text default null,
  p_external_permit_row_code text default null
) returns jsonb language plpgsql security definer set search_path=public as $$
declare result jsonb; item jsonb;
begin
  if p_internal_permit_row_code not in ('audio_visual_main_hall','conference_room','other')
     or p_external_permit_row_code not in ('gym_auditorium','avr','accommodation','love_hall','other') then
    raise exception 'Select explicit internal and external facility permit rows' using errcode='22023';
  end if;
  for item in select value from jsonb_array_elements(coalesce(p_amenities,'[]'::jsonb)) loop
    if item->>'internal_permit_row_code' not in ('sound_system','overhead_projector','lcd_accessories','other')
       or item->>'external_permit_row_code' not in ('tables_chairs','lcd_projector','avr','led_video_wall','accommodation','love_hall','other') then
      raise exception 'Every amenity needs explicit internal and external permit-row mappings' using errcode='22023';
    end if;
  end loop;
  result:=public.save_facility_configuration_v2(p_facility_id,p_rates,p_amenities,p_account_name,p_account_number,
    p_instructions,p_deposit_window_minutes,p_balance_due_lead_minutes,p_correction_window_minutes,p_down_payment_percent);
  update facilities set internal_permit_row_code=p_internal_permit_row_code,
    external_permit_row_code=p_external_permit_row_code where id=p_facility_id;
  for item in select value from jsonb_array_elements(coalesce(p_amenities,'[]'::jsonb)) loop
    update facility_amenities set internal_permit_row_code=item->>'internal_permit_row_code',
      external_permit_row_code=item->>'external_permit_row_code',
      permit_quantity_required=coalesce((item->>'permit_quantity_required')::boolean,false)
    where facility_id=p_facility_id and lower(name)=lower(trim(item->>'name'));
  end loop;
  return result;
end $$;
revoke all on function public.save_facility_configuration_v3(uuid,jsonb,jsonb,text,text,text,integer,integer,integer,integer,text,text) from public,anon;
grant execute on function public.save_facility_configuration_v3(uuid,jsonb,jsonb,text,text,text,integer,integer,integer,integer,text,text) to authenticated;

notify pgrst,'reload schema';
