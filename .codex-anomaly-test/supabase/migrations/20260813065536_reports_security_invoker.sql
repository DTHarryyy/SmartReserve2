alter function public.get_admin_report(timestamptz,timestamptz,text)
  security invoker;

notify pgrst, 'reload schema';
