-- New scenes use the default. Existing choices survive name upserts and refreshes.
alter table public.study_scenes
  add column if not exists match_threshold double precision not null default 0.42
  check (match_threshold in (0.36, 0.38, 0.40, 0.42, 0.44, 0.46, 0.48));

create or replace function public.semantic_study_scene_candidates(
  p_scene_id uuid, p_user_id uuid, p_sentence_id uuid default null,
  p_threshold double precision default null
)
returns table (sentence_id uuid, match_score integer, match_source text)
language sql stable security definer set search_path = public, pg_temp as $$
  with scores as (
    select sentence.id, coalesce(p_threshold, scene.match_threshold) as threshold,
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
  where sentence_similarity between greatest(0.36, threshold) and 1.000001
    and purpose_similarity between greatest(0.36, threshold) and 1.000001;
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
    'threshold', v_scene.match_threshold, 'rule', 'sentence_and_purpose_v1',
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

create or replace function public.get_study_scene_match_settings(p_scene_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_scene public.study_scenes%rowtype;
begin
  select * into v_scene from public.study_scenes where id = p_scene_id and user_id = auth.uid();
  if not found then raise exception 'Study scene not found' using errcode = '42501'; end if;
  return jsonb_build_object(
    'scene_id', v_scene.id, 'threshold', v_scene.match_threshold,
    'can_adjust', v_scene.learning_topic_id is null,
    'matched_count', (select count(*) from public.study_scene_sentences link
      join public.memory_sentences sentence on sentence.id = link.sentence_id
      join public.memories memory on memory.id = sentence.memory_id and memory.user_id = v_scene.user_id
      where link.scene_id = v_scene.id)
  );
end;
$$;

-- A direct owner-authorized table update must be just as atomic as the RPC.
create or replace function public.refresh_study_scene_after_threshold_change()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if new.match_threshold is not distinct from old.match_threshold then return new; end if;
  if new.learning_topic_id is not null then
    raise exception 'Category topics do not support semantic match settings' using errcode = '22023';
  end if;
  if not exists (select 1 from public.study_scene_embeddings
    where scene_id = new.id and user_id = new.user_id) then
    raise exception 'Study scene embedding not found';
  end if;
  perform public.refresh_semantic_study_scene_matches_for_owner(new.id, new.user_id);
  return new;
end;
$$;

drop trigger if exists refresh_study_scene_after_threshold_change on public.study_scenes;
create trigger refresh_study_scene_after_threshold_change
after update of match_threshold on public.study_scenes
for each row execute function public.refresh_study_scene_after_threshold_change();

create or replace function public.set_study_scene_match_settings(
  p_scene_id uuid, p_threshold double precision
)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_scene public.study_scenes%rowtype;
begin
  select * into v_scene from public.study_scenes
  where id = p_scene_id and user_id = auth.uid() for update;
  if not found then raise exception 'Study scene not found' using errcode = '42501'; end if;
  if v_scene.learning_topic_id is not null then
    raise exception 'Category topics do not support semantic match settings' using errcode = '22023';
  end if;
  if p_threshold is null or p_threshold not in (0.36, 0.38, 0.40, 0.42, 0.44, 0.46, 0.48) then
    raise exception 'Invalid match threshold' using errcode = '22023';
  end if;
  update public.study_scenes set match_threshold = p_threshold, updated_at = now()
  where id = v_scene.id;
  return public.get_study_scene_match_settings(v_scene.id);
end;
$$;

revoke all on function public.get_study_scene_match_settings(uuid) from public, anon;
revoke all on function public.set_study_scene_match_settings(uuid, double precision) from public, anon;
revoke all on function public.refresh_study_scene_after_threshold_change() from public, anon, authenticated;
grant execute on function public.get_study_scene_match_settings(uuid) to authenticated;
grant execute on function public.set_study_scene_match_settings(uuid, double precision) to authenticated;

notify pgrst, 'reload schema';
