create or replace function public.approve_and_bump_reservation(
  p_request_id uuid,
  p_reason text,
  p_expected_version integer,
  p_idempotency_key uuid
) returns jsonb
language plpgsql security definer set search_path=public as $$
declare
  request_row public.reservation_requests%rowtype;
  actor public.profiles%rowtype;
  affected_ids uuid[];
  conflict_occurrence_ids uuid[];
  journal_id uuid;
  event_id uuid;
begin
  if not public.reservation_is_admin() then raise exception using errcode='42501',message='Administrator access required'; end if;
  if coalesce(trim(p_reason),'')='' then raise exception using errcode='22023',message='A reason is required'; end if;
  if exists(select 1 from public.reservation_action_journal where actor_id=auth.uid() and idempotency_key=p_idempotency_key) then
    return jsonb_build_object('duplicate',true);
  end if;
  select * into actor from public.profiles where id=auth.uid();
  select * into request_row from public.reservation_requests where id=p_request_id for update;
  if request_row.id is null then raise exception using errcode='P0002',message='Reservation not found'; end if;
  if request_row.status<>'pending' or request_row.held_for_verification then raise exception using errcode='22023',message='Only released pending requests can be approved'; end if;
  if request_row.version<>p_expected_version then raise exception using errcode='40001',message='This reservation changed. Refresh and try again'; end if;
  if request_row.headcount>request_row.facility_capacity then raise exception using errcode='22023',message='Headcount exceeds facility capacity'; end if;
  select coalesce(array_agg(distinct other.id),'{}'),coalesce(array_agg(distinct other.request_id),'{}')
  into conflict_occurrence_ids,affected_ids
  from public.reservation_occurrences wanted
  join public.reservation_occurrences other on other.facility_id=wanted.facility_id
    and other.booking_state='booked' and other.blocked_window&&wanted.blocked_window
    and other.request_id<>wanted.request_id
  where wanted.request_id=p_request_id;
  if cardinality(conflict_occurrence_ids)=0 then raise exception using errcode='22023',message='There is no confirmed booking to bump'; end if;
  if exists(select 1 from public.reservation_occurrences where id=any(conflict_occurrence_ids) and starts_at<=now()) then
    raise exception using errcode='22023',message='Bookings that have started cannot be bumped';
  end if;
  affected_ids:=array_append(affected_ids,p_request_id);
  perform 1 from public.reservation_requests where id=any(affected_ids) for update;
  insert into public.reservation_action_journal(actor_id,idempotency_key,action,request_ids,before_requests,before_occurrences)
  select auth.uid(),p_idempotency_key,'approve_bump',affected_ids,
    (select jsonb_agg(to_jsonb(r)) from public.reservation_requests r where r.id=any(affected_ids)),
    (select jsonb_agg(to_jsonb(o)) from public.reservation_occurrences o where o.request_id=any(affected_ids))
  returning id into journal_id;
  update public.reservation_occurrences set booking_state='bumped',exception_reason=trim(p_reason)
  where id=any(conflict_occurrence_ids);
  update public.reservation_requests set status='changes_requested',decision_reason=trim(p_reason)
  where id=any(affected_ids) and id<>p_request_id;
  update public.reservation_occurrences set booking_state='booked',exception_reason=null
  where request_id=p_request_id and booking_state in ('requested','changes_requested');
  update public.reservation_requests set status='approved',decision_reason=null,decided_by=auth.uid(),
    decided_by_name=actor.full_name,decided_at=now(),
    payment_status=case when payment_status='quoted' then 'authorized' else payment_status end
  where id=p_request_id;
  update public.reservation_action_journal set after_versions=(
    select jsonb_object_agg(id::text,version) from public.reservation_requests where id=any(affected_ids)
  ) where id=journal_id;
  event_id:=public.reservation_event(p_request_id,'approved and bumped a conflicting booking',trim(p_reason),
    jsonb_build_object('bumped_occurrence_ids',conflict_occurrence_ids));
  perform public.notify_reservation_user(p_request_id,event_id,'reservation_approved','Reservation approved',trim(p_reason));
  return jsonb_build_object('action_id',journal_id,'undo_until',now()+interval '8 seconds');
exception when exclusion_violation then
  raise exception using errcode='23P01',message='The schedule changed while this decision was being saved';
end;
$$;

grant execute on function public.approve_and_bump_reservation(uuid,text,integer,uuid) to authenticated;
