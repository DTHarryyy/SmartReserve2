-- Facility names use citext; the shared calendar returns a text label.
create or replace function public.public_reservation_calendar(
  p_facility_ids uuid[],
  p_from timestamptz,
  p_to timestamptz
) returns table (
  facility_id uuid,
  occurrence_id uuid,
  starts_at timestamptz,
  ends_at timestamptz,
  facility_name text
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'Authenticated user access required';
  end if;

  if not exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and p.role in ('user', 'internal_admin', 'external_admin')
      and p.account_status = 'active'
  ) then
    raise exception using errcode = '42501', message = 'Active user access required';
  end if;

  if p_from is null or p_to is null or p_to <= p_from
      or p_to > p_from + interval '120 days'
      or p_facility_ids is null
      or cardinality(p_facility_ids) > 40 then
    raise exception using errcode = '22023', message = 'Invalid calendar range or facility batch';
  end if;

  return query
  select o.facility_id, o.id, o.starts_at, o.ends_at, f.name::text
  from public.reservation_occurrences o
  join public.facilities f on f.id = o.facility_id
  where (cardinality(p_facility_ids) = 0 or o.facility_id = any(p_facility_ids))
    and o.booking_state in ('requested', 'held', 'booked', 'changes_requested', 'bumped')
    and tstzrange(o.starts_at, o.ends_at, '[)')
      && tstzrange(p_from, p_to, '[)')
  order by o.facility_id, o.starts_at, o.id;
end;
$$;

revoke all on function public.public_reservation_calendar(uuid[], timestamptz, timestamptz)
  from public, anon;
grant execute on function public.public_reservation_calendar(uuid[], timestamptz, timestamptz)
  to authenticated;

notify pgrst, 'reload schema';

