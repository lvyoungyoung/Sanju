alter table public.profiles
  add column if not exists migration_smoke_test_20260504 text;

comment on column public.profiles.migration_smoke_test_20260504
  is 'Temporary column used to verify the staging-to-production database migration workflow.';
