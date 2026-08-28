-- External administrators share global feedback visibility, while reservation,
-- payment, document, facility, report, and account-management operations remain
-- scoped by their existing controls.

create or replace function public.feedback_admin_list(
  p_search text default null,
  p_facility_id uuid default null,
  p_min_rating integer default null,
  p_max_rating integer default null,
  p_from timestamptz default null,
  p_to timestamptz default null,
  p_sort text default 'newest',
  p_limit integer default 50,
  p_offset integer default 0
) returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  result_value jsonb;
  sort_key text := coalesce(p_sort, 'newest');
begin
  if not (public.is_internal_admin() or public.is_external_admin()) then
    raise exception using errcode = '42501', message = 'Administrator access required';
  end if;
  if p_limit not between 1 and 200 then
    raise exception using errcode = '22023', message = 'Invalid page size';
  end if;
  if sort_key not in ('newest','oldest','highest','lowest') then
    sort_key := 'newest';
  end if;

  with filtered as (
    select f.*, r.facility_name, r.requester_name
    from public.reservation_feedback f
    join public.reservation_requests r on r.id = f.reservation_id
    where (p_facility_id is null or f.facility_id = p_facility_id)
      and (p_min_rating is null or f.rating >= p_min_rating)
      and (p_max_rating is null or f.rating <= p_max_rating)
      and (p_from is null or f.created_at >= p_from)
      and (p_to is null or f.created_at < p_to)
      and (nullif(trim(p_search), '') is null
        or concat_ws(' ', r.facility_name, r.requester_name, f.comment) ilike '%' || trim(p_search) || '%')
  ), page as (
    select * from filtered
    order by
      case when sort_key = 'newest' then created_at end desc,
      case when sort_key = 'oldest' then created_at end asc,
      case when sort_key = 'highest' then rating end desc,
      case when sort_key = 'lowest' then rating end asc,
      created_at desc
    limit p_limit offset p_offset
  )
  select jsonb_build_object(
    'rows', coalesce((select jsonb_agg(to_jsonb(page)) from page), '[]'::jsonb),
    'total', (select count(*) from filtered)
  ) into result_value;
  return result_value;
end;
$$;

revoke all on function public.feedback_admin_list(
  text, uuid, integer, integer, timestamptz, timestamptz, text, integer, integer
) from public, anon;
grant execute on function public.feedback_admin_list(
  text, uuid, integer, integer, timestamptz, timestamptz, text, integer, integer
) to authenticated;

create or replace function public.feedback_admin_summary(
  p_facility_id uuid default null,
  p_from timestamptz default null,
  p_to timestamptz default null
) returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  result_value jsonb;
begin
  if not (public.is_internal_admin() or public.is_external_admin()) then
    raise exception using errcode = '42501', message = 'Administrator access required';
  end if;

  with scoped as (
    select f.* from public.reservation_feedback f
    where (p_facility_id is null or f.facility_id = p_facility_id)
      and (p_from is null or f.created_at >= p_from)
      and (p_to is null or f.created_at < p_to)
  ),
  by_facility as (
    select s.facility_id, fac.name as facility_name,
      round(avg(s.rating)::numeric, 2) as average, count(*) as total
    from scoped s
    join public.facilities fac on fac.id = s.facility_id
    group by s.facility_id, fac.name
    having count(*) >= 3
  )
  select jsonb_build_object(
    'average', (select round(avg(rating)::numeric, 2) from scoped),
    'total', (select count(*) from scoped),
    'five_star', (select count(*) from scoped where rating = 5),
    'low_rated', (select count(*) from scoped where rating <= 2),
    'highest', coalesce((
      select jsonb_agg(to_jsonb(x) order by x.average desc)
      from (select * from by_facility order by average desc limit 5) x
    ), '[]'::jsonb),
    'lowest', coalesce((
      select jsonb_agg(to_jsonb(x) order by x.average asc)
      from (select * from by_facility order by average asc limit 5) x
    ), '[]'::jsonb)
  ) into result_value;
  return result_value;
end;
$$;

revoke all on function public.feedback_admin_summary(uuid, timestamptz, timestamptz) from public, anon;
grant execute on function public.feedback_admin_summary(uuid, timestamptz, timestamptz) to authenticated;

drop policy if exists reservation_feedback_read on public.reservation_feedback;
create policy reservation_feedback_read
on public.reservation_feedback for select to authenticated
using (
  user_id = auth.uid()
  or public.is_internal_admin()
  or public.is_external_admin()
);

notify pgrst, 'reload schema';
