-- Temporarily use semantic matching alone. Keep review history and old RPC
-- contracts, but stop workers (including old clients) from changing links.
create or replace function public.claim_study_scene_sentence_reviews(p_user_id uuid, p_scene_id uuid default null)
returns table (scene_id uuid, sentence_id uuid, topic text, english text, chinese text, input_hash text, lease_token uuid)
language sql security definer set search_path = public, pg_temp as $$
  select null::uuid, null::uuid, null::text, null::text, null::text, null::text, null::uuid where false;
$$;

create or replace function public.complete_study_scene_sentence_reviews(p_user_id uuid, p_decisions jsonb)
returns integer language sql security definer set search_path = public, pg_temp as $$
  select 0;
$$;

create or replace function public.defer_study_scene_sentence_reviews(p_user_id uuid, p_claims jsonb)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
begin
  return;
end;
$$;

create or replace function public.get_study_scene_review_status(p_user_id uuid, p_scene_id uuid default null)
returns table (pending_count integer, retry_after_seconds integer)
language sql security definer set search_path = public, pg_temp as $$
  select 0, 0;
$$;

create or replace function public.refresh_semantic_study_scene_matches_for_owner(
  p_scene_id uuid, p_user_id uuid, p_threshold double precision default 0.42
)
returns integer language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_scene record;
  v_count integer;
begin
  select embedding.embedding, embedding.model into v_scene
  from public.study_scenes scene
  join public.study_scene_embeddings embedding on embedding.scene_id = scene.id
  where scene.id = p_scene_id and scene.user_id = p_user_id
    and embedding.user_id = p_user_id and scene.learning_topic_id is null
  for update of scene;
  if not found then return 0; end if;

  with scores as materialized (
    select sentence.id,
      public.cosine_similarity_real_arrays(v_scene.embedding, embedding.embedding) as similarity
    from public.sentence_embeddings embedding
    join public.memory_sentences sentence on sentence.id = embedding.sentence_id
    join public.memories memory on memory.id = sentence.memory_id
    where embedding.user_id = p_user_id and memory.user_id = p_user_id
      and embedding.model = v_scene.model
  ), matches as materialized (
    select * from scores
    where similarity between greatest(0.42, coalesce(p_threshold, 0.42)) and 1
  ), removed as (
    delete from public.study_scene_sentences link where link.scene_id = p_scene_id
      and not exists (select 1 from matches where matches.id = link.sentence_id)
  )
  insert into public.study_scene_sentences (scene_id, sentence_id, match_score, match_source)
  select p_scene_id, matches.id,
    least(100, greatest(1, round(matches.similarity * 100)::integer)), 'semantic'
  from matches
  on conflict (scene_id, sentence_id) do update
    set match_score = excluded.match_score, match_source = excluded.match_source;

  select count(*)::integer into v_count from public.study_scene_sentences where scene_id = p_scene_id;
  return v_count;
end;
$$;

create or replace function public.refresh_semantic_study_scene_matches_for_sentence(
  p_sentence_id uuid, p_user_id uuid, p_threshold double precision default 0.42
)
returns integer language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_sentence record;
  v_scene record;
  v_similarity double precision;
  v_count integer := 0;
begin
  select embedding.embedding, embedding.model into v_sentence
  from public.sentence_embeddings embedding
  join public.memory_sentences sentence on sentence.id = embedding.sentence_id
  join public.memories memory on memory.id = sentence.memory_id
  where sentence.id = p_sentence_id and embedding.user_id = p_user_id and memory.user_id = p_user_id;
  if not found then return 0; end if;

  for v_scene in
    select scene.id, embedding.embedding, embedding.model
    from public.study_scenes scene
    join public.study_scene_embeddings embedding on embedding.scene_id = scene.id
    where scene.user_id = p_user_id and embedding.user_id = p_user_id and scene.learning_topic_id is null
    order by scene.id for update of scene
  loop
    v_similarity := case when v_scene.model = v_sentence.model then
      public.cosine_similarity_real_arrays(v_scene.embedding, v_sentence.embedding) else null end;
    if coalesce(v_similarity between greatest(0.42, coalesce(p_threshold, 0.42)) and 1, false) then
      insert into public.study_scene_sentences (scene_id, sentence_id, match_score, match_source)
      values (v_scene.id, p_sentence_id,
        least(100, greatest(1, round(v_similarity * 100)::integer)), 'semantic')
      on conflict (scene_id, sentence_id) do update
        set match_score = excluded.match_score, match_source = excluded.match_source;
      v_count := v_count + 1;
    else
      delete from public.study_scene_sentences where scene_id = v_scene.id and sentence_id = p_sentence_id;
    end if;
  end loop;
  return v_count;
end;
$$;

-- Rebuild existing custom themes with the same rule as newly created themes.
-- Do not touch classification-based themes, sentence content, favorites or SRS.
do $$
declare
  v_scene record;
begin
  for v_scene in
    select scene.id, scene.user_id
    from public.study_scenes scene
    join public.study_scene_embeddings embedding on embedding.scene_id = scene.id
      and embedding.user_id = scene.user_id
    where scene.learning_topic_id is null
    order by scene.id
  loop
    perform public.refresh_semantic_study_scene_matches_for_owner(v_scene.id, v_scene.user_id);
  end loop;
end;
$$;

update public.study_scene_sentence_reviews set lease_token = null, lease_until = null
where lease_token is not null or lease_until is not null;

-- CREATE OR REPLACE retains the existing service-role-only grants.
