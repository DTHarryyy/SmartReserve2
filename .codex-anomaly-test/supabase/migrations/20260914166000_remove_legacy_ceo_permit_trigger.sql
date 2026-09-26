-- Permit generation now binds immutable, role-specific official signature
-- revisions in prepare_reservation_permit.  The old CEO-signature trigger
-- predates that model and fires on every insert, even for internal permits;
-- it therefore rejects a valid internal permit unless an unrelated legacy
-- CEO signature has also been uploaded.
--
-- Do not remove the legacy columns or historical revision rows here: older
-- issued permits may still reference them.  Removing the trigger is enough
-- to make new rows rely exclusively on the current, template-aware contract.
drop trigger if exists reservation_permits_attach_signature_revisions
  on public.reservation_permits;

drop function if exists public.attach_permit_signature_revisions();

notify pgrst, 'reload schema';
