-- Let any active administrator (internal or external) see every
-- reservation's calendar footprint, regardless of which lane it belongs
-- to -- not just the lane matching their own role. This only widens read
-- visibility of reservation_requests and reservation_occurrences (what the
-- admin calendar renders); it does not touch can_manage_reservation or
-- can_access_reservation, so approve/decline, payments, permits,
-- attachments, and events remain lane-scoped exactly as before.

create or replace function public.can_view_reservation_calendar(
  p_request_id uuid,
  p_admin_id uuid default auth.uid()
) returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.reservation_requests r
    where r.id = p_request_id
      and (
        r.requester_id = p_admin_id
        or exists (
          select 1 from public.profiles p
          where p.id = p_admin_id
            and p.account_status = 'active'
            and p.role in ('internal_admin', 'external_admin')
        )
      )
  );
$$;

revoke all on function public.can_view_reservation_calendar(uuid, uuid) from public, anon;
grant execute on function public.can_view_reservation_calendar(uuid, uuid) to authenticated;

drop policy if exists reservation_requests_read on public.reservation_requests;
create policy reservation_requests_read on public.reservation_requests
for select to authenticated
using (public.can_view_reservation_calendar(id));

drop policy if exists reservation_occurrences_read on public.reservation_occurrences;
create policy reservation_occurrences_read on public.reservation_occurrences
for select to authenticated
using (public.can_view_reservation_calendar(request_id));

notify pgrst, 'reload schema';
