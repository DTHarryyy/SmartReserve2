-- Keep every in-app notification surface consistent with the unread-only
-- inbox. Read rows remain stored for audit and push-delivery integrity.
create or replace function public.assistant_my_announcements(
  p_limit integer default 5
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  limit_value integer := least(greatest(coalesce(p_limit, 5), 1), 10);
begin
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'Sign in required';
  end if;

  return jsonb_build_object(
    'notices', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'title', n.title,
          'body', left(n.body, 200),
          'kind', n.kind,
          'unread', true,
          'created_at', n.created_at
        ) order by n.created_at desc
      )
      from (
        select *
        from public.app_notifications
        where recipient_id = auth.uid()
          and read_at is null
        order by created_at desc
        limit limit_value
      ) n
    ), '[]'::jsonb),
    'facility_advisories', coalesce((
      select jsonb_agg(distinct jsonb_build_object(
        'facility_name', f.name,
        'status', f.status
      ))
      from public.facilities f
      join public.reservation_requests r on r.facility_id = f.id
      join public.reservation_occurrences o on o.request_id = r.id
      where r.requester_id = auth.uid()
        and o.starts_at >= now()
        and o.booking_state in ('held', 'booked')
        and f.status <> 'active'
    ), '[]'::jsonb)
  );
end;
$$;

revoke execute on function public.assistant_my_announcements(integer)
  from public, anon;
grant execute on function public.assistant_my_announcements(integer)
  to authenticated;

notify pgrst, 'reload schema';
