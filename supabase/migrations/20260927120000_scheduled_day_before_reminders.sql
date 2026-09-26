-- Day-before reservation reminders used to be created only when the renter's
-- app fetched notifications (generate_my_reservation_reminders), so a renter
-- who did not open the app never got one and push could not deliver it.
-- This job creates them for every renter on a schedule; the app_notifications
-- insert trigger then queues the push immediately.

create or replace function public.send_day_before_reminders()
returns integer
language sql
security definer
set search_path = public
as $$
  with inserted as (
    insert into public.app_notifications(recipient_id, request_id, kind, title, body)
    select r.requester_id, r.id, 'reservation_reminder', 'Reservation tomorrow',
           r.facility_name || ' · ' ||
             to_char(min(o.starts_at) at time zone 'Asia/Manila', 'HH24:MI')
    from public.reservation_requests r
    join public.reservation_occurrences o on o.request_id = r.id
    left join public.notification_preferences p on p.user_id = r.requester_id
    where o.booking_state = 'booked'
      and (o.starts_at at time zone 'Asia/Manila')::date =
          (now() at time zone 'Asia/Manila')::date + 1
      and coalesce(p.day_before_reminders, true)
    group by r.id
    on conflict (recipient_id, request_id, kind)
      where kind = 'reservation_reminder' do nothing
    returning 1
  )
  select count(*)::integer from inserted;
$$;

revoke all on function public.send_day_before_reminders() from public, anon, authenticated;
grant execute on function public.send_day_before_reminders() to service_role;

do $$
begin
  if not exists (select 1 from cron.job where jobname = 'smartreserve-day-before-reminders') then
    perform cron.schedule(
      'smartreserve-day-before-reminders', '*/5 * * * *',
      'select public.send_day_before_reminders();'
    );
  end if;
end $$;

notify pgrst, 'reload schema';
