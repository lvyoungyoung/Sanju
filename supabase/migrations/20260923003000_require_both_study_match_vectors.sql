-- Keep the threshold and ranking unchanged; admission now requires both routes.
create or replace function public.semantic_study_scene_candidates(
  p_scene_id uuid, p_user_id uuid, p_sentence_id uuid default null,
  p_threshold double precision default 0.42
)
returns table (sentence_id uuid, match_score integer, match_source text)
language sql stable security definer set search_path = public, pg_temp as $$
  with scores as (
    select sentence.id,
      public.cosine_similarity_real_arrays(scene_vector.embedding, embedding.embedding) as sentence_similarity,
      case when nullif(btrim(embedding.expression_purpose), '') is not null then
        public.cosine_similarity_real_arrays(scene_vector.embedding, embedding.purpose_embedding)
      end as purpose_similarity
    from public.study_scenes scene
    join public.study_scene_embeddings scene_vector on scene_vector.scene_id = scene.id
      and scene_vector.user_id = p_user_id
    join public.sentence_embeddings embedding on embedding.user_id = p_user_id
      and embedding.model = scene_vector.model
    join public.memory_sentences sentence on sentence.id = embedding.sentence_id
    join public.memories memory on memory.id = sentence.memory_id and memory.user_id = p_user_id
    where scene.id = p_scene_id and scene.user_id = p_user_id and scene.learning_topic_id is null
      and (p_sentence_id is null or sentence.id = p_sentence_id)
  )
  select id, least(100, greatest(1, round(greatest(sentence_similarity, purpose_similarity) * 100)::integer)),
    'semantic_both'::text
  from scores
  where sentence_similarity between greatest(0.42, coalesce(p_threshold, 0.42)) and 1.000001
    and purpose_similarity between greatest(0.42, coalesce(p_threshold, 0.42)) and 1.000001;
$$;

-- Same read-only diagnostic contract, with the updated rule label.
create or replace function public.get_study_scene_match_diagnostics(
  p_scene_id uuid, p_limit integer default 100
)
returns jsonb language plpgsql stable security definer
set search_path = public, pg_temp as $$
declare
  v_owner uuid := auth.uid();
  v_scene public.study_scenes%rowtype;
  v_result jsonb;
begin
  select * into v_scene from public.study_scenes
  where id = p_scene_id and user_id = v_owner;
  if not found then
    raise exception 'Study scene not found' using errcode = '42501';
  end if;

  with candidates as materialized (
    select * from public.semantic_study_scene_candidates(p_scene_id, v_owner)
  ), scores as (
    select sentence.id as sentence_id, sentence.english,
      embedding.expression_purpose,
      embedding.model as sentence_model,
      embedding.embedding is not null as has_sentence_vector,
      embedding.purpose_embedding is not null as has_purpose_vector,
      case when embedding.model = query.model then
        public.cosine_similarity_real_arrays(query.embedding, embedding.embedding)
      end as sentence_similarity,
      case when embedding.model = query.model
        and nullif(btrim(embedding.expression_purpose), '') is not null then
        public.cosine_similarity_real_arrays(query.embedding, embedding.purpose_embedding)
      end as purpose_similarity,
      link.sentence_id is not null as included,
      link.match_source as stored_source, link.match_score as stored_score,
      candidate.match_source as current_source
    from public.memory_sentences sentence
    join public.memories memory on memory.id = sentence.memory_id and memory.user_id = v_owner
    left join public.sentence_embeddings embedding on embedding.sentence_id = sentence.id
      and embedding.user_id = v_owner
    left join public.study_scene_embeddings query on query.scene_id = p_scene_id and query.user_id = v_owner
    left join public.study_scene_sentences link on link.scene_id = p_scene_id and link.sentence_id = sentence.id
    left join candidates candidate on candidate.sentence_id = sentence.id
  ), limited as (
    select * from scores
    order by included desc, greatest(sentence_similarity, purpose_similarity) desc nulls last, sentence_id
    limit least(100, greatest(1, coalesce(p_limit, 100)))
  )
  select jsonb_build_object(
    'scene_id', p_scene_id, 'name', v_scene.name,
    'learning_topic_id', v_scene.learning_topic_id,
    'threshold', 0.42, 'rule', 'sentence_and_purpose_v1',
    'query_model', (select model from public.study_scene_embeddings where scene_id = p_scene_id and user_id = v_owner),
    'legacy_search_description', (select search_description from public.study_scene_embeddings where scene_id = p_scene_id and user_id = v_owner),
    'total_sentences', (select count(*) from scores),
    'included_count', (select count(*) from scores where included),
    'rows', coalesce((select jsonb_agg(to_jsonb(limited)
      order by included desc, greatest(sentence_similarity, purpose_similarity) desc nulls last, sentence_id)
      from limited), '[]'::jsonb)
  ) into v_result;
  return v_result;
end;
$$;

-- Reconcile existing custom themes without touching favorites or study progress.
do $$
declare v_scene record;
begin
  for v_scene in
    select scene.id, scene.user_id from public.study_scenes scene
    join public.study_scene_embeddings embedding on embedding.scene_id = scene.id and embedding.user_id = scene.user_id
    where scene.learning_topic_id is null order by scene.id
  loop
    perform public.refresh_semantic_study_scene_matches_for_owner(v_scene.id, v_scene.user_id);
  end loop;
end;
$$;

notify pgrst, 'reload schema';
