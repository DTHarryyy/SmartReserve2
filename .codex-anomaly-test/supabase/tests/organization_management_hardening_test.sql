begin;

create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(9);

select has_function(
  'public', 'organization_representative_slot_preflight', array['uuid', 'uuid'],
  'service-side representative slot preflight exists'
);
select has_function(
  'public', 'provision_organization_representative_profile_v2',
  array['uuid', 'uuid', 'text', 'text', 'uuid'],
  'versioned representative provisioning function exists'
);
select has_function(
  'public', 'restore_organization_unit_policy', array['uuid'],
  'organization restore function exists'
);

select ok(
  has_function_privilege(
    'service_role',
    'public.organization_representative_slot_preflight(uuid,uuid)',
    'execute'
  ),
  'service role can preflight representative slots'
);
select ok(
  has_function_privilege(
    'service_role',
    'public.provision_organization_representative_profile_v2(uuid,uuid,text,text,uuid)',
    'execute'
  ),
  'service role can provision representative profiles'
);
select ok(
  has_function_privilege(
    'service_role',
    'public.record_organization_representative_password_reset(uuid,uuid)',
    'execute'
  ),
  'service role can record representative password resets'
);
select isnt(
  has_function_privilege(
    'authenticated',
    'public.provision_organization_representative_profile_v2(uuid,uuid,text,text,uuid)',
    'execute'
  ),
  true,
  'regular sessions cannot provision representative profiles'
);
select isnt(
  has_function_privilege(
    'anon',
    'public.organization_representative_slot_preflight(uuid,uuid)',
    'execute'
  ),
  true,
  'anonymous sessions cannot inspect representative slots'
);
select ok(
  has_function_privilege(
    'authenticated',
    'public.restore_organization_unit_policy(uuid)',
    'execute'
  ),
  'authenticated internal-admin sessions can reach restore policy checks'
);

select * from finish();
rollback;
