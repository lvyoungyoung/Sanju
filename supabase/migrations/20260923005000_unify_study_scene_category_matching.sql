-- Recommended and manually named themes now share the same matching rule.
-- Existing themes are prepared on first opening; IDs and study history survive.
alter table public.study_scenes add column if not exists match_rule_version integer not null default 0;

create or replace function public.study_scene_similarity_scores(
  p_scene_id uuid, p_user_id uuid, p_sentence_id uuid default null
)
returns table(sentence_id uuid, sentence_similarity double precision, purpose_similarity double precision,
  category_similarity double precision, category_topic_id text, threshold double precision)
language sql stable security definer set search_path = public, pg_temp as $$
  with query as materialized (
    select vector.embedding, vector.model, scene.match_threshold
    from public.study_scenes scene
    join public.study_scene_embeddings vector on vector.scene_id = scene.id and vector.user_id = p_user_id
    where scene.id = p_scene_id and scene.user_id = p_user_id
  ), categories as materialized (
    select category.topic_id,
      public.cosine_similarity_real_arrays(query.embedding, category.embedding) as similarity
    from query join public.learning_topic_embeddings category
      on category.model = query.model and category.catalog_version = 'photo-life-v1'
  )
  select sentence.id,
    public.cosine_similarity_real_arrays(query.embedding, embedding.embedding),
    case when nullif(btrim(embedding.expression_purpose), '') is not null then
      public.cosine_similarity_real_arrays(query.embedding, embedding.purpose_embedding) end,
    category.similarity, category.topic_id, query.match_threshold
  from query
  join public.memories memory on memory.user_id = p_user_id
  join public.memory_sentences sentence on sentence.memory_id = memory.id
  left join public.sentence_embeddings embedding on embedding.sentence_id = sentence.id
    and embedding.user_id = p_user_id and embedding.model = query.model
  left join lateral (
    select * from categories where topic_id = any(sentence.learning_topic_ids)
      and similarity between -1.000001 and 1.000001
    order by similarity desc, topic_id limit 1
  ) category on true
  where p_sentence_id is null or sentence.id = p_sentence_id;
$$;

create or replace function public.semantic_study_scene_candidates(
  p_scene_id uuid, p_user_id uuid, p_sentence_id uuid default null,
  p_threshold double precision default null
)
returns table (sentence_id uuid, match_score integer, match_source text)
language sql stable security definer set search_path = public, pg_temp as $$
  with eligible as (
    select *,
      coalesce(sentence_similarity between greatest(0.36, coalesce(p_threshold, threshold)) and 1.000001, false) as original_match,
      coalesce(category_similarity between greatest(0.36, coalesce(p_threshold, threshold)) and 1.000001, false) as category_match
    from public.study_scene_similarity_scores(p_scene_id, p_user_id, p_sentence_id)
    where purpose_similarity between greatest(0.36, coalesce(p_threshold, threshold)) and 1.000001
  )
  select sentence_id,
    least(100, greatest(1, round(greatest(purpose_similarity,
      case when original_match then sentence_similarity end,
      case when category_match then category_similarity end) * 100)::integer)),
    case when original_match and category_match then 'semantic_all'
      when original_match then 'semantic_both' else 'purpose_category' end
  from eligible where original_match or category_match;
$$;

create or replace function public.refresh_semantic_study_scene_matches_for_owner(
  p_scene_id uuid, p_user_id uuid, p_threshold double precision default null
)
returns integer language plpgsql security definer set search_path = public, pg_temp as $$
declare v_count integer;
begin
  perform 1 from public.study_scenes scene
  join public.study_scene_embeddings embedding on embedding.scene_id = scene.id
  where scene.id = p_scene_id and scene.user_id = p_user_id
    and embedding.user_id = p_user_id
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
  update public.study_scenes set match_rule_version = case when (
    select count(*) from public.learning_topic_embeddings category
    join public.study_scene_embeddings query on query.scene_id = p_scene_id
      and query.user_id = p_user_id and query.model = category.model
    where category.catalog_version = 'photo-life-v1'
  ) = 21 then 1 else 0 end where id = p_scene_id;
  return v_count;
end;
$$;

create or replace function public.refresh_semantic_study_scene_matches_for_sentence(
  p_sentence_id uuid, p_user_id uuid, p_threshold double precision default null
)
returns integer language plpgsql security definer set search_path = public, pg_temp as $$
declare v_scene record; v_match record; v_count integer := 0;
begin
  -- Each custom theme applies its persisted threshold to both vectors.
  perform 1 from public.memory_sentences sentence
  join public.memories memory on memory.id = sentence.memory_id
  where sentence.id = p_sentence_id and memory.user_id = p_user_id;
  if not found then return 0; end if;
  for v_scene in
    select scene.id from public.study_scenes scene
    join public.study_scene_embeddings embedding on embedding.scene_id = scene.id
    where scene.user_id = p_user_id and embedding.user_id = p_user_id
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

  insert into public.study_scene_embeddings (scene_id, user_id, embedding, model, match_scope, search_description)
  values (v_scene_id, p_user_id, v_embedding, coalesce(nullif(btrim(p_model), ''), 'qwen3.7-text-embedding'), p_match_scope, p_search_description)
  on conflict (scene_id) do update set
    embedding = excluded.embedding, model = excluded.model,
    match_scope = excluded.match_scope, search_description = excluded.search_description, updated_at = now();
  perform public.refresh_semantic_study_scene_matches_for_owner(v_scene_id, p_user_id);
  return query select * from public.get_study_scene_summary_for_owner(p_user_id, v_scene_id);
end;
$$;

-- Prevent the old exact-category trigger from bypassing purpose matching.
drop trigger if exists match_sentence_to_learning_topic_study_scenes_trigger on public.memory_sentences;
create or replace function public.refresh_learning_topic_study_scene_matches_for_owner(p_scene_id uuid, p_user_id uuid)
returns integer language sql security definer set search_path = public, pg_temp as $$
  select public.refresh_semantic_study_scene_matches_for_owner(p_scene_id, p_user_id);
$$;

create or replace function public.refresh_study_scene_after_threshold_change()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if new.match_threshold is not distinct from old.match_threshold then return new; end if;
  if not exists (select 1 from public.study_scene_embeddings
    where scene_id = new.id and user_id = new.user_id) then
    raise exception 'Study scene embedding not found';
  end if;
  perform public.refresh_semantic_study_scene_matches_for_owner(new.id, new.user_id);
  return new;
end;
$$;

create or replace function public.get_study_scene_match_settings(p_scene_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_scene public.study_scenes%rowtype;
begin
  select * into v_scene from public.study_scenes where id = p_scene_id and user_id = auth.uid();
  if not found then raise exception 'Study scene not found' using errcode = '42501'; end if;
  return jsonb_build_object(
    'scene_id', v_scene.id, 'threshold', v_scene.match_threshold,
    'can_adjust', true,
    'needs_preparation', v_scene.match_rule_version < 1
      or not exists(select 1 from public.study_scene_embeddings where scene_id = v_scene.id and user_id = v_scene.user_id)
      or (select count(*) from public.learning_topic_embeddings category
          join public.study_scene_embeddings query on query.scene_id = v_scene.id
            and query.user_id = v_scene.user_id and query.model = category.model
          where category.catalog_version = 'photo-life-v1') <> 21,
    'matched_count', (select count(*) from public.study_scene_sentences link
      join public.memory_sentences sentence on sentence.id = link.sentence_id
      join public.memories memory on memory.id = sentence.memory_id and memory.user_id = v_scene.user_id
      where link.scene_id = v_scene.id)
  );
end;
$$;

create or replace function public.set_study_scene_match_settings(
  p_scene_id uuid, p_threshold double precision
)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_scene public.study_scenes%rowtype;
begin
  select * into v_scene from public.study_scenes
  where id = p_scene_id and user_id = auth.uid() for update;
  if not found then raise exception 'Study scene not found' using errcode = '42501'; end if;
  if p_threshold is null or p_threshold not in (0.36, 0.38, 0.40, 0.42, 0.44, 0.46, 0.48) then
    raise exception 'Invalid match threshold' using errcode = '22023';
  end if;
  update public.study_scenes set match_threshold = p_threshold, updated_at = now()
  where id = v_scene.id;
  return public.get_study_scene_match_settings(v_scene.id);
end;
$$;

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

  with similarities as materialized (
    select * from public.study_scene_similarity_scores(p_scene_id, v_owner)
  ), candidates as materialized (
    select * from public.semantic_study_scene_candidates(p_scene_id, v_owner)
  ), scores as (
    select sentence.id as sentence_id, sentence.english,
      embedding.expression_purpose, similarity.category_similarity, similarity.category_topic_id,
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
    left join similarities similarity on similarity.sentence_id = sentence.id
  ), limited as (
    select * from scores
    order by included desc, greatest(sentence_similarity, purpose_similarity, category_similarity) desc nulls last, sentence_id
    limit least(100, greatest(1, coalesce(p_limit, 100)))
  )
  select jsonb_build_object(
    'scene_id', p_scene_id, 'name', v_scene.name,
    'learning_topic_id', v_scene.learning_topic_id,
    'threshold', v_scene.match_threshold, 'rule', 'purpose_and_sentence_or_category_v1',
    'query_model', (select model from public.study_scene_embeddings where scene_id = p_scene_id and user_id = v_owner),
    'legacy_search_description', (select search_description from public.study_scene_embeddings where scene_id = p_scene_id and user_id = v_owner),
    'total_sentences', (select count(*) from scores),
    'included_count', (select count(*) from scores where included),
    'rows', coalesce((select jsonb_agg(to_jsonb(limited)
      order by included desc, greatest(sentence_similarity, purpose_similarity, category_similarity) desc nulls last, sentence_id)
      from limited), '[]'::jsonb)
  ) into v_result;
  return v_result;
end;
$$;

-- Preparation only updates an existing owned scene, so a concurrent deletion
-- cannot cause a name-based upsert to resurrect it.
create or replace function public.prepare_study_scene_matching(
  p_user_id uuid, p_scene_id uuid, p_embedding jsonb, p_model text
)
returns table (
  id uuid, name text, cover_memory_id uuid, total_count integer,
  due_count integer, studied_count integer, reviewable_today_count integer, mastery_score integer
)
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_scene public.study_scenes%rowtype; v_vector real[];
begin
  select * into v_scene from public.study_scenes where study_scenes.id = p_scene_id
    and user_id = p_user_id for update;
  if not found then raise exception 'Study scene not found'; end if;
  if p_embedding is not null then
    v_vector := public.jsonb_to_embedding_real_array(p_embedding);
    if v_vector is null or cardinality(v_vector) <> 1024
      or array_position(v_vector, null) is not null
      or v_vector && array['NaN'::real, 'Infinity'::real, '-Infinity'::real]
      or v_vector = array_fill(0::real, array[1024]) then raise exception 'Invalid study scene embedding'; end if;
    insert into public.study_scene_embeddings(scene_id,user_id,embedding,model)
    values(p_scene_id,p_user_id,v_vector,p_model)
    on conflict(scene_id) do update set embedding=excluded.embedding,model=excluded.model,
      search_description=null,match_scope='specific',updated_at=now();
  end if;
  if not exists(select 1 from public.study_scene_embeddings where scene_id=p_scene_id and user_id=p_user_id) then
    raise exception 'Study scene embedding not found';
  end if;
  perform public.refresh_semantic_study_scene_matches_for_owner(p_scene_id,p_user_id);
  return query select * from public.get_study_scene_summary_for_owner(p_user_id,p_scene_id);
end;
$$;

revoke all on function public.study_scene_similarity_scores(uuid,uuid,uuid) from public, anon, authenticated;
revoke all on function public.prepare_study_scene_matching(uuid,uuid,jsonb,text) from public, anon, authenticated;
grant execute on function public.study_scene_similarity_scores(uuid,uuid,uuid) to service_role;
grant execute on function public.prepare_study_scene_matching(uuid,uuid,jsonb,text) to service_role;

notify pgrst, 'reload schema';
