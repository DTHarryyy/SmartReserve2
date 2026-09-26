begin;
select plan(8);

select has_function(
  'public', 'get_reservation_permit_configuration', array['uuid'],
  'reservation-specific mapping readiness is exposed'
);
select has_function(
  'public', 'save_reservation_permit_mappings', array['uuid', 'jsonb'],
  'focused mapping repair RPC exists'
);
select has_function(
  'public', 'deliver_reservation_permit', array['uuid'],
  'persisted permit delivery RPC exists'
);
select has_column(
  'public', 'reservation_permits', 'delivery_status',
  'permit delivery status is persisted'
);
select has_column(
  'public', 'reservation_permits', 'delivered_at',
  'permit delivery timestamp is persisted'
);
select is(
  (select has_function_privilege(
    'anon', 'public.save_reservation_permit_mappings(uuid,jsonb)', 'EXECUTE'
  )),
  false,
  'anonymous callers cannot repair permit mappings'
);
select is(
  (select has_function_privilege(
    'anon', 'public.deliver_reservation_permit(uuid)', 'EXECUTE'
  )),
  false,
  'anonymous callers cannot deliver permits'
);
select like(
  pg_get_functiondef(
    'public.request_reservation_signature(uuid)'::regprocedure
  ),
  '%Complete the required facility permit mappings%',
  'signature requests are gated by permit mappings'
);

select * from finish();
rollback;
