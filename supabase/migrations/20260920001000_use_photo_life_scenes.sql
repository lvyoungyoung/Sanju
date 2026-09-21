-- Replace only classification metadata, not memories, sentences, favorites or
-- study progress. Custom semantic themes and their memberships remain intact.
-- Deploy this migration before the three updated Edge Functions.
delete from public.study_scenes where learning_topic_id is not null;

update public.memory_sentences
set learning_topic_ids = '{}'::text[]
where cardinality(learning_topic_ids) > 0;

alter table public.memory_sentences
  drop constraint if exists memory_sentences_learning_topic_ids_check;

alter table public.memory_sentences
  add constraint memory_sentences_learning_topic_ids_check
  check (
    cardinality(learning_topic_ids) <= 2
    and learning_topic_ids <@ array[
      'self_and_style',
      'family_time',
      'children_growing_up',
      'friends_gatherings',
      'romance_and_companionship',
      'pet_life',
      'food_and_drinks',
      'cooking',
      'home_life',
      'city_life',
      'natural_scenery',
      'plants_and_wildlife',
      'travel',
      'transport',
      'sports_and_outdoors',
      'festivals_and_celebrations',
      'arts_and_entertainment',
      'school_and_study',
      'work_life',
      'shopping',
      'health_and_wellness'
    ]::text[]
  );

alter table public.study_scenes
  drop constraint if exists study_scenes_learning_topic_id_check;

alter table public.study_scenes
  add constraint study_scenes_learning_topic_id_check
  check (
    learning_topic_id is null
    or learning_topic_id = any (array[
      'self_and_style',
      'family_time',
      'children_growing_up',
      'friends_gatherings',
      'romance_and_companionship',
      'pet_life',
      'food_and_drinks',
      'cooking',
      'home_life',
      'city_life',
      'natural_scenery',
      'plants_and_wildlife',
      'travel',
      'transport',
      'sports_and_outdoors',
      'festivals_and_celebrations',
      'arts_and_entertainment',
      'school_and_study',
      'work_life',
      'shopping',
      'health_and_wellness'
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
      'self_and_style',
      'family_time',
      'children_growing_up',
      'friends_gatherings',
      'romance_and_companionship',
      'pet_life',
      'food_and_drinks',
      'cooking',
      'home_life',
      'city_life',
      'natural_scenery',
      'plants_and_wildlife',
      'travel',
      'transport',
      'sports_and_outdoors',
      'festivals_and_celebrations',
      'arts_and_entertainment',
      'school_and_study',
      'work_life',
      'shopping',
      'health_and_wellness'
    ]::text[])
        order by items.value, items.ordinality
      ) as unique_topics
      order by ordinality
      limit 2
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
      'self_and_style',
      'family_time',
      'children_growing_up',
      'friends_gatherings',
      'romance_and_companionship',
      'pet_life',
      'food_and_drinks',
      'cooking',
      'home_life',
      'city_life',
      'natural_scenery',
      'plants_and_wildlife',
      'travel',
      'transport',
      'sports_and_outdoors',
      'festivals_and_celebrations',
      'arts_and_entertainment',
      'school_and_study',
      'work_life',
      'shopping',
      'health_and_wellness'
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
