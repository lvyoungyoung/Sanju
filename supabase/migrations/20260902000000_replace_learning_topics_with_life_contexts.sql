-- Replace the provisional topic taxonomy with a stable, real-life context map.
-- Existing memories stay available, but their old topic assignments and generated
-- topic scenes are intentionally discarded before launch.

delete from public.sentence_study_progress as progress
where exists (
  select 1
  from public.study_scenes as scene
  where scene.learning_topic_id is not null
    and progress.study_scope = 'scene:' || scene.id::text
);

delete from public.study_scenes
where learning_topic_id is not null;

update public.memory_sentences
set learning_topic_ids = '{}'::text[]
where cardinality(learning_topic_ids) > 0;

alter table public.memory_sentences
  drop constraint if exists memory_sentences_learning_topic_ids_check;

alter table public.memory_sentences
  add constraint memory_sentences_learning_topic_ids_check
  check (
    cardinality(learning_topic_ids) <= 1
    and learning_topic_ids <@ array[
      'people_and_relationships', 'clothes_and_appearance', 'house_and_home', 'daily_routines',
      'food_and_cooking', 'shopping_and_consumption', 'health_and_body', 'hobbies_and_culture',
      'sports_and_fitness', 'social_occasions', 'travel_and_transport', 'places_and_public_services',
      'education_and_learning', 'work_and_career', 'nature_weather_and_environment',
      'digital_life_and_communication'
    ]::text[]
  );

alter table public.study_scenes
  drop constraint if exists study_scenes_learning_topic_id_check;

alter table public.study_scenes
  add constraint study_scenes_learning_topic_id_check
  check (
    learning_topic_id is null
    or learning_topic_id = any (array[
      'people_and_relationships', 'clothes_and_appearance', 'house_and_home', 'daily_routines',
      'food_and_cooking', 'shopping_and_consumption', 'health_and_body', 'hobbies_and_culture',
      'sports_and_fitness', 'social_occasions', 'travel_and_transport', 'places_and_public_services',
      'education_and_learning', 'work_and_career', 'nature_weather_and_environment',
      'digital_life_and_communication'
    ]::text[])
  );

create or replace function public.learning_topic_ids_from_json(p_value jsonb)
returns text[]
language sql
immutable
set search_path = public, pg_temp
as $$
  select coalesce(
    array(
      select topic_id
      from (
        select distinct on (items.value) items.value as topic_id, items.ordinality
        from jsonb_array_elements_text(
          case when jsonb_typeof(p_value) = 'array' then p_value else '[]'::jsonb end
        ) with ordinality as items(value, ordinality)
        where items.value = any (array[
          'people_and_relationships', 'clothes_and_appearance', 'house_and_home', 'daily_routines',
          'food_and_cooking', 'shopping_and_consumption', 'health_and_body', 'hobbies_and_culture',
          'sports_and_fitness', 'social_occasions', 'travel_and_transport', 'places_and_public_services',
          'education_and_learning', 'work_and_career', 'nature_weather_and_environment',
          'digital_life_and_communication'
        ]::text[])
        order by items.value, items.ordinality
      ) as unique_topics
      order by ordinality
      limit 1
    ),
    '{}'::text[]
  );
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
  if p_learning_topic_id is null or not (p_learning_topic_id = any (array[
    'people_and_relationships', 'clothes_and_appearance', 'house_and_home', 'daily_routines',
    'food_and_cooking', 'shopping_and_consumption', 'health_and_body', 'hobbies_and_culture',
    'sports_and_fitness', 'social_occasions', 'travel_and_transport', 'places_and_public_services',
    'education_and_learning', 'work_and_career', 'nature_weather_and_environment',
    'digital_life_and_communication'
  ]::text[])) then
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

revoke all on function public.learning_topic_ids_from_json(jsonb) from public, anon, authenticated;
revoke all on function public.create_learning_topic_study_scene(uuid, text, text) from public, anon, authenticated;
grant execute on function public.create_learning_topic_study_scene(uuid, text, text) to service_role;
