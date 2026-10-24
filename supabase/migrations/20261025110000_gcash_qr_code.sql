-- GCash QR code: Internal and External Admins can upload a QR image for a
-- facility's GCash destination. Renters see it in the payment dialog next to
-- the account name and number and can scan it from their GCash app.
--
-- The image lives in the public payment-qr bucket under
-- <facility_id>/<file>; facility_payment_methods.qr_path points at it.

alter table public.facility_payment_methods
  add column if not exists qr_path text
    check (qr_path is null or (length(qr_path) between 3 and 300 and qr_path !~ '\.\.'));

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('payment-qr', 'payment-qr', true, 5242880, array['image/jpeg', 'image/png'])
on conflict (id) do update
set public = true,
    file_size_limit = 5242880,
    allowed_mime_types = array['image/jpeg', 'image/png'];

-- The first path segment must be a facility the caller can manage.
create or replace function public.can_manage_payment_qr_object(p_name text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select case
    when split_part(coalesce(p_name, ''), '/', 1)
      ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    then public.can_manage_facility(split_part(p_name, '/', 1)::uuid)
    else false
  end;
$$;

revoke all on function public.can_manage_payment_qr_object(text) from public, anon;
grant execute on function public.can_manage_payment_qr_object(text) to authenticated;

drop policy if exists payment_qr_public_read on storage.objects;
create policy payment_qr_public_read on storage.objects
for select to public
using (bucket_id = 'payment-qr');

drop policy if exists payment_qr_insert_admin on storage.objects;
create policy payment_qr_insert_admin on storage.objects
for insert to authenticated
with check (bucket_id = 'payment-qr' and public.can_manage_payment_qr_object(name));

drop policy if exists payment_qr_update_admin on storage.objects;
create policy payment_qr_update_admin on storage.objects
for update to authenticated
using (bucket_id = 'payment-qr' and public.can_manage_payment_qr_object(name))
with check (bucket_id = 'payment-qr' and public.can_manage_payment_qr_object(name));

drop policy if exists payment_qr_delete_admin on storage.objects;
create policy payment_qr_delete_admin on storage.objects
for delete to authenticated
using (bucket_id = 'payment-qr' and public.can_manage_payment_qr_object(name));

-- v3 plus the QR. p_qr_path is the QR the GCash destination should show
-- after saving (null removes it). v3 may replace the GCash row when its
-- details change, so the QR is applied to whichever row is active after it.
create or replace function public.save_facility_configuration_v4(
  p_facility_id uuid, p_rates jsonb, p_amenities jsonb, p_account_name text, p_account_number text,
  p_instructions text default '', p_deposit_window_minutes integer default 1440,
  p_balance_due_lead_minutes integer default 1440, p_correction_window_minutes integer default 1440,
  p_down_payment_percent integer default 50, p_internal_permit_row_code text default null,
  p_external_permit_row_code text default null, p_qr_path text default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  result jsonb;
  qr text := nullif(trim(coalesce(p_qr_path, '')), '');
begin
  if qr is not null and (
    split_part(qr, '/', 1) <> p_facility_id::text
    or qr ~ '\.\.'
    or length(qr) > 300
  ) then
    raise exception using errcode = '22023',
      message = 'The GCash QR must be uploaded for this facility';
  end if;

  result := public.save_facility_configuration_v3(
    p_facility_id, p_rates, p_amenities, p_account_name, p_account_number,
    p_instructions, p_deposit_window_minutes, p_balance_due_lead_minutes,
    p_correction_window_minutes, p_down_payment_percent,
    p_internal_permit_row_code, p_external_permit_row_code
  );

  if qr is not null and not exists (
    select 1 from public.facility_payment_methods
    where facility_id = p_facility_id and method_type = 'gcash' and enabled
  ) then
    raise exception using errcode = '22023',
      message = 'Add the GCash account name and number before uploading a QR';
  end if;

  update public.facility_payment_methods
  set qr_path = qr, updated_at = now(), updated_by = auth.uid()
  where facility_id = p_facility_id
    and method_type = 'gcash'
    and enabled
    and qr_path is distinct from qr;

  return result || jsonb_build_object('qr_path', qr);
end $$;

revoke all on function public.save_facility_configuration_v4(uuid,jsonb,jsonb,text,text,text,integer,integer,integer,integer,text,text,text)
  from public, anon;
grant execute on function public.save_facility_configuration_v4(uuid,jsonb,jsonb,text,text,text,integer,integer,integer,integer,text,text,text)
  to authenticated;

notify pgrst, 'reload schema';
