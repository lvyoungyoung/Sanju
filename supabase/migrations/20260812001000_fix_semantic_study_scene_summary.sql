-- Qualify output columns explicitly. `RETURNS TABLE` names can otherwise be
-- mistaken for PL/pgSQL variables by PostgreSQL when this helper is reused.
create or replace function public.get_study_scene_summary_for_owner(
  p_user_id uuid,
  p_scene_id uuid
)
returns table (
  id uuid,
  name text,
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
      scene.id,
      scene.name,
      link.sentence_id,
      progress.id as progress_id,
      coalesce(progress.correct_count, 0) as correct_count,
      progress.next_review_at,
      progress.last_studied_on
    from public.study_scenes as scene
    left join public.study_scene_sentences as link on link.scene_id = scene.id
    left join public.sentence_study_progress as progress
      on progress.sentence_id = link.sentence_id
     and progress.user_id = p_user_id
     and progress.study_scope = 'scene:' || scene.id::text
    where scene.id = p_scene_id
      and scene.user_id = p_user_id
  )
  select
    scene_sentences.id,
    scene_sentences.name,
    count(scene_sentences.sentence_id)::integer,
    count(scene_sentences.sentence_id) filter (
      where (scene_sentences.last_studied_on is null or scene_sentences.last_studied_on < (now() at time zone 'Asia/Shanghai')::date)
        and (scene_sentences.progress_id is null or (scene_sentences.next_review_at at time zone 'Asia/Shanghai')::date <= (now() at time zone 'Asia/Shanghai')::date)
    )::integer,
    count(scene_sentences.sentence_id) filter (where scene_sentences.correct_count > 0)::integer,
    count(scene_sentences.sentence_id) filter (where scene_sentences.last_studied_on = (now() at time zone 'Asia/Shanghai')::date)::integer,
    coalesce(round(avg(case
      when scene_sentences.correct_count <= 0 then 0
      when scene_sentences.correct_count <= 2 then 40
      when scene_sentences.correct_count <= 4 then 70
      else 100
    end))::integer, 0)
  from scene_sentences
  group by scene_sentences.id, scene_sentences.name;
$$;

revoke all on function public.get_study_scene_summary_for_owner(uuid, uuid) from public, anon, authenticated;
