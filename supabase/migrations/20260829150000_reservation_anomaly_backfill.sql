create table if not exists public.reservation_anomaly_backfill_runs (
  id uuid primary key default gen_random_uuid(),
  dry_run boolean not null,
  notify boolean not null,
  batch_size integer not null,
  cursor_renter_id uuid,
  processed_count integer not null default 0,
  result jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

alter table public.reservation_anomaly_backfill_runs enable row level security;
revoke all on public.reservation_anomaly_backfill_runs from public, anon, authenticated;

create or replace function public.backfill_reservation_anomalies(
  p_dry_run boolean default true,
  p_notify boolean default false,
  p_batch_size integer default 100,
  p_cursor uuid default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  row record;
  processed integer := 0;
  run_id uuid;
  results jsonb := '[]'::jsonb;
begin
  if p_batch_size not between 1 and 500 then
    raise exception using errcode = '22023', message = 'Invalid batch size';
  end if;

  perform public.refresh_facility_anomaly_baselines(null, now());

  for row in
    select distinct requester_id as renter_id, admin_lane
    from public.reservation_requests
    where (p_cursor is null or requester_id > p_cursor)
    order by requester_id, admin_lane
    limit p_batch_size
  loop
    if p_dry_run then
      results := results || jsonb_build_array(jsonb_build_object(
        'renter_id', row.renter_id,
        'admin_lane', row.admin_lane,
        'would_evaluate', true
      ));
    else
      results := results || jsonb_build_array(
        public.evaluate_renter_anomalies(row.renter_id, row.admin_lane, now(), 'backfill', p_notify)
      );
    end if;
    processed := processed + 1;
  end loop;

  insert into public.reservation_anomaly_backfill_runs(
    dry_run, notify, batch_size, cursor_renter_id, processed_count, result
  ) values (
    p_dry_run, p_notify, p_batch_size, p_cursor, processed, results
  ) returning id into run_id;

  return jsonb_build_object(
    'run_id', run_id,
    'dry_run', p_dry_run,
    'notify', p_notify,
    'processed_count', processed,
    'results', results
  );
end;
$$;

revoke all on function public.backfill_reservation_anomalies(boolean, boolean, integer, uuid) from public, anon, authenticated;
grant execute on function public.backfill_reservation_anomalies(boolean, boolean, integer, uuid) to service_role;

notify pgrst, 'reload schema';
