-- Move the deterministic imported facilities from the old west-of-campus
-- placeholder coordinates to the actual CSU Aparri grounds in Maura.
update public.facilities as facility
set latitude = corrected.latitude,
    longitude = corrected.longitude,
    updated_by_name = 'Campus map correction',
    updated_at = now()
from (
  values
    ('10000000-0000-0000-0000-000000000001'::uuid, 18.351092::double precision, 121.649970::double precision),
    ('10000000-0000-0000-0000-000000000002'::uuid, 18.350292::double precision, 121.649070::double precision),
    ('10000000-0000-0000-0000-000000000003'::uuid, 18.352232::double precision, 121.647860::double precision),
    ('10000000-0000-0000-0000-000000000004'::uuid, 18.352522::double precision, 121.649460::double precision),
    ('10000000-0000-0000-0000-000000000005'::uuid, 18.349732::double precision, 121.647670::double precision)
) as corrected(id, latitude, longitude)
where facility.id = corrected.id;
