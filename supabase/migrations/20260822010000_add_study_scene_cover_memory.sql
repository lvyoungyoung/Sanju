-- Give every study scene a stable visual anchor without making the client
-- download a new image just to render the study landing page. The client uses
-- this memory id only when its image is already cached locally.

drop function if exists public.create_study_scene_with_embedding(uuid, text, jsonb, text);
drop function if exists public.get_study_scene_summary_for_owner(uuid, uuid);
drop function if exists public.get_study_scenes();

create function public.get_study_scenes()
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
      progress.last_studied_on
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
        order by scene_sentences.memory_created_at desc nulls last,
                 scene_sentences.sentence_sort_order asc nulls last
      ) filter (where scene_sentences.memory_id is not null)
    )[1] as cover_memory_id,
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
  group by
    scene_sentences.scene_id,
    scene_sentences.scene_name,
    scene_sentences.scene_created_at
  order by scene_sentences.scene_created_at desc, scene_sentences.scene_id desc;
$$;

create function public.get_study_scene_summary_for_owner(
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
      progress.last_studied_on
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
        order by scene_sentences.memory_created_at desc nulls last,
                 scene_sentences.sentence_sort_order asc nulls last
      ) filter (where scene_sentences.memory_id is not null)
    )[1] as cover_memory_id,
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
  group by scene_sentences.scene_id, scene_sentences.scene_name;
$$;

create function public.create_study_scene_with_embedding(
  p_user_id uuid,
  p_name text,
  p_embedding jsonb,
  p_model text default 'qwen3.7-text-embedding'
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
  v_embedding real[] := public.jsonb_to_embedding_real_array(p_embedding);
begin
  if char_length(v_name) < 2 or char_length(v_name) > 24 then
    raise exception 'Study scene name must be between 2 and 24 characters';
  end if;
  if cardinality(v_embedding) <> 1024 then
    raise exception 'Invalid study scene embedding';
  end if;

  insert into public.study_scenes as scene (user_id, name)
  values (p_user_id, v_name)
  on conflict on constraint study_scenes_user_id_name_key do update
    set updated_at = now()
  returning scene.id into v_scene_id;

  insert into public.study_scene_embeddings as scene_embedding (scene_id, user_id, embedding, model)
  values (v_scene_id, p_user_id, v_embedding, coalesce(nullif(btrim(p_model), ''), 'qwen3.7-text-embedding'))
  on conflict (scene_id) do update set
    embedding = excluded.embedding,
    model = excluded.model,
    updated_at = now();

  perform public.refresh_semantic_study_scene_matches_for_owner(v_scene_id, p_user_id);

  return query
  select * from public.get_study_scene_summary_for_owner(p_user_id, v_scene_id);
end;
$$;

revoke all on function public.get_study_scenes() from public, anon;
grant execute on function public.get_study_scenes() to authenticated;
revoke all on function public.get_study_scene_summary_for_owner(uuid, uuid) from public, anon, authenticated;
revoke all on function public.create_study_scene_with_embedding(uuid, text, jsonb, text) from public, anon, authenticated;
grant execute on function public.create_study_scene_with_embedding(uuid, text, jsonb, text) to service_role;
