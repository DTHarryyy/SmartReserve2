-- The default GCash seeding function is for the facilities insert trigger
-- only. Keep it out of the exposed RPC surface.

revoke all on function public.seed_default_gcash_payment_method()
  from public, anon, authenticated;

notify pgrst, 'reload schema';
