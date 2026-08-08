create or replace function public.mark_my_notification_read(p_notification_id uuid)
returns void language sql security definer set search_path=public as $$
  update public.app_notifications set read_at=coalesce(read_at,now())
  where id=p_notification_id and recipient_id=auth.uid();
$$;

revoke update on public.app_notifications from authenticated;
drop policy if exists app_notifications_update on public.app_notifications;
grant execute on function public.mark_my_notification_read(uuid) to authenticated;

create or replace function public.resubmit_reservation(
  p_request_id uuid,
  p_purpose text,
  p_headcount integer,
  p_occurrence_id uuid,
  p_starts_at timestamptz,
  p_ends_at timestamptz,
  p_expected_version integer,
  p_idempotency_key uuid
) returns jsonb
language plpgsql security definer set search_path=public as $$
declare
  request_row public.reservation_requests%rowtype;
  occurrence_row public.reservation_occurrences%rowtype;
  facility public.facilities%rowtype;
  journal_id uuid;
  event_id uuid;
begin
  if exists(select 1 from public.reservation_action_journal where actor_id=auth.uid() and idempotency_key=p_idempotency_key) then
    return jsonb_build_object('duplicate',true);
  end if;
  select * into request_row from public.reservation_requests where id=p_request_id for update;
  if request_row.id is null or request_row.requester_id<>auth.uid() then raise exception using errcode='42501',message='Forbidden'; end if;
  if request_row.status<>'changes_requested' then raise exception using errcode='22023',message='This reservation is not awaiting changes'; end if;
  if request_row.version<>p_expected_version then raise exception using errcode='40001',message='This reservation changed. Refresh and try again'; end if;
  select * into occurrence_row from public.reservation_occurrences where id=p_occurrence_id and request_id=p_request_id for update;
  if occurrence_row.id is null or occurrence_row.booking_state not in ('changes_requested','bumped') then
    raise exception using errcode='22023',message='Choose an occurrence that needs a new time';
  end if;
  select * into facility from public.facilities where id=request_row.facility_id;
  if p_starts_at>=p_ends_at or p_starts_at<now() then raise exception using errcode='22023',message='Choose a valid future time'; end if;
  if extract(epoch from (p_ends_at-p_starts_at))/60>facility.max_duration_minutes then
    raise exception using errcode='22023',message='Reservation exceeds the facility maximum duration';
  end if;
  insert into public.reservation_action_journal(actor_id,idempotency_key,action,request_ids,before_requests,before_occurrences)
  select auth.uid(),p_idempotency_key,'resubmit',array[p_request_id],
    jsonb_build_array(to_jsonb(request_row)),jsonb_build_array(to_jsonb(occurrence_row))
  returning id into journal_id;
  update public.reservation_occurrences set starts_at=p_starts_at,ends_at=p_ends_at,
    proposed_starts_at=null,proposed_ends_at=null,booking_state='requested',exception_reason=null
  where id=p_occurrence_id;
  update public.reservation_requests set status='pending',decision_reason=null,decided_by=null,
    decided_by_name=null,decided_at=null,purpose=trim(p_purpose),headcount=p_headcount
  where id=p_request_id;
  update public.reservation_action_journal
  set after_versions=jsonb_build_object(p_request_id::text,(select version from public.reservation_requests where id=p_request_id))
  where id=journal_id;
  event_id:=public.reservation_event(p_request_id,'resubmitted reservation changes',null,
    jsonb_build_object('occurrence_id',p_occurrence_id,'starts_at',p_starts_at,'ends_at',p_ends_at),p_occurrence_id);
  insert into public.app_notifications(recipient_id,request_id,event_id,kind,title,body)
  select p.id,p_request_id,event_id,'reservation_resubmitted','Reservation resubmitted',
    request_row.requester_name||' proposed a new time for '||request_row.facility_name
  from public.profiles p where p.role in ('internal_admin','external_admin') and p.account_status='active';
  return jsonb_build_object('action_id',journal_id,'undo_until',now()+interval '8 seconds');
exception when exclusion_violation then
  raise exception using errcode='23P01',message='The proposed time is no longer available';
end;
$$;

grant execute on function public.resubmit_reservation(uuid,text,integer,uuid,timestamptz,timestamptz,integer,uuid) to authenticated;

create or replace function public.notify_bumped_occurrence()
returns trigger language plpgsql security definer set search_path=public as $$
declare event_id uuid;
begin
  if new.booking_state='bumped' and old.booking_state is distinct from 'bumped' then
    event_id:=public.reservation_event(new.request_id,'booking was bumped',new.exception_reason,
      jsonb_build_object('occurrence_id',new.id),new.id);
    perform public.notify_reservation_user(new.request_id,event_id,'reservation_bumped',
      'Your booking needs a new time',coalesce(new.exception_reason,'An administrator bumped this booking.'));
  end if;
  return new;
end;
$$;

drop trigger if exists reservation_occurrences_notify_bump on public.reservation_occurrences;
create trigger reservation_occurrences_notify_bump after update of booking_state on public.reservation_occurrences
for each row execute procedure public.notify_bumped_occurrence();
