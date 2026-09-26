-- Inert in production: only staging workers write these small diagnostic reports.
-- Keep one attempt per job, and never expose the enrichment queue or its payload.
create table public.generation_enrichment_timings (
  job_id uuid primary key references public.generation_enrichment_jobs(id) on delete cascade,
  attempt integer not null check (attempt > 0),
  report jsonb not null check (jsonb_typeof(report) = 'object' and octet_length(report::text) <= 16384),
  updated_at timestamptz not null default now()
);
alter table public.generation_enrichment_timings enable row level security;
revoke all on public.generation_enrichment_timings from public, anon, authenticated;
grant select, insert, update, delete on public.generation_enrichment_timings to service_role;

create or replace function public.save_generation_enrichment_timing(p_job_id uuid, p_attempt integer, p_report jsonb)
returns void language sql security definer set search_path = public, pg_temp as $$
  insert into public.generation_enrichment_timings as current (job_id, attempt, report)
  select j.id, p_attempt, p_report from public.generation_enrichment_jobs j
  where j.id = p_job_id and j.attempts = p_attempt
  on conflict (job_id) do update set attempt = excluded.attempt,
    report = excluded.report, updated_at = now()
  where excluded.attempt >= current.attempt;
$$;
revoke all on function public.save_generation_enrichment_timing(uuid, integer, jsonb) from public, anon, authenticated;
grant execute on function public.save_generation_enrichment_timing(uuid, integer, jsonb) to service_role;

create or replace function public.get_generation_enrichment_timing(p_memory_id uuid default null, p_guest_job_id uuid default null)
returns jsonb language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_build_object('status', j.status, 'attempt', j.attempts, 'report', t.report)
  from public.generation_enrichment_jobs j
  left join public.generation_enrichment_timings t on t.job_id = j.id and t.attempt = j.attempts
  where auth.uid() is not null and j.user_id = auth.uid()
    and ((p_memory_id is not null and p_guest_job_id is null and j.memory_id = p_memory_id)
      or (p_guest_job_id is not null and p_memory_id is null and j.guest_job_id = p_guest_job_id))
  limit 1;
$$;
revoke all on function public.get_generation_enrichment_timing(uuid, uuid) from public, anon;
grant execute on function public.get_generation_enrichment_timing(uuid, uuid) to authenticated;
