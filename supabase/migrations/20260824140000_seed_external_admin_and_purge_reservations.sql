-- Clears every reservation and its trail, then seeds a reproducible external
-- administrator account assigned to every facility.
--
-- The purge runs first so the seeded admin starts on an empty queue. On a fresh
-- database the deletes are no-ops.

-- Part 1: purge reservations.
--
-- Deletes are ordered explicitly rather than leaning on cascades: the
-- payment_transactions -> reservation_requests foreign key is RESTRICT, and
-- reservation_events.occurrence_id is NO ACTION, so events must go before the
-- occurrences they point at.
delete from public.payment_transactions;

delete from public.reservation_terms_acceptances;
delete from public.reservation_payment_reminders;
delete from public.reservation_permits;
delete from public.reservation_feedback;
delete from public.reservation_price_lines;
delete from public.reservation_amenities;
delete from public.reservation_attachments;
delete from public.app_notifications;

delete from public.reservation_events;
delete from public.reservation_occurrences;
delete from public.reservation_requests;

-- request_ids is a uuid[] with no foreign key, so the journal outlives the
-- cascade and has to be cleared by hand.
delete from public.reservation_action_journal;

delete from public.loyalty_transactions where source_type = 'reservation';

-- audit_entries also has no foreign key; facility and account history stays.
delete from public.audit_entries where entity_type = 'reservation';

-- Storage rows for reservation artefacts. This orphans the underlying objects
-- in the storage backend, which is acceptable for a development reset.
-- storage.objects blocks direct deletes (storage.protect_delete trigger)
-- unless this session-local escape hatch is set.
set local storage.allow_delete_query = 'true';
delete from storage.objects
where bucket_id in (
  'reservation-attachments',
  'payment-proofs',
  'reservation-permits'
);

-- Part 2: seed the external administrator, and assign it every facility.
do $$
declare
  admin_email constant text := 'external-admin@csu.edu.ph';
  seed_admin_id uuid;
  password_hash text;
  crypto_schema name;
begin
  select ns.nspname into crypto_schema
  from pg_extension ext
  join pg_namespace ns on ns.oid = ext.extnamespace
  where ext.extname = 'pgcrypto';

  if crypto_schema is null then
    raise exception 'The pgcrypto extension is required to seed the admin account.';
  end if;

  execute format(
    'select %I.crypt($1, %I.gen_salt(''bf'', 12))',
    crypto_schema,
    crypto_schema
  )
  into password_hash
  using convert_from(decode('YWRtaW4xMjM=', 'base64'), 'UTF8');

  select id into seed_admin_id
  from auth.users
  where lower(email) = admin_email
  limit 1;

  if seed_admin_id is null then
    seed_admin_id := '40000000-0000-0000-0000-000000000001';

    insert into auth.users (
      instance_id,
      id,
      aud,
      role,
      email,
      encrypted_password,
      email_confirmed_at,
      raw_app_meta_data,
      raw_user_meta_data,
      created_at,
      updated_at,
      confirmation_token,
      email_change,
      email_change_token_new,
      recovery_token
    )
    values (
      '00000000-0000-0000-0000-000000000000',
      seed_admin_id,
      'authenticated',
      'authenticated',
      admin_email,
      password_hash,
      now(),
      jsonb_build_object('provider', 'email', 'providers', array['email']),
      jsonb_build_object('full_name', 'CSU External Administrator'),
      now(),
      now(),
      '',
      '',
      '',
      ''
    );
  else
    update auth.users
    set encrypted_password = password_hash,
        email_confirmed_at = coalesce(email_confirmed_at, now()),
        raw_app_meta_data = coalesce(raw_app_meta_data, '{}'::jsonb) ||
          jsonb_build_object('provider', 'email', 'providers', array['email']),
        raw_user_meta_data = coalesce(raw_user_meta_data, '{}'::jsonb) ||
          jsonb_build_object('full_name', 'CSU External Administrator'),
        updated_at = now()
    where id = seed_admin_id;
  end if;

  insert into auth.identities (
    id,
    provider_id,
    user_id,
    identity_data,
    provider,
    last_sign_in_at,
    created_at,
    updated_at
  )
  values (
    seed_admin_id,
    seed_admin_id::text,
    seed_admin_id,
    jsonb_build_object(
      'sub', seed_admin_id::text,
      'email', admin_email,
      'email_verified', true,
      'phone_verified', false
    ),
    'email',
    now(),
    now(),
    now()
  )
  on conflict (provider_id, provider) do update
  set identity_data = excluded.identity_data,
      updated_at = now();

  -- handle_new_user() already inserted a role='user' row from the auth.users
  -- trigger; the upsert corrects it.
  insert into public.profiles (
    id,
    email,
    full_name,
    campus_claim,
    role,
    account_status,
    verification_status,
    onboarding_complete
  )
  values (
    seed_admin_id,
    admin_email,
    'CSU External Administrator',
    'none',
    'external_admin',
    'active',
    'none',
    true
  )
  on conflict (id) do update
  set email = excluded.email,
      full_name = excluded.full_name,
      campus_claim = excluded.campus_claim,
      role = excluded.role,
      account_status = excluded.account_status,
      verification_status = excluded.verification_status,
      onboarding_complete = excluded.onboarding_complete,
      updated_at = now();

  -- Without assignments can_manage_facility() is false everywhere and the
  -- external lane console has nothing to show.
  insert into public.facility_admin_assignments (
    facility_id,
    admin_id,
    assignment_role,
    assigned_by
  )
  select f.id, seed_admin_id, 'manager', seed_admin_id
  from public.facilities f
  on conflict (facility_id, admin_id) do nothing;
end;
$$;
