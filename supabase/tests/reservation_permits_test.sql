begin;
create extension if not exists pgtap with schema extensions;
set search_path=public,extensions;
select plan(19);

select has_table('public','reservation_permit_items','frozen permit items exist');
select has_column('public','reservation_requests','external_company_organization');
select has_column('public','reservation_requests','external_complete_address');
select has_column('public','reservation_requests','external_contact_numbers');
select has_column('public','reservation_requests','external_admission_fee_centavos');
select has_column('public','reservation_permits','template_kind');
select has_column('public','reservation_permits','template_sha256');
select has_column('public','reservation_permits','generation_status');
select has_column('public','reservation_permits','internal_approver_signature_id');
select has_column('public','reservation_permits','external_recommender_signature_id');
select has_column('public','reservation_permits','external_authorized_signature_id');
select has_function('public','get_reservation_permit_readiness',array['uuid']);
select has_function('public','issue_reservation_permit',array['uuid']);
select has_function('public','prepare_reservation_permit',array['uuid','uuid']);
select has_function('public','record_generated_permit',array['uuid','text','text','integer']);
select has_function('public','update_external_permit_details',array['uuid','text','text','text[]','integer']);
select is((select count(*) from pg_policies where schemaname='storage' and tablename='objects'
  and policyname='reservation_permits_storage_insert'),0::bigint,
  'authenticated clients have no final-PDF upload policy');
select like(pg_get_functiondef('public.submit_reservation_v3(uuid,uuid,text,integer,timestamptz[],timestamptz[],uuid[],uuid[],text,jsonb,text[],uuid,text,text,text[],integer,jsonb)'::regprocedure),
  '%payment_amount_centavos=0%','internal submission normalizes the payment snapshot to zero');
select like(pg_get_functiondef('public.get_reservation_permit_readiness(uuid)'::regprocedure),
  '%full_payment_required%','readiness explicitly blocks incomplete external payment');

select * from finish();
rollback;
