-- lease_push_deliveries used to claim deliveries whose recipient had no
-- enabled token left (e.g. the only device was signed out or reported dead
-- after the row was enqueued). send-push drops token-less jobs without
-- completing them, so those rows sat in 'processing' and were re-leased on
-- every sweep until they burned through max_attempts. They can never be
-- delivered, so they are now marked 'skipped' before candidates are picked,
-- and candidates require at least one enabled token.

create or replace function public.lease_push_deliveries(
  p_limit integer default 25,
  p_lease_seconds integer default 120,
  p_max_attempts integer default 5
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  bounded_limit integer := greatest(1, least(coalesce(p_limit, 25), 100));
  result_value jsonb;
begin
  if coalesce(p_max_attempts, 5) < 1 then
    raise exception using errcode = '22023', message = 'Invalid max attempts';
  end if;

  update public.push_deliveries
  set status = 'failed',
      last_error_code = 'stale_processing',
      next_attempt_at = null,
      locked_at = null
  where status = 'processing'
    and coalesce(locked_at, created_at)
      < now() - make_interval(secs => greatest(30, coalesce(p_lease_seconds, 120)))
    and attempt_count >= coalesce(p_max_attempts, 5);

  update public.push_deliveries d
  set status = 'skipped',
      last_error_code = 'no_enabled_token',
      next_attempt_at = null,
      locked_at = null
  where (
      d.status = 'pending'
      or (d.status = 'processing'
        and coalesce(d.locked_at, d.created_at)
          < now() - make_interval(secs => greatest(30, coalesce(p_lease_seconds, 120))))
    )
    and not exists (
      select 1 from public.user_push_tokens t
      where t.user_id = d.recipient_id and t.enabled
    );

  with candidates as (
    select d.id
    from public.push_deliveries d
    where d.attempt_count < coalesce(p_max_attempts, 5)
      and (
        (d.status = 'pending' and coalesce(d.next_attempt_at, d.created_at) <= now())
        or
        (d.status = 'processing'
          and coalesce(d.locked_at, d.created_at)
            < now() - make_interval(secs => greatest(30, coalesce(p_lease_seconds, 120))))
      )
      and exists (
        select 1 from public.user_push_tokens t
        where t.user_id = d.recipient_id and t.enabled
      )
    order by coalesce(d.next_attempt_at, d.created_at), d.created_at
    for update of d skip locked
    limit bounded_limit
  ),
  claimed as (
    update public.push_deliveries d
    set status = 'processing',
        locked_at = now(),
        next_attempt_at = null,
        last_error_code = null,
        attempt_count = d.attempt_count + 1
    from candidates c
    where d.id = c.id
    returning d.*
  )
  select jsonb_build_object(
    'rows',
    coalesce(jsonb_agg(jsonb_build_object(
      'id', c.id,
      'notification_id', c.notification_id,
      'recipient_id', c.recipient_id,
      'attempt_count', c.attempt_count,
      'kind', n.kind,
      'title', n.title,
      'body', n.body,
      'request_id', n.request_id,
      'tokens', (
        select coalesce(jsonb_agg(t.token), '[]'::jsonb)
        from public.user_push_tokens t
        where t.user_id = c.recipient_id and t.enabled
      )
    ) order by c.created_at), '[]'::jsonb)
  )
  into result_value
  from claimed c
  join public.app_notifications n on n.id = c.notification_id;

  return coalesce(result_value, jsonb_build_object('rows', '[]'::jsonb));
end;
$$;

revoke all on function public.lease_push_deliveries(integer, integer, integer)
from public, anon, authenticated;
grant execute on function public.lease_push_deliveries(integer, integer, integer)
to service_role;

notify pgrst, 'reload schema';
