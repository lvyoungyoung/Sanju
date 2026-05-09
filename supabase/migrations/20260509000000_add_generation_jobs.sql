create table if not exists public.generation_jobs (
  id uuid primary key default gen_random_uuid(),
  client_request_id uuid not null unique,
  user_id uuid not null references public.profiles (id) on delete cascade,
  status text not null default 'pending'
    check (status in ('pending', 'completed', 'failed')),
  memory_id uuid references public.memories (id) on delete set null,
  image_path text,
  provider text,
  mimo_failure_reason text,
  remaining_credits integer,
  error_message text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  completed_at timestamptz,
  failed_at timestamptz
);

create index if not exists generation_jobs_user_id_created_at_idx
  on public.generation_jobs (user_id, created_at desc);

alter table public.generation_jobs enable row level security;

revoke all on table public.generation_jobs from anon;
grant select on table public.generation_jobs to authenticated;

drop policy if exists "Users can read own generation jobs" on public.generation_jobs;
create policy "Users can read own generation jobs"
  on public.generation_jobs
  for select
  to authenticated
  using (auth.uid() = user_id);

drop policy if exists "Users cannot write generation jobs directly" on public.generation_jobs;
create policy "Users cannot write generation jobs directly"
  on public.generation_jobs
  for all
  to authenticated
  using (false)
  with check (false);
