-- Stage two owns sentence metadata. Foreground finalizers and response contracts
-- stay unchanged: persisted results, one debit and durable work still commit together.
alter table public.generation_enrichment_jobs add column metadata jsonb
  check (metadata is null or jsonb_typeof(metadata) = 'array');
alter table public.sentence_embeddings add column learning_topic_ids text[];
alter table public.guest_sentence_embeddings add column learning_topic_ids text[];

create or replace function public.save_generation_enrichment_metadata(
  p_job_id uuid, p_lease_token uuid, p_metadata jsonb
)
returns boolean language plpgsql security definer set search_path = public, pg_temp as $$
declare
  job public.generation_enrichment_jobs;
  item jsonb;
  purpose text;
  topics text[];
begin
  select * into job from public.generation_enrichment_jobs
  where id = p_job_id and status = 'processing' and lease_token = p_lease_token and lease_until > now()
  for update;
  if not found then return false; end if;
  if job.metadata is not null then return false; end if;
  if p_metadata is null or jsonb_typeof(p_metadata) <> 'array'
      or jsonb_array_length(p_metadata) <> jsonb_array_length(job.sentences)
      or (select count(distinct value->>'sentence_id') from jsonb_array_elements(p_metadata)) <> jsonb_array_length(p_metadata) then
    raise exception 'Invalid sentence metadata count';
  end if;
  for item in select value from jsonb_array_elements(p_metadata) loop
    if jsonb_typeof(item->'sentence_id') is distinct from 'string'
      or not exists (select 1 from jsonb_array_elements(job.sentences) source
        where source->>'id' = item->>'sentence_id') then
      raise exception 'Invalid sentence metadata identity';
    end if;
    purpose := nullif(btrim(item->>'expression_purpose'), '');
    if jsonb_typeof(item->'expression_purpose') is distinct from 'string' or purpose is null
      or char_length(purpose) > 240 or cardinality(regexp_split_to_array(purpose, '\s+')) > 30 then
      raise exception 'Invalid sentence expression purpose';
    end if;
    if jsonb_typeof(item->'learning_topic_ids') is distinct from 'array' then
      raise exception 'Invalid sentence metadata categories';
    end if;
    topics := public.learning_topic_ids_from_json(item->'learning_topic_ids');
    if to_jsonb(topics) is distinct from item->'learning_topic_ids' then
      raise exception 'Invalid sentence metadata categories';
    end if;
  end loop;
  update public.generation_enrichment_jobs set metadata = p_metadata where id = job.id;
  return true;
end;
$$;
revoke all on function public.save_generation_enrichment_metadata(uuid, uuid, jsonb) from public, anon, authenticated;
grant execute on function public.save_generation_enrichment_metadata(uuid, uuid, jsonb) to service_role;

-- A client may still upload the initially returned empty categories after the
-- background task has finished. Preserve the server's canonical classification.
create or replace function public.preserve_enriched_sentence_categories()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
declare topics text[];
begin
  select e.learning_topic_ids into topics
  from public.sentence_embeddings e join public.memories m on m.id = new.memory_id
  where e.sentence_id = new.id and e.user_id = m.user_id;
  if topics is not null then new.learning_topic_ids := topics; end if;
  return new;
end;
$$;
create trigger preserve_enriched_sentence_categories
before insert or update of learning_topic_ids on public.memory_sentences
for each row execute function public.preserve_enriched_sentence_categories();
revoke all on function public.preserve_enriched_sentence_categories() from public, anon, authenticated;

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
  topics text[];
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
    if job.metadata is not null then
      select value into source_sentence from jsonb_array_elements(job.metadata)
        where (value->>'sentence_id')::uuid = sentence_uuid;
      if source_sentence is null then raise exception 'Missing sentence metadata'; end if;
    end if;
    purpose := nullif(btrim(source_sentence->>'expression_purpose'), '');
    if purpose is null then raise exception 'Sentence metadata required before indexing'; end if;
    topics := case when job.metadata is not null
      then public.learning_topic_ids_from_json(source_sentence->'learning_topic_ids') end;
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
      insert into public.sentence_embeddings(sentence_id, user_id, embedding, model, expression_purpose, purpose_embedding, learning_topic_ids, updated_at)
      values (sentence_uuid, job.user_id, original_vector, 'qwen3.7-text-embedding', purpose, purpose_vector, topics, now())
      on conflict (sentence_id) do update set
        embedding = excluded.embedding, expression_purpose = excluded.expression_purpose,
        purpose_embedding = excluded.purpose_embedding,
        learning_topic_ids = coalesce(excluded.learning_topic_ids, sentence_embeddings.learning_topic_ids),
        model = excluded.model, updated_at = excluded.updated_at;
      if topics is not null then
        update public.memory_sentences set learning_topic_ids = topics
        where id = sentence_uuid and learning_topic_ids is distinct from topics;
      end if;
      perform public.refresh_semantic_study_scene_matches_for_sentence(sentence_uuid, job.user_id);
    else
      -- The existing late-promotion trigger also handles login before vectors arrive.
      insert into public.guest_sentence_embeddings(sentence_id, guest_user_id, guest_job_id, embedding, model,
        expression_purpose, purpose_embedding, learning_topic_ids, updated_at)
      values (sentence_uuid, job.user_id, job.guest_job_id, original_vector, 'qwen3.7-text-embedding', purpose, purpose_vector, topics, now())
      on conflict (sentence_id) do update set embedding = excluded.embedding,
        expression_purpose = excluded.expression_purpose, purpose_embedding = excluded.purpose_embedding,
        learning_topic_ids = coalesce(excluded.learning_topic_ids, guest_sentence_embeddings.learning_topic_ids),
        model = excluded.model, updated_at = excluded.updated_at;
    end if;
  end loop;
  -- Recovery can return the completed metadata without waiting for or invoking AI.
  if job.guest_job_id is not null and job.metadata is not null then
    update public.guest_generation_jobs guest set sentences = (
      select jsonb_agg(
        item.value || coalesce((
          select jsonb_build_object('learning_topic_ids', meta.value->'learning_topic_ids')
          from jsonb_array_elements(job.metadata) meta(value)
          where meta.value->>'sentence_id' = item.value->>'id'
        ), '{}'::jsonb) order by item.position
      )
      from jsonb_array_elements(guest.sentences) with ordinality item(value, position)
    )
    where guest.id = job.guest_job_id and guest.user_id = job.user_id;
  end if;
  update public.generation_enrichment_jobs set status = 'completed', completed_at = now(),
    sentences = '[]'::jsonb, metadata = null, lease_token = null, lease_until = null, last_error = null where id = job.id;
  return true;
end;
$$;

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
    sentence_id, user_id, embedding, model, expression_purpose, purpose_embedding, learning_topic_ids, updated_at
  )
  select staged.sentence_id, v_owner_id, staged.embedding, staged.model,
    staged.expression_purpose, staged.purpose_embedding, staged.learning_topic_ids, now()
  from public.guest_sentence_embeddings staged where staged.sentence_id = p_sentence_id
  on conflict (sentence_id) do update set
    user_id = excluded.user_id, embedding = excluded.embedding, model = excluded.model,
    expression_purpose = excluded.expression_purpose, purpose_embedding = excluded.purpose_embedding,
    learning_topic_ids = coalesce(excluded.learning_topic_ids, target.learning_topic_ids),
    updated_at = excluded.updated_at;
  get diagnostics v_count = row_count;
  if v_count = 0 then return false; end if;
  update public.memory_sentences sentence set learning_topic_ids = embedding.learning_topic_ids
  from public.sentence_embeddings embedding
  where sentence.id = p_sentence_id and embedding.sentence_id = sentence.id
    and embedding.user_id = v_owner_id and embedding.learning_topic_ids is not null
    and sentence.learning_topic_ids is distinct from embedding.learning_topic_ids;
  delete from public.guest_sentence_embeddings where sentence_id = p_sentence_id;
  perform public.refresh_semantic_study_scene_matches_for_sentence(p_sentence_id, v_owner_id);
  return true;
end;
$$;

revoke all on function public.promote_guest_sentence_embedding_for_id(uuid) from public, anon, authenticated;
grant execute on function public.promote_guest_sentence_embedding_for_id(uuid) to service_role;

-- Do not run semantic matching on foreground inserts with no vectors yet.
create or replace function public.match_sentence_to_semantic_study_scenes()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
declare v_user_id uuid;
begin
  select user_id into v_user_id from public.memories where id = new.memory_id;
  if exists (select 1 from public.sentence_embeddings e where e.sentence_id = new.id and e.user_id = v_user_id) then
    perform public.refresh_semantic_study_scene_matches_for_sentence(new.id, v_user_id);
  end if;
  return new;
end;
$$;
revoke all on function public.match_sentence_to_semantic_study_scenes() from public, anon, authenticated;
notify pgrst, 'reload schema';
