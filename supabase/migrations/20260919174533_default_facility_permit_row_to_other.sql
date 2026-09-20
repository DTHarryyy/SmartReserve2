-- Long-term fix: a brand new facility was landing with
-- internal_permit_row_code/external_permit_row_code = null (the app's
-- create/edit payload never sets these two columns at all -- they're only
-- ever written by the separate Facility Configuration dialog), which
-- silently makes it unbookable ("This facility needs official permit
-- mappings before it can accept reservations") even though it shows as
-- Available/VERIFIED everywhere else. Investigation found 6 of 8 live
-- facilities already stuck in exactly this state.
--
-- Fix: default both columns to 'other' (the always-valid catch-all already
-- in both picklists) so a facility is never silently unbookable from the
-- moment it's created. Admins can still refine it to a more specific
-- official category later via Facility Configuration -- this only removes
-- the "forgot this exists" trap, it doesn't skip deliberate configuration.

alter table public.facilities
  alter column internal_permit_row_code set default 'other',
  alter column external_permit_row_code set default 'other';

-- Backfill the facilities already stuck unmapped. "Audio Visual Room" and
-- "Gymplex" get a specific match from the existing picklist; everything
-- else gets the same generic 'other' the default now applies going forward.
update public.facilities
set internal_permit_row_code = 'audio_visual_main_hall',
    external_permit_row_code = 'avr'
where name = 'Audio Visual Room' and archived_at is null
  and internal_permit_row_code is null;

update public.facilities
set internal_permit_row_code = coalesce(internal_permit_row_code, 'other'),
    external_permit_row_code = 'gym_auditorium'
where name = 'Gymplex' and archived_at is null
  and external_permit_row_code is null;

update public.facilities
set internal_permit_row_code = coalesce(internal_permit_row_code, 'other'),
    external_permit_row_code = coalesce(external_permit_row_code, 'other')
where archived_at is null
  and (internal_permit_row_code is null or external_permit_row_code is null);
