-- Keep semantic scene refreshes safe for historical scenes created before an
-- embedding was available. They remain empty until they are recreated or
-- otherwise receive an embedding, instead of breaking unrelated migrations.
create or replace function public.refresh_semantic_study_scene_matches_for_owner(
  p_scene_id uuid,
  p_user_id uuid,
  p_threshold double precision default 0.42
)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_embedding real[];
  v_count integer := 0;
begin
  select embedding into v_embedding
  from public.study_scene_embeddings
  where scene_id = p_scene_id
    and user_id = p_user_id;

  if v_embedding is null then
    return 0;
  end if;

  delete from public.study_scene_sentences where scene_id = p_scene_id;

  insert into public.study_scene_sentences (scene_id, sentence_id, match_score, match_source)
  select p_scene_id, matches.sentence_id,
         least(100, greatest(1, round(matches.similarity * 100)::integer)),
         'semantic'
  from (
    select embedding.sentence_id,
           public.cosine_similarity_real_arrays(v_embedding, embedding.embedding) as similarity
    from public.sentence_embeddings as embedding
    join public.memory_sentences as sentence on sentence.id = embedding.sentence_id
    join public.memories as memory on memory.id = sentence.memory_id
    where embedding.user_id = p_user_id
      and memory.user_id = p_user_id
  ) as matches
  where matches.similarity >= p_threshold;

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

revoke all on function public.refresh_semantic_study_scene_matches_for_owner(uuid, uuid, double precision) from public, anon, authenticated;
