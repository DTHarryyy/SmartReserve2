-- Pin the search path, as every other function in this schema does.
--
-- It is not security definer, so it runs as the caller either way -- but it is
-- called from inside two functions that ARE, and an unpinned path is exactly
-- the shape that lets a shadowing schema change what those resolve to.
create or replace function public.assistant_format_clock_hour(p_hours numeric)
returns text
language sql
immutable
set search_path = public, pg_catalog
as $$
  select to_char(
    date '2000-01-01' + make_interval(mins => round(p_hours * 60)::integer),
    'FMHH12:MI AM'
  );
$$;

revoke execute on function public.assistant_format_clock_hour(numeric)
  from public, anon;
grant execute on function public.assistant_format_clock_hour(numeric)
  to authenticated;

notify pgrst, 'reload schema';
