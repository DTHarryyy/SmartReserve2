create extension if not exists pgcrypto;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text not null unique,
  full_name text not null default '',
  campus_claim text check (campus_claim in ('student', 'faculty', 'staff', 'none')),
  campus_id text,
  unit text,
  role text not null default 'guest' check (role in ('student', 'faculty', 'staff', 'guest', 'internal_admin', 'external_admin')),
  account_status text not null default 'active' check (account_status in ('active', 'invited', 'suspended')),
  verification_status text not null default 'none' check (verification_status in ('none', 'pending', 'verified', 'rejected')),
  onboarding_complete boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.verification_submissions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null unique references public.profiles(id) on delete cascade,
  claim_type text not null check (claim_type in ('student', 'faculty', 'staff')),
  campus_id text not null check (length(trim(campus_id)) > 0),
  unit text not null check (length(trim(unit)) > 0),
  document_name text not null,
  document_path text,
  document_mime_type text not null check (document_mime_type in ('image/jpeg', 'image/png', 'application/pdf')),
  status text not null default 'pending' check (status in ('pending', 'approved', 'changes_requested', 'rejected')),
  reason text,
  submitted_at timestamptz not null default now(),
  decided_at timestamptz,
  decided_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create or replace function public.set_updated_at()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, email, full_name)
  values (new.id, new.email, coalesce(new.raw_user_meta_data ->> 'full_name', ''));
  return new;
end;
$$;

create or replace function public.is_internal_admin(target_id uuid default auth.uid())
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.profiles
    where id = target_id
      and role = 'internal_admin'
      and account_status = 'active'
  );
$$;

create or replace function public.complete_guest_onboarding()
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;
  update public.profiles
  set campus_claim = 'none',
      role = 'guest',
      verification_status = 'none',
      onboarding_complete = true
  where id = auth.uid();
end;
$$;

create or replace function public.sync_profile_from_verification()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.profiles
  set campus_claim = new.claim_type,
      campus_id = new.campus_id,
      unit = new.unit,
      role = new.claim_type,
      verification_status = 'pending',
      onboarding_complete = true
  where id = new.user_id;
  return new;
end;
$$;

drop trigger if exists profiles_updated_at on public.profiles;
create trigger profiles_updated_at
before update on public.profiles
for each row execute procedure public.set_updated_at();

drop trigger if exists verification_submissions_updated_at on public.verification_submissions;
create trigger verification_submissions_updated_at
before update on public.verification_submissions
for each row execute procedure public.set_updated_at();

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
after insert on auth.users
for each row execute procedure public.handle_new_user();

drop trigger if exists verification_submission_profile_sync on public.verification_submissions;
create trigger verification_submission_profile_sync
after insert or update of claim_type, campus_id, unit, document_path on public.verification_submissions
for each row execute procedure public.sync_profile_from_verification();

alter table public.profiles enable row level security;
alter table public.verification_submissions enable row level security;

grant usage on schema public to anon, authenticated;
grant select on public.profiles to authenticated;
grant select, insert, update on public.verification_submissions to authenticated;
grant execute on function public.complete_guest_onboarding() to authenticated;
grant execute on function public.is_internal_admin(uuid) to authenticated;

drop policy if exists profiles_select_own on public.profiles;
create policy profiles_select_own on public.profiles
for select to authenticated
using (id = auth.uid());

drop policy if exists profiles_select_internal_admin on public.profiles;
create policy profiles_select_internal_admin on public.profiles
for select to authenticated
using (public.is_internal_admin());

drop policy if exists verification_select_own on public.verification_submissions;
create policy verification_select_own on public.verification_submissions
for select to authenticated
using (user_id = auth.uid());

drop policy if exists verification_select_internal_admin on public.verification_submissions;
create policy verification_select_internal_admin on public.verification_submissions
for select to authenticated
using (public.is_internal_admin());

drop policy if exists verification_insert_own on public.verification_submissions;
create policy verification_insert_own on public.verification_submissions
for insert to authenticated
with check (
  user_id = auth.uid()
  and status = 'pending'
  and reason is null
  and decided_at is null
  and decided_by is null
  and document_path = auth.uid()::text || '/current'
);

drop policy if exists verification_resubmit_own on public.verification_submissions;
create policy verification_resubmit_own on public.verification_submissions
for update to authenticated
using (user_id = auth.uid() and status in ('changes_requested', 'rejected'))
with check (
  user_id = auth.uid()
  and status = 'pending'
  and reason is null
  and decided_at is null
  and decided_by is null
  and document_path = auth.uid()::text || '/current'
);

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'verification-documents',
  'verification-documents',
  false,
  10485760,
  array['image/jpeg', 'image/png', 'application/pdf']
)
on conflict (id) do update
set public = false,
    file_size_limit = 10485760,
    allowed_mime_types = array['image/jpeg', 'image/png', 'application/pdf'];

drop policy if exists verification_documents_select_own on storage.objects;
create policy verification_documents_select_own on storage.objects
for select to authenticated
using (
  bucket_id = 'verification-documents'
  and (storage.foldername(name))[1] = auth.uid()::text
);

drop policy if exists verification_documents_select_internal_admin on storage.objects;
create policy verification_documents_select_internal_admin on storage.objects
for select to authenticated
using (
  bucket_id = 'verification-documents'
  and public.is_internal_admin()
);

drop policy if exists verification_documents_insert_own on storage.objects;
create policy verification_documents_insert_own on storage.objects
for insert to authenticated
with check (
  bucket_id = 'verification-documents'
  and (storage.foldername(name))[1] = auth.uid()::text
  and name = auth.uid()::text || '/current'
);

drop policy if exists verification_documents_update_own on storage.objects;
create policy verification_documents_update_own on storage.objects
for update to authenticated
using (
  bucket_id = 'verification-documents'
  and (storage.foldername(name))[1] = auth.uid()::text
)
with check (
  bucket_id = 'verification-documents'
  and name = auth.uid()::text || '/current'
);

drop policy if exists verification_documents_delete_own on storage.objects;
create policy verification_documents_delete_own on storage.objects
for delete to authenticated
using (
  bucket_id = 'verification-documents'
  and (storage.foldername(name))[1] = auth.uid()::text
);

do $$
begin
  if not exists (
    select 1
    from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'verification_submissions'
  ) then
    alter publication supabase_realtime add table public.verification_submissions;
  end if;
end;
$$;
