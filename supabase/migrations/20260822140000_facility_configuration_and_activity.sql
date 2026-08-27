-- Transactional facility commercial configuration, owner assignment directory,
-- and assigned-admin facility activity.

create or replace function public.facility_assignment_directory(p_facility_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare result_value jsonb;
begin
  if not public.is_facility_owner(p_facility_id) then
    raise exception using errcode = '42501', message = 'Facility owner access required';
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'admin_id', p.id,
    'name', coalesce(nullif(p.full_name, ''), p.email),
    'email', p.email,
    'admin_lane', case p.role
      when 'internal_admin' then 'internal' else 'external' end,
    'assignment_role', a.assignment_role
  ) order by p.role, p.full_name, p.email), '[]'::jsonb)
  into result_value
  from public.profiles p
  left join public.facility_admin_assignments a
    on a.facility_id = p_facility_id and a.admin_id = p.id
  where p.role in ('internal_admin', 'external_admin')
    and p.account_status = 'active';
  return result_value;
end;
$$;

revoke all on function public.facility_assignment_directory(uuid) from public, anon;
grant execute on function public.facility_assignment_directory(uuid) to authenticated;

create or replace function public.save_facility_configuration(
  p_facility_id uuid,
  p_rates jsonb,
  p_amenities jsonb,
  p_account_name text,
  p_account_number text,
  p_instructions text default '',
  p_deposit_window_minutes integer default 1440,
  p_balance_due_lead_days integer default 3,
  p_correction_window_minutes integer default 1440
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  rate_item jsonb;
  amenity_item jsonb;
  method_id uuid;
  facility_name text;
  actor public.profiles%rowtype;
begin
  perform 1
  from public.facility_admin_assignments a
  join public.profiles p on p.id = a.admin_id
  where a.facility_id = p_facility_id and a.admin_id = auth.uid()
    and p.role in ('internal_admin','external_admin')
    and p.account_status = 'active'
  for share of a, p;
  if not found then
    raise exception using errcode = '42501', message = 'Assigned facility access required';
  end if;
  if jsonb_typeof(p_rates) <> 'array'
      or jsonb_array_length(p_rates) <> 4
      or (select count(distinct value->>'audience')
          from jsonb_array_elements(p_rates)) <> 4 then
    raise exception using errcode = '22023',
      message = 'Provide one rate for student, faculty, staff, and guest';
  end if;
  if p_amenities is not null and jsonb_typeof(p_amenities) <> 'array' then
    raise exception using errcode = '22023', message = 'Amenities must be a list';
  end if;
  if jsonb_array_length(coalesce(p_amenities, '[]'::jsonb)) <>
      (select count(distinct lower(trim(value->>'name')))
       from jsonb_array_elements(coalesce(p_amenities, '[]'::jsonb))) then
    raise exception using errcode = '22023', message = 'Amenity names must be unique';
  end if;
  if p_deposit_window_minutes not between 30 and 10080
      or p_balance_due_lead_days not between 0 and 90
      or p_correction_window_minutes not between 30 and 10080 then
    raise exception using errcode = '22023', message = 'Invalid payment deadline settings';
  end if;

  for rate_item in select value from jsonb_array_elements(p_rates) loop
    if rate_item->>'audience' not in ('student','faculty','staff','guest')
        or (rate_item->>'hourly_rate_centavos')::integer < 0 then
      raise exception using errcode = '22023', message = 'Invalid audience rate';
    end if;
    insert into public.facility_rates(
      facility_id, audience, hourly_rate_centavos, enabled
    ) values (
      p_facility_id,
      rate_item->>'audience',
      (rate_item->>'hourly_rate_centavos')::integer,
      true
    )
    on conflict (facility_id, audience) do update
      set hourly_rate_centavos = excluded.hourly_rate_centavos,
          enabled = true,
          updated_at = now(),
          updated_by = auth.uid();
  end loop;

  update public.facility_amenities
  set enabled = false, updated_at = now(), updated_by = auth.uid()
  where facility_id = p_facility_id;
  for amenity_item in
    select value from jsonb_array_elements(coalesce(p_amenities, '[]'::jsonb))
  loop
    if length(trim(coalesce(amenity_item->>'name', ''))) not between 2 and 80
        or coalesce((amenity_item->>'price_centavos')::integer, -1) < 0
        or coalesce(amenity_item->>'pricing_unit', '')
          not in ('per_reservation','per_occurrence') then
      raise exception using errcode = '22023', message = 'Invalid facility amenity';
    end if;
    insert into public.facility_amenities(
      facility_id, name, description, price_centavos, pricing_unit, enabled
    ) values (
      p_facility_id,
      trim(amenity_item->>'name'),
      coalesce(amenity_item->>'description', ''),
      (amenity_item->>'price_centavos')::integer,
      amenity_item->>'pricing_unit',
      true
    )
    on conflict (facility_id, name) do update set
      description = excluded.description,
      price_centavos = excluded.price_centavos,
      pricing_unit = excluded.pricing_unit,
      enabled = true,
      updated_at = now(),
      updated_by = auth.uid();
  end loop;

  update public.facilities
  set deposit_window_minutes = p_deposit_window_minutes,
      balance_due_lead_days = p_balance_due_lead_days,
      payment_correction_window_minutes = p_correction_window_minutes,
      amenities = array(
        select (value->>'name')::text
        from jsonb_array_elements(coalesce(p_amenities, '[]'::jsonb))
      ),
      updated_at = now(),
      updated_by = auth.uid()
  where id = p_facility_id
  returning name::text into facility_name;

  if nullif(trim(coalesce(p_account_name, '')), '') is not null
      or nullif(trim(coalesce(p_account_number, '')), '') is not null then
    if length(trim(coalesce(p_account_name, ''))) < 2
        or length(regexp_replace(coalesce(p_account_number, ''), '[^0-9]', '', 'g'))
          not between 10 and 15 then
      raise exception using errcode = '22023', message = 'Enter a valid GCash destination';
    end if;
    select id into method_id
    from public.facility_payment_methods
    where facility_id = p_facility_id and method_type = 'gcash' and enabled
    for update;
    if method_id is not null and exists(
      select 1 from public.facility_payment_methods m
      where m.id = method_id
        and m.account_name = trim(p_account_name)
        and m.account_number = trim(p_account_number)
        and m.instructions = trim(coalesce(p_instructions, ''))
    ) then
      null;
    else
      if method_id is not null then
        update public.facility_payment_methods
        set enabled = false, updated_at = now(), updated_by = auth.uid()
        where id = method_id;
      end if;
      insert into public.facility_payment_methods(
        facility_id, account_name, account_number, instructions
      ) values (
        p_facility_id, trim(p_account_name), trim(p_account_number),
        trim(coalesce(p_instructions, ''))
      ) returning id into method_id;
    end if;
  end if;

  select * into actor from public.profiles where id = auth.uid();
  insert into public.audit_entries(
    entity_type, entity_id, target_label, actor_id, actor_name, actor_role,
    action, details, material, source_type, source_id
  ) values (
    'facility', p_facility_id, facility_name, auth.uid(),
    coalesce(nullif(actor.full_name, ''), actor.email), actor.role,
    'updated pricing, amenities, and payment settings',
    jsonb_build_object(
      'rates', p_rates,
      'amenity_count', jsonb_array_length(coalesce(p_amenities, '[]'::jsonb)),
      'deposit_window_minutes', p_deposit_window_minutes,
      'balance_due_lead_days', p_balance_due_lead_days
      ,'correction_window_minutes', p_correction_window_minutes
    ), true, 'facility_configuration', gen_random_uuid()
  );

  return jsonb_build_object('facility_id', p_facility_id, 'payment_method_id', method_id);
end;
$$;

revoke all on function public.save_facility_configuration(
  uuid, jsonb, jsonb, text, text, text, integer, integer, integer
) from public, anon;
grant execute on function public.save_facility_configuration(
  uuid, jsonb, jsonb, text, text, text, integer, integer, integer
) to authenticated;

drop policy if exists audit_entries_select_internal_admin on public.audit_entries;
create policy audit_entries_select_authorized
on public.audit_entries for select to authenticated
using (
  public.is_internal_admin()
  or (entity_type = 'facility' and entity_id is not null
      and public.can_manage_facility(entity_id))
  or (entity_type = 'reservation' and entity_id is not null
      and public.can_manage_reservation(entity_id))
);

create or replace function public.capture_facility_configuration_audit()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  row_value jsonb := case when tg_op = 'DELETE' then to_jsonb(old) else to_jsonb(new) end;
  facility_value uuid := (row_value->>'facility_id')::uuid;
  actor public.profiles%rowtype;
  facility_name text;
begin
  select * into actor from public.profiles where id = auth.uid();
  select name::text into facility_name from public.facilities where id = facility_value;
  insert into public.audit_entries(
    entity_type, entity_id, target_label, actor_id, actor_name, actor_role,
    action, details, material, source_type, source_id
  ) values (
    'facility', facility_value, coalesce(facility_name, 'Facility'), auth.uid(),
    coalesce(nullif(actor.full_name, ''), actor.email, 'System'),
    coalesce(actor.role, 'system'),
    lower(tg_op) || ' ' || replace(tg_table_name, '_', ' '),
    jsonb_build_object(
      'table', tg_table_name,
      'record_id', coalesce(row_value->>'id', row_value->>'admin_id'),
      'assignment_role', row_value->>'assignment_role',
      'audience', row_value->>'audience'
    ),
    true, 'facility_configuration_row', gen_random_uuid()
  );
  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$$;

drop trigger if exists facility_assignments_capture_audit
  on public.facility_admin_assignments;
create trigger facility_assignments_capture_audit
after insert or update or delete on public.facility_admin_assignments
for each row execute function public.capture_facility_configuration_audit();

drop trigger if exists facility_rates_capture_audit on public.facility_rates;
create trigger facility_rates_capture_audit
after insert or update or delete on public.facility_rates
for each row execute function public.capture_facility_configuration_audit();

drop trigger if exists facility_amenities_capture_audit on public.facility_amenities;
create trigger facility_amenities_capture_audit
after insert or update or delete on public.facility_amenities
for each row execute function public.capture_facility_configuration_audit();

drop trigger if exists facility_payment_methods_capture_audit
  on public.facility_payment_methods;
create trigger facility_payment_methods_capture_audit
after insert or update or delete on public.facility_payment_methods
for each row execute function public.capture_facility_configuration_audit();

notify pgrst, 'reload schema';
