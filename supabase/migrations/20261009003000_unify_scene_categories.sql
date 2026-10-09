-- A single category catalog for independently classified photos and sentences.
-- Only obsolete classification IDs are removed; content, credits, favorites and
-- study progress are not recreated or reset. No legacy aliases or AI backfill.
create or replace function public.scene_category_ids()
returns text[] language sql immutable set search_path = public, pg_temp as $$
  select array[
    'people_and_portraits',
    'self_and_style',
    'family_time',
    'children_growing_up',
    'friends_gatherings',
    'romance_and_companionship',
    'pets_and_animals',
    'flowers_and_plants',
    'food_and_drinks',
    'restaurants_and_cafes',
    'cooking',
    'home_life',
    'city_life',
    'natural_scenery',
    'travel',
    'transport',
    'sports_and_outdoors',
    'festivals_and_celebrations',
    'arts_and_entertainment',
    'school_and_study',
    'work_life',
    'shopping',
    'health_and_wellness',
    'objects_and_details',
    'screenshots_and_documents'
  ]::text[];
$$;

create or replace function public.scene_category_catalog_version()
returns text language sql immutable set search_path = public, pg_temp as $$
  select 'unified-scenes-v1'::text;
$$;

create or replace function public.normalize_scene_category_ids(p_ids text[], p_limit integer)
returns text[] language sql immutable set search_path = public, pg_temp as $$
  select array(
    select category_id from (
      select btrim(category_id) as category_id, min(position) as position
      from unnest(coalesce(p_ids, '{}'::text[])) with ordinality as input(category_id, position)
      where btrim(category_id) = any(public.scene_category_ids())
      group by btrim(category_id)
    ) unique_categories order by position limit least(3, greatest(0, coalesce(p_limit, 0)))
  );
$$;

create or replace function public.normalize_memory_photo_categories(p_tags text[])
returns text[] language sql immutable set search_path = public, pg_temp as $$
  select public.normalize_scene_category_ids(p_tags, 3);
$$;

create or replace function public.learning_topic_ids_from_json(p_value jsonb)
returns text[] language sql immutable set search_path = public, pg_temp as $$
  select public.normalize_scene_category_ids(array(
    select value #>> '{}' from jsonb_array_elements(
      case when jsonb_typeof(p_value) = 'array' then p_value else '[]'::jsonb end
    ) with ordinality as input(value, position)
    where jsonb_typeof(value) = 'string' order by position
  ), 2);
$$;

alter table public.memory_sentences drop constraint if exists memory_sentences_learning_topic_ids_check;
alter table public.study_scenes drop constraint if exists study_scenes_learning_topic_id_check;
alter table public.learning_topic_embeddings drop constraint if exists learning_topic_embeddings_topic_id_check;

update public.memory_sentences
set learning_topic_ids = public.normalize_scene_category_ids(learning_topic_ids, 2)
where learning_topic_ids is distinct from public.normalize_scene_category_ids(learning_topic_ids, 2);
update public.memories set tags = public.normalize_memory_photo_categories(tags)
where tags is distinct from public.normalize_memory_photo_categories(tags);
update public.study_scenes set learning_topic_id = null
where learning_topic_id is not null and not learning_topic_id = any(public.scene_category_ids());
delete from public.learning_topic_embeddings
where catalog_version <> public.scene_category_catalog_version()
   or not topic_id = any(public.scene_category_ids());

alter table public.memory_sentences add constraint memory_sentences_learning_topic_ids_check
  check (cardinality(learning_topic_ids) <= 2 and learning_topic_ids <@ public.scene_category_ids());
alter table public.study_scenes add constraint study_scenes_learning_topic_id_check
  check (learning_topic_id is null or learning_topic_id = any(public.scene_category_ids()));
alter table public.learning_topic_embeddings add constraint learning_topic_embeddings_topic_id_check
  check (topic_id = any(public.scene_category_ids()));

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
      on category.model = query.model and category.catalog_version = public.scene_category_catalog_version()
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
    where category.catalog_version = public.scene_category_catalog_version()
  ) = cardinality(public.scene_category_ids()) then 1 else 0 end where id = p_scene_id;
  return v_count;
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
          where category.catalog_version = public.scene_category_catalog_version()) <> cardinality(public.scene_category_ids()),
    'matched_count', (select count(*) from public.study_scene_sentences link
      join public.memory_sentences sentence on sentence.id = link.sentence_id
      join public.memories memory on memory.id = sentence.memory_id and memory.user_id = v_scene.user_id
      where link.scene_id = v_scene.id)
  );
end;
$$;

create or replace function public.create_learning_topic_study_scene(
  p_user_id uuid,
  p_name text,
  p_learning_topic_id text
)
returns table (
  id uuid,
  name text,
  cover_memory_id uuid,
  total_count integer,
  due_count integer,
  studied_count integer,
  reviewable_today_count integer,
  mastery_score integer
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_name text := btrim(coalesce(p_name, ''));
  v_scene_id uuid;
begin
  if char_length(v_name) < 2 or char_length(v_name) > 24 then
    raise exception 'Study scene name must be between 2 and 24 characters';
  end if;
  if p_learning_topic_id is null or not (p_learning_topic_id = any (public.scene_category_ids())) then
    raise exception 'Invalid learning topic';
  end if;

  insert into public.study_scenes as scene (user_id, name, learning_topic_id)
  values (p_user_id, v_name, p_learning_topic_id)
  on conflict on constraint study_scenes_user_id_name_key do update
    set learning_topic_id = excluded.learning_topic_id,
        updated_at = now()
  returning scene.id into v_scene_id;

  delete from public.study_scene_embeddings where scene_id = v_scene_id;
  perform public.refresh_learning_topic_study_scene_matches_for_owner(v_scene_id, p_user_id);

  return query
  select * from public.get_study_scene_summary_for_owner(p_user_id, v_scene_id);
end;
$$;

-- Catalog IDs are public metadata; normalization is an internal write helper.
revoke all on function public.normalize_scene_category_ids(text[], integer) from public, anon, authenticated;
revoke all on function public.normalize_memory_photo_categories(text[]) from public, anon, authenticated;
revoke all on function public.learning_topic_ids_from_json(jsonb) from public, anon, authenticated;
grant execute on function public.normalize_scene_category_ids(text[], integer) to service_role;
grant execute on function public.normalize_memory_photo_categories(text[]) to service_role;
grant execute on function public.learning_topic_ids_from_json(jsonb) to service_role;
notify pgrst, 'reload schema';
