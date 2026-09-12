begin;
create extension if not exists pgtap with schema extensions;
set search_path=public,extensions;
select plan(12);

select has_table('public','permit_official_signature_revisions');
select has_column('public','reservation_signature_requests','reservation_version');
select has_column('public','reservation_signature_requests','printable_content_hash');
select has_column('public','reservation_user_signatures','reservation_version');
select has_column('public','reservation_user_signatures','printable_content_hash');
select has_function('public','record_official_permit_signature',array['text','text','text','text','integer','text','uuid']);
select has_function('public','permit_printable_hash',array['uuid']);
select is((select count(*) from information_schema.role_table_grants where table_schema='public'
  and table_name='permit_official_signature_revisions' and grantee='authenticated'),0::bigint,
  'authenticated users have no direct official-signature table grant');
select is((select count(*) from pg_policies where schemaname='storage' and tablename='objects'
  and policyname ilike '%official%signature%'),0::bigint,
  'official-signature objects have no authenticated storage policy');
select like(pg_get_functiondef('public.record_official_permit_signature(text,text,text,text,integer,text,uuid)'::regprocedure),
  '%internal_approver%','official signature recorder recognizes the internal slot');
select like(pg_get_functiondef('public.record_official_permit_signature(text,text,text,text,integer,text,uuid)'::regprocedure),
  '%external_recommender%','official signature recorder recognizes the recommender slot');
select like(pg_get_functiondef('public.record_official_permit_signature(text,text,text,text,integer,text,uuid)'::regprocedure),
  '%external_authorized_official%','official signature recorder recognizes the authorized-official slot');

select * from finish();
rollback;
