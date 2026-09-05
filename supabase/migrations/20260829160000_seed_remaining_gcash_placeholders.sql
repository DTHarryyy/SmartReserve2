-- 20260824130000 seeded a temporary GCash destination only for facilities
-- that already had a paid reservation at the time it ran, so approval stayed
-- blocked (apply_reservation_payment_gate) for every facility added or paid
-- for afterward. Seed the official default account for every facility that
-- still has no active GCash method, regardless of reservation history.
insert into public.facility_payment_methods (facility_id, account_name, account_number, instructions)
select f.id, 'Janna Grace Somera', '09123456789',
       'Send GCash payment to Janna Grace Somera - 09123456789. Submit the reference number and proof in SmartReserve after approval.'
from public.facilities f
where not exists (
  select 1 from public.facility_payment_methods m
  where m.facility_id = f.id and m.enabled and m.method_type = 'gcash'
);
