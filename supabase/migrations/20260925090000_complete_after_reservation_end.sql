-- A checked-in occurrence stays active until its reserved end time. The UI
-- mirrors this gate, while this trigger keeps direct/RPC updates from closing
-- an occurrence early.
create or replace function public.enforce_occurrence_completion_after_end()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if old.lifecycle_stage = 'checked_in'
     and new.lifecycle_stage = 'completed'
     and now() < new.ends_at then
    raise exception using
      errcode = '22023',
      message = 'Completion becomes available after the reservation end time';
  end if;
  return new;
end;
$$;

drop trigger if exists enforce_occurrence_completion_after_end
on public.reservation_occurrences;

create trigger enforce_occurrence_completion_after_end
before update of lifecycle_stage on public.reservation_occurrences
for each row
execute function public.enforce_occurrence_completion_after_end();
