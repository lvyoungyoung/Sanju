-- Prefer the oldest matching memory so new generations do not replace a topic cover.
-- Memory ID breaks creation-time ties deterministically. Keep RPC contracts,
-- existing execute privileges, study counts and device-time-zone behavior unchanged.

create or replace function public.get_study_scenes()
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
language sql
security definer
set search_path = public, pg_temp
as $$
  with scene_sentences as (
    select
      scene.id as scene_id,
      scene.name as scene_name,
      scene.created_at as scene_created_at,
      link.sentence_id,
      memory.id as memory_id,
      memory.created_at as memory_created_at,
      sentence.sort_order as sentence_sort_order,
      progress.id as progress_id,
      coalesce(progress.correct_count, 0) as correct_count,
      progress.next_review_at,
      coalesce((progress.last_studied_at at time zone (select public.sentence_study_time_zone()))::date, progress.last_studied_on) as last_studied_on
    from public.study_scenes as scene
    left join public.study_scene_sentences as link on link.scene_id = scene.id
    left join public.memory_sentences as sentence on sentence.id = link.sentence_id
    left join public.memories as memory on memory.id = sentence.memory_id
    left join public.sentence_study_progress as progress
      on progress.sentence_id = link.sentence_id
     and progress.user_id = auth.uid()
     and progress.study_scope = 'scene:' || scene.id::text
    where scene.user_id = auth.uid()
  )
  select
    scene_sentences.scene_id as id,
    scene_sentences.scene_name as name,
    (
      array_agg(
        scene_sentences.memory_id
        order by scene_sentences.memory_created_at asc nulls last,
                 scene_sentences.memory_id asc,
                 scene_sentences.sentence_sort_order asc nulls last
      ) filter (where scene_sentences.memory_id is not null)
    )[1] as cover_memory_id,
    count(scene_sentences.sentence_id)::integer as total_count,
    count(scene_sentences.sentence_id) filter (
      where (scene_sentences.last_studied_on is null or scene_sentences.last_studied_on < (now() at time zone (select public.sentence_study_time_zone()))::date)
        and (
          scene_sentences.progress_id is null
          or (scene_sentences.next_review_at at time zone (select public.sentence_study_time_zone()))::date <= (now() at time zone (select public.sentence_study_time_zone()))::date
        )
    )::integer as due_count,
    count(scene_sentences.sentence_id) filter (where scene_sentences.correct_count > 0)::integer as studied_count,
    count(scene_sentences.sentence_id) filter (where scene_sentences.last_studied_on = (now() at time zone (select public.sentence_study_time_zone()))::date)::integer as reviewable_today_count,
    coalesce(round(avg(
      case
        when scene_sentences.correct_count <= 0 then 0
        when scene_sentences.correct_count <= 2 then 40
        when scene_sentences.correct_count <= 4 then 70
        else 100
      end
    ))::integer, 0) as mastery_score
  from scene_sentences
  group by
    scene_sentences.scene_id,
    scene_sentences.scene_name,
    scene_sentences.scene_created_at
  order by scene_sentences.scene_created_at desc, scene_sentences.scene_id desc;
$$;

create or replace function public.get_study_scene_summary_for_owner(
  p_user_id uuid,
  p_scene_id uuid
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
language sql
security definer
set search_path = public, pg_temp
as $$
  with scene_sentences as (
    select
      scene.id as scene_id,
      scene.name as scene_name,
      link.sentence_id,
      memory.id as memory_id,
      memory.created_at as memory_created_at,
      sentence.sort_order as sentence_sort_order,
      progress.id as progress_id,
      coalesce(progress.correct_count, 0) as correct_count,
      progress.next_review_at,
      coalesce((progress.last_studied_at at time zone (select public.sentence_study_time_zone()))::date, progress.last_studied_on) as last_studied_on
    from public.study_scenes as scene
    left join public.study_scene_sentences as link on link.scene_id = scene.id
    left join public.memory_sentences as sentence on sentence.id = link.sentence_id
    left join public.memories as memory on memory.id = sentence.memory_id
    left join public.sentence_study_progress as progress
      on progress.sentence_id = link.sentence_id
     and progress.user_id = p_user_id
     and progress.study_scope = 'scene:' || scene.id::text
    where scene.id = p_scene_id
      and scene.user_id = p_user_id
  )
  select
    scene_sentences.scene_id as id,
    scene_sentences.scene_name as name,
    (
      array_agg(
        scene_sentences.memory_id
        order by scene_sentences.memory_created_at asc nulls last,
                 scene_sentences.memory_id asc,
                 scene_sentences.sentence_sort_order asc nulls last
      ) filter (where scene_sentences.memory_id is not null)
    )[1] as cover_memory_id,
    count(scene_sentences.sentence_id)::integer as total_count,
    count(scene_sentences.sentence_id) filter (
      where (scene_sentences.last_studied_on is null or scene_sentences.last_studied_on < (now() at time zone (select public.sentence_study_time_zone()))::date)
        and (
          scene_sentences.progress_id is null
          or (scene_sentences.next_review_at at time zone (select public.sentence_study_time_zone()))::date <= (now() at time zone (select public.sentence_study_time_zone()))::date
        )
    )::integer as due_count,
    count(scene_sentences.sentence_id) filter (where scene_sentences.correct_count > 0)::integer as studied_count,
    count(scene_sentences.sentence_id) filter (where scene_sentences.last_studied_on = (now() at time zone (select public.sentence_study_time_zone()))::date)::integer as reviewable_today_count,
    coalesce(round(avg(
      case
        when scene_sentences.correct_count <= 0 then 0
        when scene_sentences.correct_count <= 2 then 40
        when scene_sentences.correct_count <= 4 then 70
        else 100
      end
    ))::integer, 0) as mastery_score
  from scene_sentences
  group by scene_sentences.scene_id, scene_sentences.scene_name;
$$;

