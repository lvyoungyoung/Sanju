-- Durable outbox: the result, debit and indexing payload commit together.
-- Only service workers may inspect/claim jobs; clients keep the same responses.
create table public.generation_enrichment_jobs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  memory_id uuid unique references public.memories(id) on delete cascade,
  -- Guest result cleanup must not discard an unfinished indexing payload.
  guest_job_id uuid unique,
  sentences jsonb not null check (jsonb_typeof(sentences) = 'array'),
  status text not null default 'pending' check (status in ('pending', 'processing', 'completed')),
  attempts integer not null default 0,
  next_attempt_at timestamptz not null default now(),
  lease_token uuid,
  lease_until timestamptz,
  last_error text,
  created_at timestamptz not null default now(),
  completed_at timestamptz,
  check ((memory_id is null) <> (guest_job_id is null))
);
create index generation_enrichment_pending_idx on public.generation_enrichment_jobs(next_attempt_at, created_at)
  where status <> 'completed';
create index generation_enrichment_owner_idx on public.generation_enrichment_jobs(user_id);
alter table public.generation_enrichment_jobs enable row level security;
revoke all on public.generation_enrichment_jobs from public, anon, authenticated;
grant select, insert, update, delete on public.generation_enrichment_jobs to service_role;

create or replace function public.claim_generation_enrichment(p_user_id uuid default null)
returns setof public.generation_enrichment_jobs
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_id uuid;
begin
  -- Bound aggregate background concurrency independently of generation slots.
  perform pg_advisory_xact_lock(hashtextextended('generation-enrichment-claim', 0));
  if (select count(*) from public.generation_enrichment_jobs
      where status = 'processing' and lease_until > now()) >= 8 then return; end if;
  select id into v_id from public.generation_enrichment_jobs
  where (p_user_id is null or user_id = p_user_id)
    and ((status = 'pending' and next_attempt_at <= now())
      or (status = 'processing' and lease_until <= now()))
  order by created_at, id for update skip locked limit 1;
  if v_id is null then return; end if;
  return query update public.generation_enrichment_jobs set
    status = 'processing', attempts = attempts + 1,
    lease_token = gen_random_uuid(), lease_until = now() + interval '2 minutes'
  where id = v_id returning *;
end;
$$;

create or replace function public.retry_generation_enrichment(p_job_id uuid, p_lease_token uuid, p_error text)
returns void language sql security definer set search_path = public, pg_temp as $$
  update public.generation_enrichment_jobs set status = 'pending', lease_token = null, lease_until = null,
    next_attempt_at = now() + make_interval(secs => least(900, 30 * power(2, least(attempts - 1, 5)))::integer),
    last_error = left(p_error, 500)
  where id = p_job_id and status = 'processing' and lease_token = p_lease_token;
$$;

create or replace function public.complete_generation_enrichment(p_job_id uuid, p_lease_token uuid, p_rows jsonb)
returns boolean language plpgsql security definer set search_path = public, pg_temp as $$
declare
  job public.generation_enrichment_jobs;
  item jsonb;
  source_sentence jsonb;
  original_vector real[];
  purpose_vector real[];
  purpose text;
  sentence_uuid uuid;
begin
  select * into job from public.generation_enrichment_jobs
  where id = p_job_id and status = 'processing' and lease_token = p_lease_token and lease_until > now()
  for update;
  if not found then return false; end if;
  if p_rows is null or jsonb_typeof(p_rows) <> 'array'
      or jsonb_array_length(p_rows) <> jsonb_array_length(job.sentences)
      or (select count(distinct value->>'sentence_id') from jsonb_array_elements(p_rows)) <> jsonb_array_length(p_rows) then
    raise exception 'Invalid indexing result';
  end if;
  for item in select value from jsonb_array_elements(p_rows) loop
    sentence_uuid := (item->>'sentence_id')::uuid;
    select value into source_sentence from jsonb_array_elements(job.sentences)
      where (value->>'id')::uuid = sentence_uuid;
    if source_sentence is null then raise exception 'Unexpected indexing sentence'; end if;
    purpose := nullif(btrim(source_sentence->>'expression_purpose'), '');
    original_vector := public.jsonb_to_embedding_real_array(item->'embedding');
    purpose_vector := case when purpose is not null then public.jsonb_to_embedding_real_array(item->'purpose_embedding') end;
    if original_vector is null or cardinality(original_vector) <> 1024
      or array_position(original_vector, null) is not null
      or original_vector && array['NaN'::real, 'Infinity'::real, '-Infinity'::real]
      or original_vector = array_fill(0::real, array[1024])
      or (purpose is not null and (purpose_vector is null or cardinality(purpose_vector) <> 1024
        or array_position(purpose_vector, null) is not null
        or purpose_vector && array['NaN'::real, 'Infinity'::real, '-Infinity'::real]
        or purpose_vector = array_fill(0::real, array[1024]))) then
      raise exception 'Invalid indexing vectors';
    end if;

    if job.memory_id is not null then
      -- A sentence removed while the model was running must not be resurrected.
      if not exists (select 1 from public.memory_sentences s join public.memories m on m.id = s.memory_id
        where s.id = sentence_uuid and m.id = job.memory_id and m.user_id = job.user_id) then continue; end if;
      insert into public.sentence_embeddings(sentence_id, user_id, embedding, model, expression_purpose, purpose_embedding, updated_at)
      values (sentence_uuid, job.user_id, original_vector, 'qwen3.7-text-embedding', purpose, purpose_vector, now())
      on conflict (sentence_id) do update set
        embedding = excluded.embedding, expression_purpose = excluded.expression_purpose,
        purpose_embedding = excluded.purpose_embedding, model = excluded.model, updated_at = excluded.updated_at;
      perform public.refresh_semantic_study_scene_matches_for_sentence(sentence_uuid, job.user_id);
    else
      -- The existing late-promotion trigger also handles login before vectors arrive.
      insert into public.guest_sentence_embeddings(sentence_id, guest_user_id, guest_job_id, embedding, model,
        expression_purpose, purpose_embedding, updated_at)
      values (sentence_uuid, job.user_id, job.guest_job_id, original_vector, 'qwen3.7-text-embedding', purpose, purpose_vector, now())
      on conflict (sentence_id) do update set embedding = excluded.embedding,
        expression_purpose = excluded.expression_purpose, purpose_embedding = excluded.purpose_embedding,
        model = excluded.model, updated_at = excluded.updated_at;
    end if;
  end loop;
  update public.generation_enrichment_jobs set status = 'completed', completed_at = now(),
    sentences = '[]'::jsonb, lease_token = null, lease_until = null, last_error = null where id = job.id;
  return true;
end;
$$;

revoke all on function public.claim_generation_enrichment(uuid) from public, anon, authenticated;
revoke all on function public.retry_generation_enrichment(uuid, uuid, text) from public, anon, authenticated;
revoke all on function public.complete_generation_enrichment(uuid, uuid, jsonb) from public, anon, authenticated;
grant execute on function public.claim_generation_enrichment(uuid) to service_role;
grant execute on function public.retry_generation_enrichment(uuid, uuid, text) to service_role;
grant execute on function public.complete_generation_enrichment(uuid, uuid, jsonb) to service_role;

create or replace function public.promote_guest_sentence_embedding_for_id(p_sentence_id uuid)
returns boolean language plpgsql security definer set search_path = public, pg_temp as $$
declare v_owner_id uuid; v_count integer;
begin
  -- Serialize migration and late indexing for the same UUID across transactions.
  perform pg_advisory_xact_lock(hashtextextended('guest-sentence:' || p_sentence_id::text, 0));
  select memory.user_id into v_owner_id
  from public.memory_sentences sentence join public.memories memory on memory.id = sentence.memory_id
  where sentence.id = p_sentence_id;
  if v_owner_id is null then return false; end if;
  insert into public.sentence_embeddings as target (
    sentence_id, user_id, embedding, model, expression_purpose, purpose_embedding, updated_at
  )
  select staged.sentence_id, v_owner_id, staged.embedding, staged.model,
    staged.expression_purpose, staged.purpose_embedding, now()
  from public.guest_sentence_embeddings staged where staged.sentence_id = p_sentence_id
  on conflict (sentence_id) do update set
    user_id = excluded.user_id, embedding = excluded.embedding, model = excluded.model,
    expression_purpose = excluded.expression_purpose, purpose_embedding = excluded.purpose_embedding,
    updated_at = excluded.updated_at;
  get diagnostics v_count = row_count;
  if v_count = 0 then return false; end if;
  delete from public.guest_sentence_embeddings where sentence_id = p_sentence_id;
  perform public.refresh_semantic_study_scene_matches_for_sentence(p_sentence_id, v_owner_id);
  return true;
end;
$$;

revoke all on function public.promote_guest_sentence_embedding_for_id(uuid) from public, anon, authenticated;
grant execute on function public.promote_guest_sentence_embedding_for_id(uuid) to service_role;

create or replace function public.finalize_authenticated_generation(
  p_user_id uuid,
  p_memory_id uuid,
  p_client_request_id uuid,
  p_image_path text,
  p_created_at timestamptz,
  p_provider text,
  p_sentences jsonb,
  p_tags text[]
)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  current_balance integer := 0;
  remaining_balance integer := 0;
  generation_job record;
  sentence_item record;
begin
  if p_sentences is null or jsonb_typeof(p_sentences) <> 'array'
     or jsonb_array_length(p_sentences) not in (3, 6) then
    raise exception 'invalid sentences';
  end if;

  if p_client_request_id is not null then
    insert into public.generation_jobs (client_request_id, user_id, status, updated_at)
    values (p_client_request_id, p_user_id, 'pending', timezone('utc', now()))
    on conflict (client_request_id) do nothing;

    select * into generation_job
    from public.generation_jobs
    where client_request_id = p_client_request_id and user_id = p_user_id
    for update;

    if not found then raise exception 'generation job not found'; end if;
    if generation_job.status = 'completed' then
      return coalesce(generation_job.remaining_credits, (select available_generations from public.profiles where id = p_user_id));
    end if;
    if generation_job.status = 'failed' then raise exception 'generation job already failed'; end if;
  end if;

  select available_generations into current_balance
  from public.profiles where id = p_user_id for update;
  if not found then raise exception 'profile not found'; end if;
  if exists (select 1 from public.memories where id = p_memory_id and user_id = p_user_id) then
    return current_balance;
  end if;
  if coalesce(current_balance, 0) <= 0 then raise exception 'No credits left'; end if;

  remaining_balance := current_balance - 1;
  insert into public.memories (id, user_id, image_url, created_at, provider, tags)
  values (
    p_memory_id, p_user_id, p_image_path, coalesce(p_created_at, timezone('utc', now())), p_provider,
    coalesce(array(
      select tag from (
        select distinct on (tag) tag, position
        from unnest(coalesce(p_tags, '{}'::text[])) with ordinality as input(tag, position)
        where tag = any (array['人物','风景','旅行','美食','生活场景','动物','植物','建筑','活动','物品','截图/信息'])
        order by tag, position
      ) as unique_tags order by position limit 3
    ), '{}'::text[])
  );

  for sentence_item in select value, ordinality from jsonb_array_elements(p_sentences) with ordinality loop
    insert into public.memory_sentences (
      id, memory_id, sort_order, english, chinese, learning_topic_ids, presentation_group, is_favorite
    ) values (
      case when nullif(sentence_item.value ->> 'id', '') is null then gen_random_uuid() else (sentence_item.value ->> 'id')::uuid end,
      p_memory_id,
      sentence_item.ordinality - 1,
      btrim(sentence_item.value ->> 'english'),
      btrim(sentence_item.value ->> 'chinese'),
      public.learning_topic_ids_from_json(sentence_item.value -> 'learning_topic_ids'),
      case when sentence_item.value ->> 'presentation_group' = 'what_i_say' then 'what_i_say' else 'what_i_see' end,
      coalesce((sentence_item.value ->> 'is_favorite')::boolean, false)
    );
  end loop;

  update public.profiles set available_generations = remaining_balance where id = p_user_id;
  if to_regclass('public.generation_transactions') is not null then
    insert into public.generation_transactions (user_id, delta, balance_after, reason, note)
    values (p_user_id, -1, remaining_balance, 'generate', 'memory_id:' || p_memory_id::text);
  end if;
  if p_client_request_id is not null then
    update public.generation_jobs set
      status = 'completed', memory_id = p_memory_id, image_path = p_image_path,
      provider = p_provider, remaining_credits = remaining_balance, error_message = null,
      updated_at = timezone('utc', now()), completed_at = coalesce(completed_at, timezone('utc', now())), failed_at = null
    where client_request_id = p_client_request_id and user_id = p_user_id;
  end if;
  insert into public.generation_enrichment_jobs(user_id, memory_id, sentences)
  select p_user_id, p_memory_id, jsonb_agg(jsonb_build_object(
    'id', s.id, 'english', s.english, 'chinese', s.chinese,
    'expression_purpose', input.value->>'expression_purpose') order by s.sort_order)
  from public.memory_sentences s
  join jsonb_array_elements(p_sentences) with ordinality input(value, position)
    on s.sort_order = input.position - 1
  where s.memory_id = p_memory_id;
  return remaining_balance;
end;
$$;

create or replace function public.finalize_guest_generation(
  p_user_id uuid,
  p_guest_job_id uuid,
  p_completed_at timestamptz,
  p_provider text,
  p_sentences jsonb,
  p_tags text[]
)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  current_balance integer := 0;
  remaining_balance integer := 0;
  guest_job record;
begin
  if p_sentences is null or jsonb_typeof(p_sentences) <> 'array'
     or jsonb_array_length(p_sentences) not in (3, 6) then
    raise exception 'invalid sentences';
  end if;
  select * into guest_job from public.guest_generation_jobs
  where id = p_guest_job_id and user_id = p_user_id for update;
  if not found then raise exception 'guest generation job not found'; end if;
  if guest_job.status in ('completed', 'acknowledged') then
    return coalesce(guest_job.remaining_credits, (select available_generations from public.profiles where id = p_user_id));
  end if;
  if guest_job.status = 'failed' then raise exception 'guest generation job already failed'; end if;
  select available_generations into current_balance from public.profiles where id = p_user_id for update;
  if not found then raise exception 'profile not found'; end if;
  if coalesce(current_balance, 0) <= 0 then raise exception 'No credits left'; end if;

  remaining_balance := current_balance - 1;
  update public.profiles set available_generations = remaining_balance where id = p_user_id;
  update public.guest_generation_jobs set
    status = 'completed', completed_at = coalesce(p_completed_at, timezone('utc', now())),
    provider = p_provider, sentences = p_sentences,
    tags = coalesce(array(
      select tag from (
        select distinct on (tag) tag, position
        from unnest(coalesce(p_tags, '{}'::text[])) with ordinality as input(tag, position)
        where tag = any (array['人物','风景','旅行','美食','生活场景','动物','植物','建筑','活动','物品','截图/信息'])
        order by tag, position
      ) as unique_tags order by position limit 3
    ), '{}'::text[]),
    remaining_credits = remaining_balance, error_message = null
  where id = p_guest_job_id and user_id = p_user_id;
  if to_regclass('public.generation_transactions') is not null then
    insert into public.generation_transactions (user_id, delta, balance_after, reason, note)
    values (p_user_id, -1, remaining_balance, 'generate', 'guest_job_id:' || p_guest_job_id::text);
  end if;
  insert into public.generation_enrichment_jobs(user_id, guest_job_id, sentences)
  values (p_user_id, p_guest_job_id, p_sentences);
  return remaining_balance;
end;
$$;

revoke all on function public.finalize_authenticated_generation(uuid, uuid, uuid, text, timestamptz, text, jsonb, text[]) from public, anon, authenticated;
revoke all on function public.finalize_guest_generation(uuid, uuid, timestamptz, text, jsonb, text[]) from public, anon, authenticated;
grant execute on function public.finalize_authenticated_generation(uuid, uuid, uuid, text, timestamptz, text, jsonb, text[]) to service_role;
grant execute on function public.finalize_guest_generation(uuid, uuid, timestamptz, text, jsonb, text[]) to service_role;
notify pgrst, 'reload schema';
