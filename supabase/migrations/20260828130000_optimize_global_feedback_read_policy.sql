-- Keep global feedback visibility for external administrators, but make the
-- RLS helper calls initPlan-friendly so they are not re-evaluated per row.

drop policy if exists reservation_feedback_read on public.reservation_feedback;
create policy reservation_feedback_read
on public.reservation_feedback for select to authenticated
using (
  user_id = (select auth.uid())
  or (select public.is_internal_admin())
  or (select public.is_external_admin())
);

notify pgrst, 'reload schema';
