-- Caller must use a transaction. Synthetic SQL-only purchase; no Apple API or persistent user.
SAVEPOINT runtime_smoke;
INSERT INTO auth.users (id, aud, role, email)
VALUES ('f4d3bc21-452d-42df-ad53-3aa05b448e61', 'authenticated', 'authenticated', 'staging-bootstrap@example.invalid');
INSERT INTO public.profiles (id, available_generations)
VALUES ('f4d3bc21-452d-42df-ad53-3aa05b448e61', 10);
SELECT set_config('request.jwt.claims', '{"role":"service_role"}', true);
DO $smoke$
DECLARE result record;
BEGIN
  SELECT * INTO result FROM public.confirm_purchase_atomically(
    'f4d3bc21-452d-42df-ad53-3aa05b448e61', 'bootstrap-synthetic-transaction', 'bootstrap-synthetic-product', 200);
  IF result.remaining_credits <> 210 OR result.already_processed THEN
    RAISE EXCEPTION 'Atomic credit addition failed';
  END IF;
  SELECT * INTO result FROM public.confirm_purchase_atomically(
    'f4d3bc21-452d-42df-ad53-3aa05b448e61', 'bootstrap-synthetic-transaction', 'bootstrap-synthetic-product', 200);
  IF result.remaining_credits <> 210 OR NOT result.already_processed
    OR (SELECT count(*) FROM public.purchase_ledger) <> 1
    OR (SELECT count(*) FROM public.generation_transactions WHERE reason='purchase') <> 1 THEN
    RAISE EXCEPTION 'Duplicate purchase idempotency failed';
  END IF;
END;
$smoke$;
ROLLBACK TO SAVEPOINT runtime_smoke;
RELEASE SAVEPOINT runtime_smoke;
