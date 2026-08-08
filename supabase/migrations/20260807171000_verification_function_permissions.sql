do $$
begin
  execute 'revoke all on function public.decide_verification_atomic(uuid, text, text, uuid) from public, anon, authenticated';
  execute 'grant execute on function public.decide_verification_atomic(uuid, text, text, uuid) to service_role';
end;
$$;
