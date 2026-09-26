-- A creation snapshots missing work. Reading a topic cannot enroll new work.
create table public.study_scene_enrichment_jobs (
  scene_id uuid not null references public.study_scenes(id) on delete cascade,
  job_id uuid not null references public.generation_enrichment_jobs(id) on delete cascade,
  attempt_limit integer not null,
  expires_at timestamptz not null,
  primary key (scene_id, job_id)
);
create index study_scene_enrichment_job_idx on public.study_scene_enrichment_jobs(job_id);
alter table public.study_scene_enrichment_jobs enable row level security;
revoke all on public.study_scene_enrichment_jobs from public, anon, authenticated;
grant all on public.study_scene_enrichment_jobs to service_role;

create or replace function public.get_study_scene_enrichment_status(p_user_id uuid, p_scene_id uuid)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare result jsonb;
begin
  if not exists (select 1 from public.study_scenes where id = p_scene_id and user_id = p_user_id) then
    raise exception 'Study scene not found';
  end if;
  select jsonb_build_object(
    'pendingCount', count(*) filter (where eligible),
    'completedCount', count(*) filter (where status = 'completed'),
    'failedCount', count(*) filter (where status <> 'completed' and not eligible),
    'retryAfterSeconds', 5
  ) into result from (
    select j.status, (j.status <> 'completed' and link.expires_at > now()
      and (j.attempts < link.attempt_limit or (j.status = 'processing' and j.lease_until > now()))) as eligible
    from public.study_scene_enrichment_jobs link
    join public.generation_enrichment_jobs j on j.id = link.job_id
    where link.scene_id = p_scene_id
  ) work;
  return result;
end;
$$;

create or replace function public.begin_study_scene_enrichment(p_user_id uuid, p_scene_id uuid)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare missing record; job public.generation_enrichment_jobs;
begin
  if not exists (select 1 from public.study_scenes where id = p_scene_id and user_id = p_user_id) then
    raise exception 'Study scene not found';
  end if;
  -- Shares the claim lock: never reset work while a worker is acquiring a lease.
  perform pg_advisory_xact_lock(hashtextextended('generation-enrichment-claim', 0));
  -- A repeated HTTP creation request must not renew the retry budget/backoff.
  if exists (select 1 from public.study_scene_enrichment_jobs where scene_id = p_scene_id and expires_at > now()) then
    return public.get_study_scene_enrichment_status(p_user_id, p_scene_id);
  end if;
  delete from public.study_scene_enrichment_jobs where scene_id = p_scene_id;
  for missing in
    select m.id as memory_id, jsonb_agg(jsonb_build_object(
      'id', s.id, 'english', s.english, 'chinese', s.chinese
    ) order by s.sort_order, s.id) as sentences
    from public.memories m join public.memory_sentences s on s.memory_id = m.id
    left join public.sentence_embeddings e on e.sentence_id = s.id and e.user_id = p_user_id
    where m.user_id = p_user_id and (
      e.sentence_id is null or e.model is distinct from 'qwen3.7-text-embedding'
      or e.learning_topic_ids is null -- [] is a valid, completed classification.
      or nullif(btrim(e.expression_purpose), '') is null
      or e.embedding is null or cardinality(e.embedding) <> 1024
      or e.purpose_embedding is null or cardinality(e.purpose_embedding) <> 1024
    )
    group by m.id
  loop
    select * into job from public.generation_enrichment_jobs where memory_id = missing.memory_id for update;
    if not found then
      -- Login preserves sentence UUIDs. Reuse a guest job instead of racing its
      -- late-promotion worker with a second metadata request for the same batch.
      select j.* into job from public.generation_enrichment_jobs j
      where j.guest_job_id is not null and j.status <> 'completed'
        and jsonb_array_length(j.sentences) > 0
        and exists (select 1 from jsonb_array_elements(j.sentences) item
          join public.memory_sentences s on s.id::text = item->>'id'
          where s.memory_id = missing.memory_id)
        and not exists (select 1 from jsonb_array_elements(j.sentences) item
          where not exists (select 1 from public.memory_sentences s
            where s.id::text = item->>'id' and s.memory_id = missing.memory_id))
      order by j.created_at limit 1 for update;
    end if;
    if job.id is null then
      insert into public.generation_enrichment_jobs(user_id, memory_id, sentences)
      values (p_user_id, missing.memory_id, missing.sentences) returning * into job;
    elsif job.status = 'completed' then
      -- Historical/partial data can be absent even though an older job completed.
      update public.generation_enrichment_jobs set status = 'pending', sentences = missing.sentences,
        metadata = null, completed_at = null, lease_token = null, lease_until = null,
        next_attempt_at = now(), last_error = null where id = job.id returning * into job;
    elsif job.status = 'pending' then
      update public.generation_enrichment_jobs set next_attempt_at = now()
      where id = job.id returning * into job;
    end if;
    insert into public.study_scene_enrichment_jobs(scene_id, job_id, attempt_limit, expires_at)
    values (p_scene_id, job.id, job.attempts + 2, now() + interval '15 minutes');
  end loop;
  return public.get_study_scene_enrichment_status(p_user_id, p_scene_id);
end;
$$;

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
  if p_scene_id is not null and not exists (
    select 1 from public.study_scenes where id = p_scene_id and user_id = p_user_id
  ) then raise exception 'Study scene not found'; end if;
  perform pg_advisory_xact_lock(hashtextextended('generation-enrichment-claim', 0));
  if (select count(*) from public.generation_enrichment_jobs
      where status = 'processing' and lease_until > now()) >= 8 then return; end if;
  select j.id into v_id from public.generation_enrichment_jobs j
  where ((j.status = 'pending' and j.next_attempt_at <= now())
      or (j.status = 'processing' and j.lease_until <= now()))
    and case when p_scene_id is null then
      j.user_id = p_user_id and j.attempts = 0 and
        ((p_memory_id is not null and j.memory_id = p_memory_id)
          or (p_guest_job_id is not null and j.guest_job_id = p_guest_job_id))
    else exists (select 1 from public.study_scene_enrichment_jobs link
      where link.scene_id = p_scene_id and link.job_id = j.id
        and link.expires_at > now() and j.attempts < link.attempt_limit)
    end
  order by j.created_at, j.id for update skip locked limit 1;
  if v_id is null then return; end if;
  return query update public.generation_enrichment_jobs set
    status = 'processing', attempts = attempts + 1,
    lease_token = gen_random_uuid(), lease_until = now() + interval '2 minutes'
    where id = v_id returning *;
end;
$$;

-- Keep topic creation and repair enrollment in one transaction.
create or replace function public.create_study_scene_with_enrichment(
  p_user_id uuid, p_name text, p_embedding jsonb, p_model text default 'qwen3.7-text-embedding'
)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare scene jsonb; progress jsonb;
begin
  select to_jsonb(s) into scene from public.create_study_scene_with_embedding(p_user_id, p_name, p_embedding, p_model) s;
  if scene is null then raise exception 'Study scene response is invalid'; end if;
  progress := public.begin_study_scene_enrichment(p_user_id, (scene->>'id')::uuid);
  return jsonb_build_object('scene', scene, 'enrichment', progress);
end;
$$;

-- Disable the old owner-wide/global sweep, including calls from old deployments.
create or replace function public.claim_generation_enrichment(p_user_id uuid default null)
returns setof public.generation_enrichment_jobs
language sql security definer set search_path = public, pg_temp as $$
  select * from public.generation_enrichment_jobs where false;
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
