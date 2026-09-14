begin;
create extension if not exists pgtap with schema extensions;
set search_path=public,extensions;
select plan(22);

select has_table('public','reservation_permit_items','frozen permit items exist');
select has_column('public','reservation_requests','external_company_organization',
  'reservation requests store the external company or organization');
select has_column('public','reservation_requests','external_complete_address',
  'reservation requests store the external complete address');
select has_column('public','reservation_requests','external_contact_numbers',
  'reservation requests store external contact numbers');
select has_column('public','reservation_requests','external_admission_fee_centavos',
  'reservation requests store the external admission fee');
select has_column('public','reservation_permits','template_kind',
  'permits record their official template kind');
select has_column('public','reservation_permits','template_sha256',
  'permits bind the official template hash');
select has_column('public','reservation_permits','generation_status',
  'permits expose their generation status');
select has_column('public','reservation_permits','internal_approver_signature_id',
  'internal permits bind the approver signature revision');
select has_column('public','reservation_permits','external_recommender_signature_id',
  'external permits bind the recommender signature revision');
select has_column('public','reservation_permits','external_authorized_signature_id',
  'external permits bind the authorized-official signature revision');
select has_function('public','get_reservation_permit_readiness',array['uuid']);
select has_function('public','issue_reservation_permit',array['uuid']);
select has_function('public','prepare_reservation_permit',array['uuid','uuid']);
select has_function('public','record_generated_permit',array['uuid','text','text','integer']);
select has_function('public','update_external_permit_details',array['uuid','text','text','text[]','integer']);
select has_function('public','submit_reservation_v3',array[
  'uuid','uuid','text','integer','timestamp with time zone[]','timestamp with time zone[]',
  'uuid[]','uuid[]','text','jsonb','text[]','uuid','text','text','text[]','integer','jsonb'
], 'the required v3 reservation submission contract exists');
select ok(has_function_privilege('authenticated',
  'public.submit_reservation_v3(uuid,uuid,text,integer,timestamptz[],timestamptz[],uuid[],uuid[],text,jsonb,text[],uuid,text,text,text[],integer,jsonb)',
  'EXECUTE'), 'authenticated requesters can execute the v3 submission contract');
select is((select count(*) from pg_policies where schemaname='storage' and tablename='objects'
  and policyname='reservation_permits_storage_insert'),0::bigint,
  'authenticated clients have no final-PDF upload policy');
select ok(not has_function_privilege('authenticated',
  'public.record_reservation_permit_pdf(uuid,text,text,integer)','EXECUTE'),
  'authenticated clients cannot attach a client-generated PDF');
select ok(pg_get_functiondef('public.submit_reservation_v3(uuid,uuid,text,integer,timestamptz[],timestamptz[],uuid[],uuid[],text,jsonb,text[],uuid,text,text,text[],integer,jsonb)'::regprocedure)
  like '%payment_amount_centavos=0%','internal submission normalizes the payment snapshot to zero');
select ok(pg_get_functiondef('public.get_reservation_permit_readiness(uuid)'::regprocedure)
  like '%full_payment_required%','readiness explicitly blocks incomplete external payment');

select * from finish();
rollback;
