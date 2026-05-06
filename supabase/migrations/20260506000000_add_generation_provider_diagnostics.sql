alter table if exists public.memories
  add column if not exists provider text,
  add column if not exists mimo_failure_reason text;

alter table if exists public.guest_generation_jobs
  add column if not exists mimo_failure_reason text;

create index if not exists memories_provider_created_at_idx
  on public.memories (provider, created_at desc);

create index if not exists memories_mimo_failure_reason_created_at_idx
  on public.memories (mimo_failure_reason, created_at desc)
  where mimo_failure_reason is not null;
