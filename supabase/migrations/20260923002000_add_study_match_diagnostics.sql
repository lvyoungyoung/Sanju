-- Read-only diagnostics for the signed-in owner's topic. No vectors are exposed.
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
    'threshold', 0.42, 'rule', 'sentence_or_purpose_v1',
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

revoke all on function public.get_study_scene_match_diagnostics(uuid, integer) from public, anon;
grant execute on function public.get_study_scene_match_diagnostics(uuid, integer) to authenticated;
notify pgrst, 'reload schema';
