-- Security advisor follow-ups for 20260930055936:
-- * The payable-total helpers are internal to SECURITY DEFINER RPCs; exposed
--   through PostgREST they would reveal any reservation's balance by id.
-- * Pin the search_path of the two pure helpers.

revoke execute on function public.reservation_extra_charges_total(uuid) from authenticated;
revoke execute on function public.reservation_payable_total(uuid) from authenticated;

alter function public.campus_free_hours_end() set search_path = public;
alter function public.format_peso(integer) set search_path = public;
