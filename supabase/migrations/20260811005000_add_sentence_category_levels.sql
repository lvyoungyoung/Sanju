-- Each sentence keeps a stable, browseable category hierarchy.
-- Learning scenes use the coarse category. `study_topic` remains available for
-- future medium-granularity experiences.

alter table public.memory_sentences
  add column if not exists coarse_category text,
  add column if not exists fine_categories text[] not null default '{}';

create index if not exists memory_sentences_coarse_category_idx
  on public.memory_sentences (coarse_category)
  where coarse_category is not null;

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
    -- The previous overload performs the atomic memory insert and credit debit.
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

    update public.memory_sentences as sentence
       set coarse_category = case
                when btrim(generated.item ->> 'coarse_category') = any (array[
                    '人物', '风景', '旅行', '美食', '生活场景', '动物',
                    '植物', '建筑', '活动', '物品', '截图/信息'
                ]) then btrim(generated.item ->> 'coarse_category')
                else null
           end,
           fine_categories = coalesce(
                array(
                    select btrim(fine_category)
                      from jsonb_array_elements_text(
                          coalesce(generated.item -> 'fine_categories', '[]'::jsonb)
                      ) with ordinality as fine_values(fine_category, position)
                     where char_length(btrim(fine_category)) between 2 and 10
                     order by position
                     limit 2
                ),
                '{}'::text[]
           )
      from jsonb_array_elements(coalesce(p_sentences, '[]'::jsonb)) with ordinality as generated(item, position)
     where sentence.memory_id = p_memory_id
       and sentence.sort_order = generated.position;

    return remaining_balance;
end;
$$;

revoke all on function public.finalize_authenticated_generation(uuid, uuid, uuid, text, timestamptz, text, jsonb, text[]) from public, anon, authenticated;
grant execute on function public.finalize_authenticated_generation(uuid, uuid, uuid, text, timestamptz, text, jsonb, text[]) to service_role;

-- Older sentences predate the category hierarchy. Their image-level tag is the
-- closest available coarse category, so keep them discoverable in learning.
update public.memory_sentences as sentence
   set coarse_category = memory.tags[1]
  from public.memories as memory
 where memory.id = sentence.memory_id
   and sentence.coarse_category is null
   and memory.tags[1] = any (array[
     '人物', '风景', '旅行', '美食', '生活场景', '动物',
     '植物', '建筑', '活动', '物品', '截图/信息'
   ]);

-- Move existing medium-category progress into the new coarse-category scope.
-- A sentence can only have one coarse category, so keeping the furthest
-- progress on a conflict preserves progress without double-counting it.
insert into public.sentence_study_progress as target (
  user_id,
  sentence_id,
  study_scope,
  learning_step,
  mastered_review_count,
  correct_count,
  wrong_count,
  last_result,
  last_studied_at,
  last_studied_on,
  next_review_at,
  created_at,
  updated_at
)
select
  source.user_id,
  source.sentence_id,
  sentence.coarse_category,
  source.learning_step,
  source.mastered_review_count,
  source.correct_count,
  source.wrong_count,
  source.last_result,
  source.last_studied_at,
  source.last_studied_on,
  source.next_review_at,
  source.created_at,
  source.updated_at
from public.sentence_study_progress as source
join public.memory_sentences as sentence on sentence.id = source.sentence_id
where source.study_scope = sentence.study_topic
  and sentence.coarse_category is not null
on conflict (user_id, sentence_id, study_scope) do update
  set learning_step = greatest(target.learning_step, excluded.learning_step),
      mastered_review_count = greatest(target.mastered_review_count, excluded.mastered_review_count),
      correct_count = greatest(target.correct_count, excluded.correct_count),
      wrong_count = greatest(target.wrong_count, excluded.wrong_count),
      last_result = case
        when target.last_studied_at is null then excluded.last_result
        when excluded.last_studied_at is null then target.last_result
        when excluded.last_studied_at >= target.last_studied_at then excluded.last_result
        else target.last_result
      end,
      last_studied_at = greatest(target.last_studied_at, excluded.last_studied_at),
      last_studied_on = greatest(target.last_studied_on, excluded.last_studied_on),
      next_review_at = greatest(target.next_review_at, excluded.next_review_at),
      updated_at = greatest(target.updated_at, excluded.updated_at);

delete from public.sentence_study_progress as progress
using public.memory_sentences as sentence
where progress.sentence_id = sentence.id
  and progress.study_scope = sentence.study_topic
  and sentence.coarse_category is not null;

create or replace function public.get_sentence_study_topic_queue(
  p_topic text,
  p_limit integer default 30
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
      ms.id as sentence_id, ms.memory_id, ms.english, ms.chinese,
      m.image_url as image_path, m.created_at as memory_created_at,
      coalesce(sp.learning_step, 0) as learning_step,
      coalesce(sp.mastered_review_count, 0) as mastered_review_count,
      coalesce(sp.correct_count, 0) as correct_count,
      coalesce(sp.wrong_count, 0) as wrong_count,
      sp.last_result, sp.next_review_at,
      case
        when sp.id is not null and sp.learning_step < 5
          and (sp.next_review_at at time zone 'Asia/Shanghai')::date <= (now() at time zone 'Asia/Shanghai')::date then 1
        when sp.id is null then 2
        when sp.id is not null and sp.learning_step >= 5
          and (sp.next_review_at at time zone 'Asia/Shanghai')::date <= (now() at time zone 'Asia/Shanghai')::date then 3
        else 99
      end as priority
    from public.memory_sentences ms
    join public.memories m on m.id = ms.memory_id
    left join public.sentence_study_progress sp
      on sp.sentence_id = ms.id
     and sp.user_id = auth.uid()
     and sp.study_scope = p_topic
    where auth.uid() is not null
      and m.user_id = auth.uid()
      and ms.coarse_category = p_topic
      and (sp.last_studied_on is null or sp.last_studied_on < (now() at time zone 'Asia/Shanghai')::date)
  )
  select sentence_id, memory_id, english, chinese, image_path, memory_created_at,
         learning_step, mastered_review_count, correct_count, wrong_count, last_result, next_review_at
  from candidates
  where priority < 99
  order by priority asc,
           coalesce((next_review_at at time zone 'Asia/Shanghai')::date, (now() at time zone 'Asia/Shanghai')::date) asc,
           memory_created_at desc
  limit least(greatest(coalesce(p_limit, 30), 1), 1000);
$$;

create or replace function public.get_sentence_studied_today_topic_queue(
  p_topic text,
  p_limit integer default 200
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
  from public.sentence_study_progress sp
  join public.memory_sentences ms on ms.id = sp.sentence_id
  join public.memories m on m.id = ms.memory_id
  where auth.uid() is not null
    and sp.user_id = auth.uid()
    and sp.study_scope = p_topic
    and m.user_id = auth.uid()
    and ms.coarse_category = p_topic
    and sp.last_studied_on = (now() at time zone 'Asia/Shanghai')::date
  order by sp.last_studied_at asc nulls last, m.created_at desc
  limit least(greatest(coalesce(p_limit, 200), 1), 1000);
$$;

drop function if exists public.get_sentence_study_topic_summaries();
create function public.get_sentence_study_topic_summaries()
returns table (
  topic text,
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
  with sentences as (
    select
      ms.coarse_category as topic,
      sp.id as progress_id,
      coalesce(sp.correct_count, 0) as correct_count,
      sp.next_review_at,
      sp.last_studied_on
    from public.memory_sentences ms
    join public.memories m on m.id = ms.memory_id
    left join public.sentence_study_progress sp
      on sp.sentence_id = ms.id
     and sp.user_id = auth.uid()
     and sp.study_scope = ms.coarse_category
    where auth.uid() is not null
      and m.user_id = auth.uid()
      and ms.coarse_category is not null
  )
  select
    topic,
    count(*)::integer as total_count,
    count(*) filter (
      where (last_studied_on is null or last_studied_on < (now() at time zone 'Asia/Shanghai')::date)
        and (progress_id is null or (next_review_at at time zone 'Asia/Shanghai')::date <= (now() at time zone 'Asia/Shanghai')::date)
    )::integer as due_count,
    count(*) filter (where correct_count > 0)::integer as studied_count,
    count(*) filter (where last_studied_on = (now() at time zone 'Asia/Shanghai')::date)::integer as reviewable_today_count,
    round(avg(case
      when correct_count <= 0 then 0
      when correct_count <= 2 then 40
      when correct_count <= 4 then 70
      else 100
    end))::integer as mastery_score
  from sentences
  group by topic;
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
  if char_length(v_scope) > 64
     or (v_scope <> 'favorites' and char_length(v_scope) < 2) then
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
  from public.memory_sentences ms
  join public.memories m on m.id = ms.memory_id
  where ms.id = p_sentence_id
    and m.user_id = auth.uid()
    and (
      (v_scope = 'favorites' and ms.is_favorite = true)
      or (v_scope not like 'scene:%' and v_scope <> 'favorites' and ms.coarse_category = v_scope)
      or (v_scene_id is not null and exists (
        select 1
        from public.study_scene_sentences link
        join public.study_scenes scene on scene.id = link.scene_id
        where link.scene_id = v_scene_id
          and link.sentence_id = ms.id
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

revoke all on function public.get_sentence_study_topic_queue(text, integer) from public, anon;
grant execute on function public.get_sentence_study_topic_queue(text, integer) to authenticated;
revoke all on function public.get_sentence_studied_today_topic_queue(text, integer) from public, anon;
grant execute on function public.get_sentence_studied_today_topic_queue(text, integer) to authenticated;
revoke all on function public.get_sentence_study_topic_summaries() from public, anon;
grant execute on function public.get_sentence_study_topic_summaries() to authenticated;
revoke all on function public.record_sentence_study_result(uuid, boolean, text) from public, anon;
grant execute on function public.record_sentence_study_result(uuid, boolean, text) to authenticated;
