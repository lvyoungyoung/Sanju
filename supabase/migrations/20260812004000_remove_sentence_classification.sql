-- Sentence-level coarse / medium / fine classifications are no longer part of
-- the product. Keep memory tags and semantic user-created scenes intact.

-- The old category-scene trigger and helper functions reference study_topic.
-- Semantic scenes use embeddings and study_scene_sentences instead.
drop trigger if exists match_sentence_to_user_study_scenes_trigger
  on public.memory_sentences;
drop function if exists public.match_sentence_to_user_study_scenes();
drop function if exists public.create_study_scene(text);
drop function if exists public.refresh_study_scene_matches(uuid);
drop function if exists public.study_scene_match_score(text, text, text, text, text[]);

drop function if exists public.get_sentence_study_topic_summaries();
drop function if exists public.get_sentence_study_topic_queue(text, integer);
drop function if exists public.get_sentence_studied_today_topic_queue(text, integer);

-- The eight-argument wrapper still finalizes memory creation and credit
-- deduction atomically through the existing seven-argument RPC. It now only
-- stores memory-level tags and deliberately ignores any legacy JSON fields.
create or replace function public.finalize_authenticated_generation(
  p_user_id uuid,
  p_memory_id uuid,
  p_client_request_id uuid,
  p_image_path text,
  p_created_at timestamptz,
  p_provider text,
  p_sentences jsonb,
  p_tags text[]
)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  remaining_balance integer := 0;
begin
  remaining_balance := public.finalize_authenticated_generation(
    p_user_id,
    p_memory_id,
    p_client_request_id,
    p_image_path,
    p_created_at,
    p_provider,
    p_sentences
  );

  update public.memories
     set tags = coalesce(
          array(
            select tag
            from (
              select distinct on (tag) tag, position
              from unnest(coalesce(p_tags, '{}'::text[])) with ordinality as input(tag, position)
              where tag = any (array[
                '人物', '风景', '旅行', '美食', '生活场景', '动物',
                '植物', '建筑', '活动', '物品', '截图/信息'
              ])
              order by tag, position
            ) as unique_tags
            order by position
            limit 3
          ),
          '{}'::text[]
     )
   where id = p_memory_id
     and user_id = p_user_id;

  return remaining_balance;
end;
$$;

-- A local (anonymous) study record can only be merged once it belongs to a
-- favorite sentence. User-created scenes are signed-in only and remain fully
-- supported by their own server-side progress records.
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

    if v_last_studied_on is null and v_last_studied_at is not null then
      v_last_studied_on := (v_last_studied_at at time zone 'Asia/Shanghai')::date;
    end if;
    v_next_review_on := coalesce(v_next_review_on, v_last_studied_on, (now() at time zone 'Asia/Shanghai')::date);
    v_next_review_at := v_next_review_on::timestamp at time zone 'Asia/Shanghai';

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
            when excluded.last_studied_on is not null
              and (progress.last_studied_on is null or excluded.last_studied_on >= progress.last_studied_on)
              then coalesce(excluded.last_result, progress.last_result)
            else progress.last_result
          end,
          last_studied_at = case
            when excluded.last_studied_at is null then progress.last_studied_at
            when progress.last_studied_at is null then excluded.last_studied_at
            else greatest(progress.last_studied_at, excluded.last_studied_at)
          end,
          last_studied_on = case
            when excluded.last_studied_on is null then progress.last_studied_on
            when progress.last_studied_on is null then excluded.last_studied_on
            else greatest(progress.last_studied_on, excluded.last_studied_on)
          end,
          next_review_at = greatest(progress.next_review_at, excluded.next_review_at),
          updated_at = timezone('utc'::text, now());

    return query select v_sentence_id, 'favorites'::text;
  end loop;
end;
$$;

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
  v_now timestamptz := now();
  v_today date := (now() at time zone 'Asia/Shanghai')::date;
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
  if found and v_existing.last_studied_on = v_today then return v_existing; end if;

  if p_was_correct then
    v_correct_count := coalesce(v_existing.correct_count, 0) + 1;
    v_wrong_count := coalesce(v_existing.wrong_count, 0);
    v_last_result := 'correct';
    if coalesce(v_existing.learning_step, 0) < 5 then
      v_learning_step := coalesce(v_existing.learning_step, 0) + 1;
      v_mastered_review_count := coalesce(v_existing.mastered_review_count, 0);
      case v_learning_step
        when 1 then v_next_review_at := ((v_today + 1)::timestamp at time zone 'Asia/Shanghai');
        when 2 then v_next_review_at := ((v_today + 2)::timestamp at time zone 'Asia/Shanghai');
        when 3 then v_next_review_at := ((v_today + 4)::timestamp at time zone 'Asia/Shanghai');
        when 4 then v_next_review_at := ((v_today + 7)::timestamp at time zone 'Asia/Shanghai');
        else v_next_review_at := ((v_today + 14)::timestamp at time zone 'Asia/Shanghai');
      end case;
    else
      v_learning_step := 5;
      v_mastered_review_count := coalesce(v_existing.mastered_review_count, 0) + 1;
      v_next_review_at := ((v_today + case when v_mastered_review_count = 1 then 30 else 60 end)::timestamp at time zone 'Asia/Shanghai');
    end if;
  else
    v_learning_step := least(coalesce(v_existing.learning_step, 0), 5);
    v_mastered_review_count := coalesce(v_existing.mastered_review_count, 0);
    v_correct_count := coalesce(v_existing.correct_count, 0);
    v_wrong_count := coalesce(v_existing.wrong_count, 0) + 1;
    v_last_result := 'incorrect';
    v_next_review_at := ((v_today + 1)::timestamp at time zone 'Asia/Shanghai');
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

-- Category-scoped progress cannot be reached after category removal. Preserve
-- favorites and explicitly created scene progress, and discard only stale data.
delete from public.sentence_study_progress
where study_scope <> 'favorites'
  and study_scope not like 'scene:%';

drop index if exists public.memory_sentences_study_topic_idx;
drop index if exists public.memory_sentences_coarse_category_idx;
alter table public.memory_sentences
  drop constraint if exists memory_sentences_study_topic_check,
  drop column if exists study_topic,
  drop column if exists coarse_category,
  drop column if exists fine_categories;
