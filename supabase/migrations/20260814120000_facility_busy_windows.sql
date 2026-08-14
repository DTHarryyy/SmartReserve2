-- Anonymised availability lookup for the student booking assistant.
--
-- RLS on reservation_requests / reservation_occurrences (public.can_access_reservation)
-- hides other people's rows, so a plain select can never answer "is this room free?".
-- This function exposes the minimum needed to answer that: a facility id and two
-- timestamps. No requester, no purpose, no headcount, no request or occurrence id --
-- exactly what a printed door schedule shows.
--
-- Only booking_state = 'booked' rows are returned. Pending requests (which reveal
-- intent and are the more sensitive class) are never exposed, and this matches the
-- reservation_occurrences_no_overlap exclusion constraint, so the answer is truthful
-- about what would actually be rejected on insert.
create or replace function public.facility_busy_windows(
  p_facility_ids uuid[],
  p_from timestamptz,
  p_to timestamptz
) returns table (
  facility_id uuid,
  starts_at timestamptz,
  ends_at timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
  select o.facility_id, o.starts_at, o.ends_at
  from public.reservation_occurrences o
  join public.facilities f on f.id = o.facility_id
  where p_to > p_from
    and p_to <= p_from + interval '120 days'
    and array_length(p_facility_ids, 1) between 1 and 40
    and o.facility_id = any(p_facility_ids)
    and o.booking_state = 'booked'
    and f.archived_at is null
    and f.public_listing
    and tstzrange(o.starts_at, o.ends_at, '[)') && tstzrange(p_from, p_to, '[)')
  order by o.facility_id, o.starts_at;
$$;

revoke all on function public.facility_busy_windows(uuid[], timestamptz, timestamptz)
  from public, anon;
grant execute on function public.facility_busy_windows(uuid[], timestamptz, timestamptz)
  to authenticated;

notify pgrst, 'reload schema';
