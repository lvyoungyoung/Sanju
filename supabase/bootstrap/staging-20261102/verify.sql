DO $verify$
BEGIN
  IF to_regprocedure('public.confirm_purchase_atomically(uuid,text,text,integer)') IS NULL
    OR to_regprocedure('public.transfer_guest_credits(uuid,uuid)') IS NULL
    OR to_regprocedure('public.finalize_generation_job_v3(uuid,uuid,boolean,text,jsonb,text)') IS NULL THEN
    RAISE EXCEPTION 'Required transactional RPC is missing';
  END IF;
  IF has_function_privilege('anon', 'public.confirm_purchase_atomically(uuid,text,text,integer)', 'EXECUTE')
    OR has_function_privilege('authenticated', 'public.confirm_purchase_atomically(uuid,text,text,integer)', 'EXECUTE')
    OR NOT has_function_privilege('service_role', 'public.confirm_purchase_atomically(uuid,text,text,integer)', 'EXECUTE') THEN
    RAISE EXCEPTION 'Purchase RPC permissions differ from the source';
  END IF;
  IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid='public.profiles'::regclass)
    OR NOT (SELECT relrowsecurity FROM pg_class WHERE oid='public.memories'::regclass)
    OR NOT (SELECT relrowsecurity FROM pg_class WHERE oid='public.memory_sentences'::regclass) THEN
    RAISE EXCEPTION 'Core RLS is disabled';
  END IF;
  IF (SELECT count(*) FROM public.language_capabilities_v1) <> 10
    OR (SELECT count(*) FROM storage.buckets WHERE id IN ('memories', 'avatars') AND NOT public) <> 2
    OR (SELECT count(*) FROM pg_policies WHERE schemaname='storage' AND tablename='objects') <> 7 THEN
    RAISE EXCEPTION 'Required catalog, private buckets or storage policies are missing';
  END IF;
  IF EXISTS (SELECT 1 FROM auth.users) OR EXISTS (SELECT 1 FROM public.profiles)
    OR EXISTS (SELECT 1 FROM public.memories) OR EXISTS (SELECT 1 FROM public.purchase_ledger)
    OR EXISTS (SELECT 1 FROM storage.objects) THEN
    RAISE EXCEPTION 'Fresh staging contains unexpected user data';
  END IF;
END;
$verify$;
