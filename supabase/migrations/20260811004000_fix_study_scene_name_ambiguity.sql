-- `create_study_scene` returns a column named `name`, which becomes an
-- implicit PL/pgSQL variable. Refer to the unique constraint and all return
-- columns explicitly so PostgreSQL never needs to guess which `name` is meant.

create or replace function public.get_study_scenes()
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
      scene.id as scene_id,
      scene.name as scene_name,
      link.sentence_id,
      sp.id as progress_id,
      coalesce(sp.correct_count, 0) as correct_count,
      sp.learning_step,
      sp.next_review_at,
      sp.last_studied_on
    from public.study_scenes as scene
    left join public.study_scene_sentences as link on link.scene_id = scene.id
    left join public.sentence_study_progress as sp
      on sp.sentence_id = link.sentence_id
     and sp.user_id = auth.uid()
     and sp.study_scope = 'scene:' || scene.id::text
    where scene.user_id = auth.uid()
  )
  select
    scene_sentences.scene_id as id,
    scene_sentences.scene_name as name,
    count(scene_sentences.sentence_id)::integer as total_count,
    count(scene_sentences.sentence_id) filter (
      where (scene_sentences.last_studied_on is null or scene_sentences.last_studied_on < (now() at time zone 'Asia/Shanghai')::date)
        and (
          scene_sentences.progress_id is null
          or (scene_sentences.next_review_at at time zone 'Asia/Shanghai')::date <= (now() at time zone 'Asia/Shanghai')::date
        )
    )::integer as due_count,
    count(scene_sentences.sentence_id) filter (where scene_sentences.correct_count > 0)::integer as studied_count,
    count(scene_sentences.sentence_id) filter (where scene_sentences.last_studied_on = (now() at time zone 'Asia/Shanghai')::date)::integer as reviewable_today_count,
    coalesce(round(avg(
      case
        when scene_sentences.correct_count <= 0 then 0
        when scene_sentences.correct_count <= 2 then 40
        when scene_sentences.correct_count <= 4 then 70
        else 100
      end
    ))::integer, 0) as mastery_score
  from scene_sentences
  group by scene_sentences.scene_id, scene_sentences.scene_name
  order by scene_sentences.scene_name;
$$;

create or replace function public.create_study_scene(p_name text)
returns table (
  id uuid,
  name text,
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
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;
  if char_length(v_name) < 2 or char_length(v_name) > 24 then
    raise exception 'Study scene name must be between 2 and 24 characters';
  end if;

  insert into public.study_scenes (user_id, name)
  values (auth.uid(), v_name)
  on conflict on constraint study_scenes_user_id_name_key do update
    set updated_at = now()
  returning public.study_scenes.id into v_scene_id;

  perform public.refresh_study_scene_matches(v_scene_id);

  return query
  select
    scenes.id,
    scenes.name,
    scenes.total_count,
    scenes.due_count,
    scenes.studied_count,
    scenes.reviewable_today_count,
    scenes.mastery_score
  from public.get_study_scenes() as scenes
  where scenes.id = v_scene_id;
end;
$$;

revoke all on function public.create_study_scene(text) from public, anon;
grant execute on function public.create_study_scene(text) to authenticated;
revoke all on function public.get_study_scenes() from public, anon;
grant execute on function public.get_study_scenes() to authenticated;
