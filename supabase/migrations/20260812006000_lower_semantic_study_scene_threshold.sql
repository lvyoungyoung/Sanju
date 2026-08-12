-- A scene name is often broader than an individual sentence. Lower the
-- semantic threshold so meaningful scene hints can surface related sentences
-- without requiring nearly identical wording.
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
    raise exception 'Study scene embedding not found';
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

create or replace function public.refresh_semantic_study_scene_matches_for_sentence(
  p_sentence_id uuid,
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
  from public.sentence_embeddings
  where sentence_id = p_sentence_id
    and user_id = p_user_id;

  if v_embedding is null then
    return 0;
  end if;

  delete from public.study_scene_sentences as link
  using public.study_scenes as scene
  where link.scene_id = scene.id
    and scene.user_id = p_user_id
    and link.sentence_id = p_sentence_id;

  insert into public.study_scene_sentences (scene_id, sentence_id, match_score, match_source)
  select scene.id, p_sentence_id,
         least(100, greatest(1, round(public.cosine_similarity_real_arrays(scene_embedding.embedding, v_embedding) * 100)::integer)),
         'semantic'
  from public.study_scenes as scene
  join public.study_scene_embeddings as scene_embedding on scene_embedding.scene_id = scene.id
  where scene.user_id = p_user_id
    and scene_embedding.user_id = p_user_id
    and public.cosine_similarity_real_arrays(scene_embedding.embedding, v_embedding) >= p_threshold;

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

-- Apply the lower threshold to existing user scenes immediately.
do $$
declare
  scene_record record;
begin
  for scene_record in select id, user_id from public.study_scenes
  loop
    perform public.refresh_semantic_study_scene_matches_for_owner(
      scene_record.id,
      scene_record.user_id
    );
  end loop;
end;
$$;

revoke all on function public.refresh_semantic_study_scene_matches_for_owner(uuid, uuid, double precision) from public, anon, authenticated;
revoke all on function public.refresh_semantic_study_scene_matches_for_sentence(uuid, uuid, double precision) from public, anon, authenticated;
grant execute on function public.refresh_semantic_study_scene_matches_for_sentence(uuid, uuid, double precision) to service_role;
