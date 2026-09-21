-- New clients send an IANA time zone with every study request. No account-wide
-- setting: two devices can use different local days without changing each other.
-- Keep signatures/return types intact for released clients.
create or replace function public.sentence_study_time_zone()
returns text
language plpgsql
stable
set search_path = public, pg_temp
as $$
declare
  v_zone text;
begin
  begin
    v_zone := nullif(current_setting('request.headers', true), '')::jsonb ->> 'x-sanju-study-time-zone';
  exception when others then
    return 'Asia/Shanghai';
  end;
  if v_zone is not null and char_length(v_zone) <= 100
    and exists (select 1 from pg_timezone_names where name = v_zone) then
    return v_zone;
  end if;
  -- Old clients do not send a time zone.
  return 'Asia/Shanghai';
end;
$$;

revoke all on function public.sentence_study_time_zone() from public, anon;
grant execute on function public.sentence_study_time_zone() to authenticated, service_role;

-- Existing contract from 20260811002000_scope_sentence_study_progress.sql
create or replace function public.get_sentence_study_queue(p_limit integer default 5)
returns table (
  sentence_id uuid,
  memory_id uuid,
  english text,
  chinese text,
  image_path text,
  memory_created_at timestamptz,
  learning_step integer,
  mastered_review_count integer,
  correct_count integer,
  wrong_count integer,
  last_result text,
  next_review_at timestamptz
)
language sql
security definer
set search_path = public, pg_temp
as $$
  with candidates as (
    select
      ms.id as sentence_id,
      ms.memory_id,
      ms.english,
      ms.chinese,
      m.image_url as image_path,
      m.created_at as memory_created_at,
      coalesce(sp.learning_step, 0) as learning_step,
      coalesce(sp.mastered_review_count, 0) as mastered_review_count,
      coalesce(sp.correct_count, 0) as correct_count,
      coalesce(sp.wrong_count, 0) as wrong_count,
      sp.last_result,
      sp.next_review_at,
      case
        when sp.id is not null and sp.learning_step < 5
          and (sp.next_review_at at time zone (select public.sentence_study_time_zone()))::date <= (now() at time zone (select public.sentence_study_time_zone()))::date then 1
        when sp.id is null then 2
        when sp.id is not null and sp.learning_step >= 5
          and (sp.next_review_at at time zone (select public.sentence_study_time_zone()))::date <= (now() at time zone (select public.sentence_study_time_zone()))::date then 3
        else 99
      end as priority
    from public.memory_sentences ms
    join public.memories m on m.id = ms.memory_id
    left join public.sentence_study_progress sp
      on sp.sentence_id = ms.id
     and sp.user_id = auth.uid()
     and sp.study_scope = 'favorites'
    where auth.uid() is not null
      and m.user_id = auth.uid()
      and ms.is_favorite = true
      and (coalesce((sp.last_studied_at at time zone (select public.sentence_study_time_zone()))::date, sp.last_studied_on) is null or coalesce((sp.last_studied_at at time zone (select public.sentence_study_time_zone()))::date, sp.last_studied_on) < (now() at time zone (select public.sentence_study_time_zone()))::date)
  )
  select sentence_id, memory_id, english, chinese, image_path, memory_created_at,
         learning_step, mastered_review_count, correct_count, wrong_count, last_result, next_review_at
  from candidates
  where priority < 99
  order by priority asc,
           coalesce((next_review_at at time zone (select public.sentence_study_time_zone()))::date, (now() at time zone (select public.sentence_study_time_zone()))::date) asc,
           memory_created_at desc
  limit least(greatest(coalesce(p_limit, 5), 1), 1000);
$$;

-- Existing contract from 20260811002000_scope_sentence_study_progress.sql
create or replace function public.count_sentence_study_queue()
returns integer
language sql
security definer
set search_path = public, pg_temp
as $$
  with candidates as (
    select case
      when sp.id is not null and sp.learning_step < 5
        and (sp.next_review_at at time zone (select public.sentence_study_time_zone()))::date <= (now() at time zone (select public.sentence_study_time_zone()))::date then 1
      when sp.id is null then 2
      when sp.id is not null and sp.learning_step >= 5
        and (sp.next_review_at at time zone (select public.sentence_study_time_zone()))::date <= (now() at time zone (select public.sentence_study_time_zone()))::date then 3
      else 99
    end as priority
    from public.memory_sentences ms
    join public.memories m on m.id = ms.memory_id
    left join public.sentence_study_progress sp
      on sp.sentence_id = ms.id
     and sp.user_id = auth.uid()
     and sp.study_scope = 'favorites'
    where auth.uid() is not null
      and m.user_id = auth.uid()
      and ms.is_favorite = true
      and (coalesce((sp.last_studied_at at time zone (select public.sentence_study_time_zone()))::date, sp.last_studied_on) is null or coalesce((sp.last_studied_at at time zone (select public.sentence_study_time_zone()))::date, sp.last_studied_on) < (now() at time zone (select public.sentence_study_time_zone()))::date)
  )
  select count(*)::integer
  from candidates
  where priority < 99;
$$;

-- Existing contract from 20260424004000_sentence_study_today_count.sql
create or replace function public.count_sentence_studied_today()
returns integer
language sql
security definer
set search_path = public, pg_temp
as $$
  select count(*)::integer
  from public.sentence_study_progress sp
  where sp.user_id = auth.uid()
    and coalesce((sp.last_studied_at at time zone (select public.sentence_study_time_zone()))::date, sp.last_studied_on) = (now() at time zone (select public.sentence_study_time_zone()))::date;
$$;

-- Existing contract from 20260811002000_scope_sentence_study_progress.sql
create or replace function public.count_sentence_studied_today_reviewable()
returns integer
language sql
security definer
set search_path = public, pg_temp
as $$
  select count(*)::integer
  from public.sentence_study_progress sp
  join public.memory_sentences ms on ms.id = sp.sentence_id
  join public.memories m on m.id = ms.memory_id
  where auth.uid() is not null
    and sp.user_id = auth.uid()
    and sp.study_scope = 'favorites'
    and m.user_id = auth.uid()
    and ms.is_favorite = true
    and coalesce((sp.last_studied_at at time zone (select public.sentence_study_time_zone()))::date, sp.last_studied_on) = (now() at time zone (select public.sentence_study_time_zone()))::date;
$$;

-- Existing contract from 20260811002000_scope_sentence_study_progress.sql
create or replace function public.get_sentence_studied_today_queue(p_limit integer default 30)
returns table (
  sentence_id uuid,
  memory_id uuid,
  english text,
  chinese text,
  image_path text,
  memory_created_at timestamptz,
  learning_step integer,
  mastered_review_count integer,
  correct_count integer,
  wrong_count integer,
  last_result text,
  next_review_at timestamptz
)
language sql
security definer
set search_path = public, pg_temp
as $$
  select
    ms.id, ms.memory_id, ms.english, ms.chinese, m.image_url, m.created_at,
    coalesce(sp.learning_step, 0), coalesce(sp.mastered_review_count, 0),
    coalesce(sp.correct_count, 0), coalesce(sp.wrong_count, 0),
    sp.last_result, sp.next_review_at
  from public.sentence_study_progress sp
  join public.memory_sentences ms on ms.id = sp.sentence_id
  join public.memories m on m.id = ms.memory_id
  where auth.uid() is not null
    and sp.user_id = auth.uid()
    and sp.study_scope = 'favorites'
    and m.user_id = auth.uid()
    and ms.is_favorite = true
    and coalesce((sp.last_studied_at at time zone (select public.sentence_study_time_zone()))::date, sp.last_studied_on) = (now() at time zone (select public.sentence_study_time_zone()))::date
  order by sp.last_studied_at asc nulls last, m.created_at desc
  limit least(greatest(coalesce(p_limit, 30), 1), 1000);
$$;

-- Existing contract from 20260812004000_remove_sentence_classification.sql
create or replace function public.merge_local_sentence_study_progress(p_items jsonb)
returns table (
  sentence_id uuid,
  study_scope text
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_time_zone text := public.sentence_study_time_zone();
  v_item jsonb;
  v_sentence_id uuid;
  v_learning_step integer;
  v_mastered_review_count integer;
  v_correct_count integer;
  v_wrong_count integer;
  v_last_result text;
  v_last_studied_at timestamptz;
  v_last_studied_on date;
  v_next_review_on date;
  v_next_review_at timestamptz;
begin
  if auth.uid() is null or p_items is null or jsonb_typeof(p_items) <> 'array' then
    return;
  end if;

  for v_item in select value from jsonb_array_elements(p_items)
  loop
    begin
      v_sentence_id := nullif(v_item ->> 'sentence_id', '')::uuid;
      v_learning_step := least(greatest(coalesce(nullif(v_item ->> 'learning_step', '')::integer, 0), 0), 5);
      v_mastered_review_count := greatest(coalesce(nullif(v_item ->> 'mastered_review_count', '')::integer, 0), 0);
      v_correct_count := greatest(coalesce(nullif(v_item ->> 'correct_count', '')::integer, 0), 0);
      v_wrong_count := greatest(coalesce(nullif(v_item ->> 'wrong_count', '')::integer, 0), 0);
      v_last_result := case when v_item ->> 'last_result' in ('correct', 'incorrect') then v_item ->> 'last_result' else null end;
      v_last_studied_at := nullif(v_item ->> 'last_studied_at', '')::timestamptz;
      v_last_studied_on := nullif(v_item ->> 'last_studied_on', '')::date;
      v_next_review_on := nullif(v_item ->> 'next_review_on', '')::date;
    exception when others then
      continue;
    end;

    if v_sentence_id is null then
      continue;
    end if;

    if v_last_studied_at is not null then
      v_last_studied_on := (v_last_studied_at at time zone v_time_zone)::date;
    end if;
    v_next_review_on := coalesce(v_next_review_on, v_last_studied_on, (now() at time zone v_time_zone)::date);
    v_next_review_at := v_next_review_on::timestamp at time zone v_time_zone;

    if not exists (
      select 1
      from public.memory_sentences as sentence
      join public.memories as memory on memory.id = sentence.memory_id
      where sentence.id = v_sentence_id
        and memory.user_id = auth.uid()
        and sentence.is_favorite = true
    ) then
      continue;
    end if;

    insert into public.sentence_study_progress as progress (
      user_id, sentence_id, study_scope, learning_step, mastered_review_count,
      correct_count, wrong_count, last_result, last_studied_at, last_studied_on, next_review_at
    ) values (
      auth.uid(), v_sentence_id, 'favorites', v_learning_step, v_mastered_review_count,
      v_correct_count, v_wrong_count, v_last_result, v_last_studied_at, v_last_studied_on, v_next_review_at
    )
    on conflict on constraint sentence_study_progress_user_id_sentence_id_scope_key do update
      set learning_step = greatest(progress.learning_step, excluded.learning_step),
          mastered_review_count = greatest(progress.mastered_review_count, excluded.mastered_review_count),
          correct_count = greatest(progress.correct_count, excluded.correct_count),
          wrong_count = greatest(progress.wrong_count, excluded.wrong_count),
          last_result = case
            when coalesce(excluded.last_studied_at, excluded.last_studied_on::timestamp at time zone v_time_zone) is not null
              and (coalesce(progress.last_studied_at, progress.last_studied_on::timestamp at time zone v_time_zone) is null
                or coalesce(excluded.last_studied_at, excluded.last_studied_on::timestamp at time zone v_time_zone)
                  >= coalesce(progress.last_studied_at, progress.last_studied_on::timestamp at time zone v_time_zone))
              then coalesce(excluded.last_result, progress.last_result)
            else progress.last_result
          end,
          last_studied_at = case
            when excluded.last_studied_at is null then progress.last_studied_at
            when progress.last_studied_at is null then excluded.last_studied_at
            else greatest(progress.last_studied_at, excluded.last_studied_at)
          end,
          last_studied_on = coalesce(
            (greatest(progress.last_studied_at, excluded.last_studied_at) at time zone v_time_zone)::date,
            greatest(progress.last_studied_on, excluded.last_studied_on)
          ),
          next_review_at = greatest(progress.next_review_at, excluded.next_review_at),
          updated_at = timezone('utc'::text, now());

    return query select v_sentence_id, 'favorites'::text;
  end loop;
end;
$$;

-- Existing contract from 20260812004000_remove_sentence_classification.sql
create or replace function public.record_sentence_study_result(
  p_sentence_id uuid,
  p_was_correct boolean,
  p_scope text default 'favorites'
)
returns public.sentence_study_progress
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_time_zone text := public.sentence_study_time_zone();
  v_now timestamptz := now();
  v_today date := (now() at time zone v_time_zone)::date;
  v_scope text := coalesce(nullif(trim(p_scope), ''), 'favorites');
  v_scene_id uuid;
  v_existing public.sentence_study_progress%rowtype;
  v_result public.sentence_study_progress%rowtype;
  v_learning_step integer;
  v_mastered_review_count integer;
  v_correct_count integer;
  v_wrong_count integer;
  v_next_review_at timestamptz;
  v_last_result text;
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;
  if char_length(v_scope) > 64 or (v_scope <> 'favorites' and v_scope not like 'scene:%') then
    raise exception 'Invalid study scope';
  end if;

  if v_scope like 'scene:%' then
    begin
      v_scene_id := substr(v_scope, 7)::uuid;
    exception when others then
      raise exception 'Invalid study scene scope';
    end;
  end if;

  perform 1
  from public.memory_sentences as sentence
  join public.memories as memory on memory.id = sentence.memory_id
  where sentence.id = p_sentence_id
    and memory.user_id = auth.uid()
    and (
      (v_scope = 'favorites' and sentence.is_favorite = true)
      or (v_scene_id is not null and exists (
        select 1
        from public.study_scene_sentences as link
        join public.study_scenes as scene on scene.id = link.scene_id
        where link.scene_id = v_scene_id
          and link.sentence_id = sentence.id
          and scene.user_id = auth.uid()
      ))
    );
  if not found then
    raise exception 'Sentence not available for study';
  end if;

  select * into v_existing
  from public.sentence_study_progress
  where user_id = auth.uid() and sentence_id = p_sentence_id and study_scope = v_scope
  for update;
  if found and coalesce((v_existing.last_studied_at at time zone v_time_zone)::date, v_existing.last_studied_on) = v_today then return v_existing; end if;

  if p_was_correct then
    v_correct_count := coalesce(v_existing.correct_count, 0) + 1;
    v_wrong_count := coalesce(v_existing.wrong_count, 0);
    v_last_result := 'correct';
    if coalesce(v_existing.learning_step, 0) < 5 then
      v_learning_step := coalesce(v_existing.learning_step, 0) + 1;
      v_mastered_review_count := coalesce(v_existing.mastered_review_count, 0);
      case v_learning_step
        when 1 then v_next_review_at := ((v_today + 1)::timestamp at time zone v_time_zone);
        when 2 then v_next_review_at := ((v_today + 2)::timestamp at time zone v_time_zone);
        when 3 then v_next_review_at := ((v_today + 4)::timestamp at time zone v_time_zone);
        when 4 then v_next_review_at := ((v_today + 7)::timestamp at time zone v_time_zone);
        else v_next_review_at := ((v_today + 14)::timestamp at time zone v_time_zone);
      end case;
    else
      v_learning_step := 5;
      v_mastered_review_count := coalesce(v_existing.mastered_review_count, 0) + 1;
      v_next_review_at := ((v_today + case when v_mastered_review_count = 1 then 30 else 60 end)::timestamp at time zone v_time_zone);
    end if;
  else
    v_learning_step := least(coalesce(v_existing.learning_step, 0), 5);
    v_mastered_review_count := coalesce(v_existing.mastered_review_count, 0);
    v_correct_count := coalesce(v_existing.correct_count, 0);
    v_wrong_count := coalesce(v_existing.wrong_count, 0) + 1;
    v_last_result := 'incorrect';
    v_next_review_at := ((v_today + 1)::timestamp at time zone v_time_zone);
  end if;

  insert into public.sentence_study_progress (
    user_id, sentence_id, study_scope, learning_step, mastered_review_count,
    correct_count, wrong_count, last_result, last_studied_at, last_studied_on, next_review_at
  ) values (
    auth.uid(), p_sentence_id, v_scope, v_learning_step, v_mastered_review_count,
    v_correct_count, v_wrong_count, v_last_result, v_now, v_today, v_next_review_at
  ) on conflict (user_id, sentence_id, study_scope) do update set
    learning_step = excluded.learning_step,
    mastered_review_count = excluded.mastered_review_count,
    correct_count = excluded.correct_count,
    wrong_count = excluded.wrong_count,
    last_result = excluded.last_result,
    last_studied_at = excluded.last_studied_at,
    last_studied_on = excluded.last_studied_on,
    next_review_at = excluded.next_review_at,
    updated_at = v_now
  returning * into v_result;
  return v_result;
end;
$$;

-- Existing contract from 20260822010000_add_study_scene_cover_memory.sql
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
        order by scene_sentences.memory_created_at desc nulls last,
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

-- Existing contract from 20260811003000_add_user_study_scenes.sql
create or replace function public.get_study_scene_queue(
  p_scene_id uuid,
  p_limit integer default 1000
)
returns table (
  sentence_id uuid,
  memory_id uuid,
  english text,
  chinese text,
  image_path text,
  memory_created_at timestamptz,
  learning_step integer,
  mastered_review_count integer,
  correct_count integer,
  wrong_count integer,
  last_result text,
  next_review_at timestamptz
)
language sql
security definer
set search_path = public, pg_temp
as $$
  with candidates as (
    select
      ms.id as sentence_id,
      ms.memory_id,
      ms.english,
      ms.chinese,
      m.image_url as image_path,
      m.created_at as memory_created_at,
      coalesce(sp.learning_step, 0) as learning_step,
      coalesce(sp.mastered_review_count, 0) as mastered_review_count,
      coalesce(sp.correct_count, 0) as correct_count,
      coalesce(sp.wrong_count, 0) as wrong_count,
      sp.last_result,
      sp.next_review_at,
      case
        when sp.id is not null and sp.learning_step < 5
          and (sp.next_review_at at time zone (select public.sentence_study_time_zone()))::date <= (now() at time zone (select public.sentence_study_time_zone()))::date then 1
        when sp.id is null then 2
        when sp.id is not null and sp.learning_step >= 5
          and (sp.next_review_at at time zone (select public.sentence_study_time_zone()))::date <= (now() at time zone (select public.sentence_study_time_zone()))::date then 3
        else 99
      end as priority
    from public.study_scenes scene
    join public.study_scene_sentences link on link.scene_id = scene.id
    join public.memory_sentences ms on ms.id = link.sentence_id
    join public.memories m on m.id = ms.memory_id
    left join public.sentence_study_progress sp
      on sp.sentence_id = ms.id
     and sp.user_id = auth.uid()
     and sp.study_scope = 'scene:' || scene.id::text
    where scene.id = p_scene_id
      and scene.user_id = auth.uid()
      and m.user_id = auth.uid()
      and (coalesce((sp.last_studied_at at time zone (select public.sentence_study_time_zone()))::date, sp.last_studied_on) is null or coalesce((sp.last_studied_at at time zone (select public.sentence_study_time_zone()))::date, sp.last_studied_on) < (now() at time zone (select public.sentence_study_time_zone()))::date)
  )
  select sentence_id, memory_id, english, chinese, image_path, memory_created_at,
         learning_step, mastered_review_count, correct_count, wrong_count, last_result, next_review_at
  from candidates
  where priority < 99
  order by priority asc, memory_created_at desc
  limit least(greatest(coalesce(p_limit, 1000), 1), 1000);
$$;

-- Existing contract from 20260811003000_add_user_study_scenes.sql
create or replace function public.get_studied_today_scene_queue(
  p_scene_id uuid,
  p_limit integer default 1000
)
returns table (
  sentence_id uuid,
  memory_id uuid,
  english text,
  chinese text,
  image_path text,
  memory_created_at timestamptz,
  learning_step integer,
  mastered_review_count integer,
  correct_count integer,
  wrong_count integer,
  last_result text,
  next_review_at timestamptz
)
language sql
security definer
set search_path = public, pg_temp
as $$
  select
    ms.id, ms.memory_id, ms.english, ms.chinese, m.image_url, m.created_at,
    coalesce(sp.learning_step, 0), coalesce(sp.mastered_review_count, 0),
    coalesce(sp.correct_count, 0), coalesce(sp.wrong_count, 0),
    sp.last_result, sp.next_review_at
  from public.study_scenes scene
  join public.study_scene_sentences link on link.scene_id = scene.id
  join public.memory_sentences ms on ms.id = link.sentence_id
  join public.memories m on m.id = ms.memory_id
  join public.sentence_study_progress sp
    on sp.sentence_id = ms.id
   and sp.user_id = auth.uid()
   and sp.study_scope = 'scene:' || scene.id::text
  where scene.id = p_scene_id
    and scene.user_id = auth.uid()
    and m.user_id = auth.uid()
    and coalesce((sp.last_studied_at at time zone (select public.sentence_study_time_zone()))::date, sp.last_studied_on) = (now() at time zone (select public.sentence_study_time_zone()))::date
  order by sp.last_studied_at asc nulls last, m.created_at desc
  limit least(greatest(coalesce(p_limit, 1000), 1), 1000);
$$;

-- Existing contract from 20260822010000_add_study_scene_cover_memory.sql
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
        order by scene_sentences.memory_created_at desc nulls last,
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
