-- Fix "there is no unique or exclusion constraint matching the ON CONFLICT
-- specification" on completing a reservation (and on submitting feedback).
--
-- loyalty_transactions_source_idx (20260823090000) is a PARTIAL unique index:
--   on public.loyalty_transactions(transaction_type, source_type, source_id)
--   where source_id is not null
--
-- Postgres will only use a partial unique index as an ON CONFLICT arbiter
-- when the conflict clause's predicate matches the index predicate exactly.
-- award_reservation_completion_points() and submit_reservation_feedback()
-- both omitted "where source_id is not null" from their
-- `on conflict (transaction_type, source_type, source_id) do nothing`
-- clauses, so Postgres couldn't find a matching arbiter and every completion
-- (and every feedback submission) failed at the insert.

create or replace function public.award_reservation_completion_points()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  awarded_id uuid;
  award_points integer;
begin
  if new.reservation_status = 'completed'
     and old.reservation_status is distinct from 'completed'
     and new.requester_id is not null
     and exists (
       select 1 from public.reservation_occurrences
       where request_id = new.id and lifecycle_stage = 'completed'
     )
  then
    award_points := public.loyalty_points_for('reservation_completed');
    insert into public.loyalty_transactions(
      user_id, points, transaction_type, source_type, source_id, description
    ) values (
      new.requester_id, award_points, 'reservation_completed',
      'reservation', new.id, 'Completed reservation - ' || new.facility_name
    )
    on conflict (transaction_type, source_type, source_id) where source_id is not null do nothing
    returning id into awarded_id;

    if awarded_id is not null then
      insert into public.app_notifications(recipient_id, request_id, kind, title, body)
      values (
        new.requester_id, new.id, 'loyalty_earned',
        '+' || award_points || ' points',
        'Thanks for using ' || new.facility_name || '.'
      );
    end if;
  end if;
  return null;
end;
$$;

create or replace function public.submit_reservation_feedback(
  p_reservation_id uuid,
  p_rating integer,
  p_comment text default '',
  p_cleanliness integer default null,
  p_condition integer default null,
  p_equipment integer default null
) returns public.reservation_feedback
language plpgsql
security definer
set search_path = public
as $$
declare
  request_row public.reservation_requests%rowtype;
  result public.reservation_feedback%rowtype;
  awarded_id uuid;
  award_points integer;
  clean_comment text;
begin
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'Sign in required';
  end if;
  if p_rating is null or p_rating not between 1 and 5 then
    raise exception using errcode = '22023', message = 'Choose a rating from 1 to 5';
  end if;
  if p_cleanliness is not null and p_cleanliness not between 1 and 5 then
    raise exception using errcode = '22023', message = 'Cleanliness rating must be between 1 and 5';
  end if;
  if p_condition is not null and p_condition not between 1 and 5 then
    raise exception using errcode = '22023', message = 'Condition rating must be between 1 and 5';
  end if;
  if p_equipment is not null and p_equipment not between 1 and 5 then
    raise exception using errcode = '22023', message = 'Equipment rating must be between 1 and 5';
  end if;
  clean_comment := trim(coalesce(p_comment, ''));
  if length(clean_comment) > 500 then
    raise exception using errcode = '22023', message = 'Keep your comment under 500 characters';
  end if;

  select * into request_row from public.reservation_requests
  where id = p_reservation_id for update;

  if request_row.id is null then
    raise exception using errcode = 'P0002', message = 'Reservation not found';
  end if;
  if request_row.requester_id <> auth.uid() then
    raise exception using errcode = '42501', message = 'Feedback is limited to the person who booked';
  end if;
  if request_row.reservation_status <> 'completed'
     or not exists (
       select 1 from public.reservation_occurrences
       where request_id = p_reservation_id and lifecycle_stage = 'completed'
     ) then
    raise exception using errcode = '22023', message = 'Feedback opens once the reservation is completed';
  end if;

  begin
    insert into public.reservation_feedback(
      reservation_id, facility_id, user_id, rating,
      cleanliness_rating, condition_rating, equipment_rating, comment
    ) values (
      p_reservation_id, request_row.facility_id, auth.uid(), p_rating,
      p_cleanliness, p_condition, p_equipment, clean_comment
    )
    returning * into result;
  exception when unique_violation then
    raise exception using errcode = '23505', message = 'You already left feedback for this reservation';
  end;

  award_points := public.loyalty_points_for('feedback_submitted');
  insert into public.loyalty_transactions(
    user_id, points, transaction_type, source_type, source_id, description
  ) values (
    auth.uid(), award_points, 'feedback_submitted', 'feedback',
    result.id, 'Feedback for ' || request_row.facility_name
  )
  on conflict (transaction_type, source_type, source_id) where source_id is not null do nothing
  returning id into awarded_id;

  if awarded_id is not null then
    insert into public.app_notifications(recipient_id, request_id, kind, title, body)
    values (
      auth.uid(), p_reservation_id, 'loyalty_earned',
      '+' || award_points || ' points',
      'Thanks for rating ' || request_row.facility_name || '.'
    );
  end if;

  if p_rating <= 2 then
    insert into public.app_notifications(recipient_id, request_id, kind, title, body)
    select a.id, p_reservation_id, 'feedback_low_rating',
           p_rating || ' star rating for ' || request_row.facility_name,
           coalesce(nullif(clean_comment, ''), 'No comment left.')
    from public.profiles a
    where a.account_status = 'active'
      and (
        a.role = 'internal_admin'
        or (a.role = 'external_admin' and public.can_manage_facility(request_row.facility_id, a.id))
      )
    on conflict (recipient_id, request_id, kind) where kind = 'feedback_low_rating' do nothing;
  end if;

  perform public.reservation_event(
    p_reservation_id, 'left feedback', null,
    jsonb_build_object('rating', p_rating), null, false
  );

  return result;
end;
$$;
