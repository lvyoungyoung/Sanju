-- Shared document vectors, not account data. Only the service role may access them.
create table if not exists public.learning_topic_embeddings (
  topic_id text not null check (topic_id = any(array[
    'self_and_style','family_time','children_growing_up','friends_gatherings',
    'romance_and_companionship','pet_life','food_and_drinks','cooking','home_life',
    'city_life','natural_scenery','plants_and_wildlife','travel','transport',
    'sports_and_outdoors','festivals_and_celebrations','arts_and_entertainment',
    'school_and_study','work_life','shopping','health_and_wellness'
  ]::text[])),
  model text not null,
  catalog_version text not null,
  embedding real[] not null check (
    cardinality(embedding) = 1024 and array_ndims(embedding) = 1
    and array_position(embedding, null) is null
    and not (embedding && array['NaN'::real, 'Infinity'::real, '-Infinity'::real])
    and embedding <> array_fill(0::real, array[1024])
  ),
  created_at timestamptz not null default now(),
  primary key (topic_id, model, catalog_version)
);
alter table public.learning_topic_embeddings enable row level security;
revoke all on public.learning_topic_embeddings from public, anon, authenticated;
grant select, insert, update on public.learning_topic_embeddings to service_role;

-- Old themes stay sentence-only until their intent is explicitly resolved again.
alter table public.study_scene_embeddings
  add column if not exists match_scope text not null default 'specific'
    check (match_scope in ('broad', 'specific')),
  add column if not exists search_description text;

-- One scoring rule for creation, full refresh and newly indexed sentences.
create or replace function public.semantic_study_scene_candidates(
  p_scene_id uuid, p_user_id uuid, p_sentence_id uuid default null,
  p_threshold double precision default 0.42
)
returns table (sentence_id uuid, match_score integer, match_source text)
language sql stable security definer set search_path = public, pg_temp as $$
  with scene_vector as materialized (
    select embedding.* from public.study_scene_embeddings embedding
    join public.study_scenes scene on scene.id = embedding.scene_id
    where scene.id = p_scene_id and scene.user_id = p_user_id
      and embedding.user_id = p_user_id and scene.learning_topic_id is null
  ), category_scores as materialized (
    select category.topic_id,
      public.cosine_similarity_real_arrays(scene.embedding, category.embedding) as similarity
    from scene_vector scene
    join public.learning_topic_embeddings category on category.model = scene.model
      and category.catalog_version = 'photo-life-v1'
  ), top_categories as materialized (
    -- Initial conservative category threshold; keep at most two near-best categories.
    select * from category_scores
    where similarity between 0.55 and 1.000001
      and similarity >= (select max(similarity) from category_scores) - 0.08
    order by similarity desc, topic_id limit 2
  ), scores as (
    select sentence.id, scene.match_scope,
      public.cosine_similarity_real_arrays(scene.embedding, embedding.embedding) as sentence_similarity,
      (select max(category.similarity) from top_categories category
       where category.topic_id = any(sentence.learning_topic_ids)) as category_similarity
    from scene_vector scene
    join public.memories memory on memory.user_id = p_user_id
    join public.memory_sentences sentence on sentence.memory_id = memory.id
    left join public.sentence_embeddings embedding on embedding.sentence_id = sentence.id
      and embedding.user_id = p_user_id and embedding.model = scene.model
    where p_sentence_id is null or sentence.id = p_sentence_id
  ), eligible as (
    select *, coalesce(sentence_similarity between greatest(0.42, coalesce(p_threshold, 0.42)) and 1.000001, false) as sentence_match
    from scores
  )
  select id,
    least(100, greatest(1, round((case when sentence_match then
      sentence_similarity + 0.03 * coalesce(category_similarity, 0)
      else category_similarity end) * 100)::integer)),
    case when sentence_match then 'semantic' else 'category_semantic' end
  from eligible
  where sentence_match or (match_scope = 'broad' and category_similarity is not null);
$$;

create or replace function public.refresh_semantic_study_scene_matches_for_owner(
  p_scene_id uuid, p_user_id uuid, p_threshold double precision default 0.42
)
returns integer language plpgsql security definer set search_path = public, pg_temp as $$
declare v_count integer;
begin
  perform 1 from public.study_scenes scene
  join public.study_scene_embeddings embedding on embedding.scene_id = scene.id
  where scene.id = p_scene_id and scene.user_id = p_user_id
    and embedding.user_id = p_user_id and scene.learning_topic_id is null
  for update of scene;
  if not found then return 0; end if;

  with matches as materialized (
    select * from public.semantic_study_scene_candidates(p_scene_id, p_user_id, null, p_threshold)
  ), removed as (
    delete from public.study_scene_sentences link where link.scene_id = p_scene_id
      and not exists (select 1 from matches where matches.sentence_id = link.sentence_id)
  )
  insert into public.study_scene_sentences (scene_id, sentence_id, match_score, match_source)
  select p_scene_id, matches.sentence_id, matches.match_score, matches.match_source from matches
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
declare v_scene record; v_match record; v_count integer := 0;
begin
  -- Missing sentence vectors are allowed only through a broad theme's category route.
  perform 1 from public.memory_sentences sentence
  join public.memories memory on memory.id = sentence.memory_id
  where sentence.id = p_sentence_id and memory.user_id = p_user_id;
  if not found then return 0; end if;
  for v_scene in
    select scene.id from public.study_scenes scene
    join public.study_scene_embeddings embedding on embedding.scene_id = scene.id
    where scene.user_id = p_user_id and embedding.user_id = p_user_id and scene.learning_topic_id is null
    order by scene.id for update of scene
  loop
    select * into v_match from public.semantic_study_scene_candidates(v_scene.id, p_user_id, p_sentence_id, p_threshold);
    if found then
      insert into public.study_scene_sentences (scene_id, sentence_id, match_score, match_source)
      values (v_scene.id, p_sentence_id, v_match.match_score, v_match.match_source)
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

create or replace function public.create_study_scene_with_matching_context(
  p_user_id uuid, p_name text, p_embedding jsonb, p_model text,
  p_search_description text, p_match_scope text
)
returns table (
  id uuid, name text, cover_memory_id uuid, total_count integer,
  due_count integer, studied_count integer, reviewable_today_count integer, mastery_score integer
)
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_name text := btrim(coalesce(p_name, ''));
  v_scene_id uuid;
  v_embedding real[] := public.jsonb_to_embedding_real_array(p_embedding);
begin
  if char_length(v_name) < 2 or char_length(v_name) > 24 then
    raise exception 'Study scene name must be between 2 and 24 characters';
  end if;
  if v_embedding is null or cardinality(v_embedding) <> 1024
    or array_position(v_embedding, null) is not null
    or v_embedding && array['NaN'::real, 'Infinity'::real, '-Infinity'::real]
    or v_embedding = array_fill(0::real, array[1024]) then
    raise exception 'Invalid study scene embedding';
  end if;
  if p_match_scope is null or p_match_scope not in ('broad', 'specific') then
    raise exception 'Invalid study scene match scope';
  end if;
  if p_match_scope = 'broad' and nullif(btrim(p_search_description), '') is null then
    raise exception 'Broad scene requires resolved intent';
  end if;
  if char_length(p_search_description) > 240 then raise exception 'Invalid search description'; end if;

  insert into public.study_scenes as scene (user_id, name)
  values (p_user_id, v_name)
  on conflict on constraint study_scenes_user_id_name_key do update set updated_at = now()
  returning scene.id into v_scene_id;

  -- A custom-name request must not convert an existing exact-category theme.
  if exists (select 1 from public.study_scenes scene where scene.id = v_scene_id and scene.learning_topic_id is not null) then
    return query select * from public.get_study_scene_summary_for_owner(p_user_id, v_scene_id);
    return;
  end if;
  insert into public.study_scene_embeddings (scene_id, user_id, embedding, model, match_scope, search_description)
  values (v_scene_id, p_user_id, v_embedding, coalesce(nullif(btrim(p_model), ''), 'qwen3.7-text-embedding'), p_match_scope, p_search_description)
  on conflict (scene_id) do update set
    embedding = excluded.embedding, model = excluded.model,
    match_scope = excluded.match_scope, search_description = excluded.search_description, updated_at = now();
  perform public.refresh_semantic_study_scene_matches_for_owner(v_scene_id, p_user_id);
  return query select * from public.get_study_scene_summary_for_owner(p_user_id, v_scene_id);
end;
$$;

-- Keep the old RPC's argument and response shape, defaulting to sentence-only admission.
create or replace function public.create_study_scene_with_embedding(
  p_user_id uuid, p_name text, p_embedding jsonb, p_model text default 'qwen3.7-text-embedding'
)
returns table (
  id uuid, name text, cover_memory_id uuid, total_count integer,
  due_count integer, studied_count integer, reviewable_today_count integer, mastery_score integer
)
language sql security definer set search_path = public, pg_temp as $$
  select * from public.create_study_scene_with_matching_context(p_user_id, p_name, p_embedding, p_model, null, 'specific');
$$;

-- Category changes/new sentences must not wait for their individual embedding.
create or replace function public.match_sentence_to_semantic_study_scenes()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
declare v_user_id uuid;
begin
  select user_id into v_user_id from public.memories where id = new.memory_id;
  perform public.refresh_semantic_study_scene_matches_for_sentence(new.id, v_user_id);
  return new;
end;
$$;
drop trigger if exists match_sentence_to_semantic_study_scenes on public.memory_sentences;
create trigger match_sentence_to_semantic_study_scenes
after insert or update of learning_topic_ids on public.memory_sentences
for each row execute function public.match_sentence_to_semantic_study_scenes();

revoke all on function public.semantic_study_scene_candidates(uuid, uuid, uuid, double precision) from public, anon, authenticated;
revoke all on function public.create_study_scene_with_matching_context(uuid, text, jsonb, text, text, text) from public, anon, authenticated;
revoke all on function public.match_sentence_to_semantic_study_scenes() from public, anon, authenticated;
grant execute on function public.semantic_study_scene_candidates(uuid, uuid, uuid, double precision) to service_role;
grant execute on function public.create_study_scene_with_matching_context(uuid, text, jsonb, text, text, text) to service_role;

notify pgrst, 'reload schema';
