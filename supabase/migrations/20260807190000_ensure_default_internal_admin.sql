do $$
declare
  admin_email constant text := 'admin@csu.edu.ph';
  admin_id uuid;
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

  select id into admin_id
  from auth.users
  where lower(email) = admin_email
  limit 1;

  if admin_id is null then
    admin_id := '20000000-0000-0000-0000-000000000001';

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
      admin_id,
      'authenticated',
      'authenticated',
      admin_email,
      password_hash,
      now(),
      jsonb_build_object('provider', 'email', 'providers', array['email']),
      jsonb_build_object('full_name', 'CSU Administrator'),
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
          jsonb_build_object('full_name', 'CSU Administrator'),
        updated_at = now()
    where id = admin_id;
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
    admin_id,
    admin_id::text,
    admin_id,
    jsonb_build_object(
      'sub', admin_id::text,
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
    admin_id,
    admin_email,
    'CSU Administrator',
    'none',
    'internal_admin',
    'active',
    'verified',
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
end;
$$;
