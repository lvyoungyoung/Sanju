-- Disable theme-triggered repairs, including requests from older deployments.
-- Keep the old signatures inert until all clients/functions have been updated.
create or replace function public.get_study_scene_enrichment_status(p_user_id uuid, p_scene_id uuid)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if not exists (select 1 from public.study_scenes where id = p_scene_id and user_id = p_user_id) then
    raise exception 'Study scene not found';
  end if;
  return jsonb_build_object('pendingCount', 0, 'completedCount', 0, 'failedCount', 0, 'retryAfterSeconds', 5);
end;
$$;

create or replace function public.begin_study_scene_enrichment(p_user_id uuid, p_scene_id uuid)
returns jsonb language sql security definer set search_path = public, pg_temp as $$
  select public.get_study_scene_enrichment_status(p_user_id, p_scene_id);
$$;

create or replace function public.create_study_scene_with_enrichment(
  p_user_id uuid, p_name text, p_embedding jsonb, p_model text default 'qwen3.7-text-embedding'
)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare scene jsonb;
begin
  select to_jsonb(s) into scene from public.create_study_scene_with_embedding(p_user_id, p_name, p_embedding, p_model) s;
  if scene is null then raise exception 'Study scene response is invalid'; end if;
  return jsonb_build_object('scene', scene, 'enrichment',
    public.get_study_scene_enrichment_status(p_user_id, (scene->>'id')::uuid));
end;
$$;

-- Normal generation still claims its own first attempt, never another photo's
-- work or a failed attempt. Existing leases/checkpoints are left untouched.
create or replace function public.claim_scoped_generation_enrichment(
  p_user_id uuid, p_memory_id uuid default null, p_guest_job_id uuid default null, p_scene_id uuid default null
)
returns setof public.generation_enrichment_jobs
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_id uuid;
begin
  if p_user_id is null or num_nonnulls(p_memory_id, p_guest_job_id, p_scene_id) <> 1 then
    raise exception 'A single enrichment scope is required';
  end if;
  if p_scene_id is not null then
    if not exists (select 1 from public.study_scenes where id = p_scene_id and user_id = p_user_id) then
      raise exception 'Study scene not found';
    end if;
    return;
  end if;
  perform pg_advisory_xact_lock(hashtextextended('generation-enrichment-claim', 0));
  if (select count(*) from public.generation_enrichment_jobs
      where status = 'processing' and lease_until > now()) >= 8 then return; end if;
  select j.id into v_id from public.generation_enrichment_jobs j
  where j.status = 'pending' and j.next_attempt_at <= now()
    and j.user_id = p_user_id and j.attempts = 0
    and ((p_memory_id is not null and j.memory_id = p_memory_id)
      or (p_guest_job_id is not null and j.guest_job_id = p_guest_job_id))
  order by j.created_at, j.id for update skip locked limit 1;
  if v_id is null then return; end if;
  return query update public.generation_enrichment_jobs set
    status = 'processing', attempts = attempts + 1,
    lease_token = gen_random_uuid(), lease_until = now() + interval '2 minutes'
    where id = v_id returning *;
end;
$$;

revoke all on function public.begin_study_scene_enrichment(uuid, uuid) from public, anon, authenticated;
revoke all on function public.get_study_scene_enrichment_status(uuid, uuid) from public, anon, authenticated;
revoke all on function public.claim_scoped_generation_enrichment(uuid, uuid, uuid, uuid) from public, anon, authenticated;
revoke all on function public.create_study_scene_with_enrichment(uuid, text, jsonb, text) from public, anon, authenticated;
grant execute on function public.begin_study_scene_enrichment(uuid, uuid) to service_role;
grant execute on function public.get_study_scene_enrichment_status(uuid, uuid) to service_role;
grant execute on function public.claim_scoped_generation_enrichment(uuid, uuid, uuid, uuid) to service_role;
grant execute on function public.create_study_scene_with_enrichment(uuid, text, jsonb, text) to service_role;

notify pgrst, 'reload schema';
