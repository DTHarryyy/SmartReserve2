create or replace function public.capture_account_audit()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  actor public.profiles%rowtype;
  noise_keys constant text[] := array['id', 'created_at', 'updated_at'];
begin
  select * into actor from public.profiles where id = new.actor_id;
  insert into public.audit_entries(
    entity_type, entity_id, target_label, actor_id, actor_name, actor_role,
    action, reason, before_values, after_values, material,
    source_type, source_id, created_at
  ) values (
    'account', new.target_id, new.target_email, new.actor_id,
    coalesce(nullif(actor.full_name, ''), actor.email, 'System'),
    coalesce(actor.role, 'system'), replace(new.action, '_', ' '), new.reason,
    new.before_values - noise_keys, new.after_values - noise_keys, true,
    'account_admin_event', new.id, new.created_at
  ) on conflict (source_type, source_id) do nothing;
  return new;
end;
$$;

create or replace function public.capture_facility_audit()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  actor public.profiles%rowtype;
  actor_id_value uuid := auth.uid();
  action_value text;
  reason_value text := nullif(current_setting('smartreserve.audit_reason', true), '');
  material_value boolean := true;
  noise_keys constant text[] := array['id', 'created_at', 'updated_by', 'updated_by_name'];
begin
  select * into actor from public.profiles where id = actor_id_value;
  if tg_op = 'INSERT' then
    action_value := 'created';
  elsif old.archived_at is null and new.archived_at is not null then
    action_value := 'archived';
  elsif old.archived_at is not null and new.archived_at is null then
    action_value := 'restored';
  else
    action_value := 'updated';
    material_value := old.capacity is distinct from new.capacity
      or old.status is distinct from new.status
      or old.latitude is distinct from new.latitude
      or old.longitude is distinct from new.longitude
      or old.public_listing is distinct from new.public_listing
      or old.archived_at is distinct from new.archived_at;
  end if;
  insert into public.audit_entries(
    entity_type, entity_id, target_label, actor_id, actor_name, actor_role,
    action, reason, before_values, after_values, material, source_type, source_id
  ) values (
    'facility', new.id, new.name::text, actor_id_value,
    coalesce(nullif(actor.full_name, ''), actor.email, new.updated_by_name, 'System'),
    coalesce(actor.role, 'system'), action_value, reason_value,
    case when tg_op = 'INSERT' then '{}'::jsonb else to_jsonb(old) - noise_keys end,
    to_jsonb(new) - noise_keys, material_value, 'facility_change', gen_random_uuid()
  );
  return new;
end;
$$;

create or replace function public.get_audit_entries(
  p_search text default null,
  p_actor text default null,
  p_entity_type text default null,
  p_material_only boolean default false,
  p_from timestamptz default null,
  p_to timestamptz default null,
  p_before_created_at timestamptz default null,
  p_before_id uuid default null,
  p_limit integer default 50
) returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  result_value jsonb;
begin
  if not public.is_internal_admin() then
    raise exception using errcode = '42501', message = 'Internal administrator access required';
  end if;
  if p_limit not between 1 and 200 then
    raise exception using errcode = '22023', message = 'Invalid page size';
  end if;
  with filtered as (
    select a.*, p.email as actor_email
    from public.audit_entries a
    left join public.profiles p on p.id = a.actor_id
    where (nullif(trim(p_search), '') is null or concat_ws(' ', a.actor_name, a.target_label, a.action, a.reason, a.details::text, a.before_values::text, a.after_values::text) ilike '%' || trim(p_search) || '%')
      and (p_actor is null or a.actor_name = p_actor)
      and (p_entity_type is null or a.entity_type = p_entity_type)
      and (not p_material_only or a.material)
      and (p_from is null or a.created_at >= p_from)
      and (p_to is null or a.created_at < p_to)
  ), page as (
    select * from filtered
    where p_before_created_at is null
      or (created_at, id) < (p_before_created_at, p_before_id)
    order by created_at desc, id desc
    limit p_limit
  )
  select jsonb_build_object(
    'rows', coalesce((select jsonb_agg(to_jsonb(page) || jsonb_build_object(
      'revertable', entity_type = 'facility' and action = 'updated'
    ) order by created_at desc, id desc) from page), '[]'::jsonb),
    'total', (select count(*) from filtered),
    'actors', coalesce((select jsonb_agg(actor_name order by actor_name) from (select distinct actor_name from filtered) actors), '[]'::jsonb)
  ) into result_value;
  return result_value;
end;
$$;

grant execute on function public.get_audit_entries(text,text,text,boolean,timestamptz,timestamptz,timestamptz,uuid,integer) to authenticated;

notify pgrst, 'reload schema';
