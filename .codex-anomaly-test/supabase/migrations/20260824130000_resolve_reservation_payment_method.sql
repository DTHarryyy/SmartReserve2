-- Fixes GCash proof submission being permanently blocked:
--   1. No facility has ever had a GCash destination configured
--      (facility_payment_methods is empty), so every paid reservation's
--      payment_method_id is null.
--   2. submit_payment() hard-fails on a null payment_method_id instead of
--      resolving one, unlike apply_reservation_payment_gate() which already
--      knows how to pick the facility's active GCash method.
--
-- This migration seeds a placeholder GCash destination for facilities that
-- already have paid reservations, backfills payment_method_id on those
-- legacy rows, and makes submit_payment() self-healing so future facilities
-- that gain a method after approval aren't stuck either.

-- (c) Seed a placeholder GCash destination for facilities that already have
-- paid reservations but no payment method on file. Administrators should
-- replace this with the real account via Facility configuration.
insert into public.facility_payment_methods (facility_id, account_name, account_number, instructions)
select distinct f.id, 'CSU Aparri — ' || f.name, '09000000000',
       'PLACEHOLDER — replace via Facility configuration → GCash destination.'
from public.facilities f
join public.reservation_requests r on r.facility_id = f.id and r.total_amount_centavos > 0
where not exists (
  select 1 from public.facility_payment_methods m where m.facility_id = f.id and m.enabled
);

-- (b) Backfill legacy reservations that were never routed through
-- apply_reservation_payment_gate() and so never got a payment_method_id.
update public.reservation_requests r
set payment_method_id = m.id
from public.facility_payment_methods m
where r.payment_method_id is null
  and r.total_amount_centavos > 0
  and r.reservation_status in ('awaiting_payment','confirmed')
  and m.facility_id = r.facility_id and m.enabled and m.method_type = 'gcash';

-- (a) Make submit_payment() resolve a missing payment_method_id instead of
-- rejecting outright, mirroring apply_reservation_payment_gate()'s lookup.
create or replace function public.submit_payment(
  p_transaction_id uuid,p_request_id uuid,p_purpose text,p_amount_centavos integer,
  p_reference_number text,p_proof_path text,p_idempotency_key uuid
) returns public.payment_transactions
language plpgsql
security definer
set search_path=public,storage
as $$
declare
  request_row public.reservation_requests%rowtype;
  result public.payment_transactions%rowtype;
  committed_value integer;
  event_id uuid;
  method_id uuid;
begin
  select * into request_row from public.reservation_requests where id=p_request_id for update;
  if request_row.id is null or request_row.requester_id<>auth.uid() then
    raise exception using errcode='42501',message='Reservation access denied';
  end if;
  if request_row.reservation_status not in ('awaiting_payment','confirmed') then
    raise exception using errcode='22023',message='This reservation is not accepting payments';
  end if;
  if p_purpose not in ('down_payment','balance') or p_amount_centavos<=0 then
    raise exception using errcode='22023',message='Provide a valid payment amount and purpose';
  end if;
  if request_row.payment_method_id is null then
    select id into method_id from public.facility_payment_methods
    where facility_id=request_row.facility_id and enabled and method_type='gcash'
    order by updated_at desc limit 1;
    if method_id is null then
      raise exception using errcode='22023',
        message='This facility has not published a GCash account yet. Ask the administrator to configure one.';
    end if;
    update public.reservation_requests set payment_method_id=method_id where id=p_request_id;
    request_row.payment_method_id:=method_id;
  end if;
  if length(trim(p_reference_number))<6 then
    raise exception using errcode='22023',message='Provide the GCash reference number';
  end if;
  if p_proof_path not like auth.uid()::text||'/'||p_request_id::text||'/%' then
    raise exception using errcode='42501',message='Invalid payment proof path';
  end if;
  select coalesce(sum(amount_centavos),0) into committed_value
  from public.payment_transactions
  where request_id=p_request_id and status in ('submitted','verified');
  if p_amount_centavos>request_row.total_amount_centavos-committed_value then
    raise exception using errcode='22023',message='Payment is greater than the outstanding balance';
  end if;
  insert into public.payment_transactions(
    id,request_id,payer_id,payment_method_id,purpose,amount_centavos,
    reference_number,proof_path,idempotency_key
  ) values (
    p_transaction_id,p_request_id,auth.uid(),request_row.payment_method_id,
    p_purpose,p_amount_centavos,trim(p_reference_number),p_proof_path,p_idempotency_key
  ) returning * into result;
  event_id:=public.reservation_event(p_request_id,'submitted payment proof',null,
    jsonb_build_object('payment_id',result.id,'purpose',result.purpose,
      'amount_centavos',result.amount_centavos),null,true);
  insert into public.app_notifications(recipient_id,request_id,event_id,kind,title,body)
  select a.admin_id,p_request_id,event_id,'payment_submitted','Payment needs review',
    request_row.requester_name||' submitted GCash payment proof.'
  from public.facility_admin_assignments a
  join public.profiles p on p.id=a.admin_id and p.account_status='active'
  where a.facility_id=request_row.facility_id
    and p.role=case request_row.admin_lane when 'internal' then 'internal_admin' else 'external_admin' end;
  return result;
exception when unique_violation then
  raise exception using errcode='23505',message='That payment reference or submission was already used';
end;
$$;

revoke all on function public.submit_payment(uuid,uuid,text,integer,text,text,uuid) from public,anon;
grant execute on function public.submit_payment(uuid,uuid,text,integer,text,text,uuid) to authenticated;
