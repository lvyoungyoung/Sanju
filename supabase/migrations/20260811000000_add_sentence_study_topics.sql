alter table public.memory_sentences
  add column if not exists study_topic text;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'memory_sentences_study_topic_check'
      and conrelid = 'public.memory_sentences'::regclass
  ) then
    alter table public.memory_sentences
      add constraint memory_sentences_study_topic_check
      check (
        study_topic is null
        or (
          char_length(btrim(study_topic)) between 2 and 8
          and btrim(study_topic) <> '收藏'
          and btrim(study_topic) <> 'favorites'
        )
      );
  end if;
end;
$$;

create index if not exists memory_sentences_study_topic_idx
  on public.memory_sentences (study_topic)
  where study_topic is not null;

-- Keep the existing atomic generation transaction, then attach the per-sentence
-- topic chosen by the model to the rows it just created.
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
set search_path = public
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

    update public.memory_sentences ms
       set study_topic = case
            when char_length(btrim(coalesce(payload.value ->> 'study_topic', ''))) between 2 and 8
              and btrim(payload.value ->> 'study_topic') <> '收藏'
              and btrim(payload.value ->> 'study_topic') <> 'favorites'
              then btrim(payload.value ->> 'study_topic')
            else null
       end
      from jsonb_array_elements(p_sentences) with ordinality as payload(value, sort_order)
     where ms.memory_id = p_memory_id
       and ms.sort_order = payload.sort_order
       and exists (
            select 1
            from public.memories m
            where m.id = ms.memory_id
              and m.user_id = p_user_id
       );

    return remaining_balance;
end;
$$;

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
  with daily_budget as (
    select greatest(30 - count(*)::integer, 0) as remaining_slots
    from public.sentence_study_progress sp
    where sp.user_id = auth.uid()
      and sp.last_studied_on = (now() at time zone 'Asia/Shanghai')::date
  ), candidates as (
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
          and (sp.next_review_at at time zone 'Asia/Shanghai')::date <= (now() at time zone 'Asia/Shanghai')::date then 1
        when sp.id is null then 2
        when sp.id is not null and sp.learning_step >= 5
          and (sp.next_review_at at time zone 'Asia/Shanghai')::date <= (now() at time zone 'Asia/Shanghai')::date then 3
        else 99
      end as priority
    from public.memory_sentences ms
    join public.memories m on m.id = ms.memory_id
    left join public.sentence_study_progress sp
      on sp.sentence_id = ms.id and sp.user_id = auth.uid()
    where auth.uid() is not null
      and m.user_id = auth.uid()
      and ms.study_topic = p_topic
      and (sp.last_studied_on is null or sp.last_studied_on < (now() at time zone 'Asia/Shanghai')::date)
  )
  select sentence_id, memory_id, english, chinese, image_path, memory_created_at,
         learning_step, mastered_review_count, correct_count, wrong_count, last_result, next_review_at
  from candidates
  where priority < 99
    and (select remaining_slots from daily_budget) > 0
  order by priority asc,
           coalesce((next_review_at at time zone 'Asia/Shanghai')::date, (now() at time zone 'Asia/Shanghai')::date) asc,
           memory_created_at desc
  limit least(greatest(coalesce(p_limit, 30), 1), (select remaining_slots from daily_budget), 30);
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
    and m.user_id = auth.uid()
    and ms.study_topic = p_topic
    and sp.last_studied_on = (now() at time zone 'Asia/Shanghai')::date
  order by sp.last_studied_at asc nulls last, m.created_at desc
  limit least(greatest(coalesce(p_limit, 200), 1), 200);
$$;

create or replace function public.get_sentence_study_topic_summaries()
returns table (
  topic text,
  total_count integer,
  due_count integer,
  studied_count integer,
  reviewable_today_count integer
)
language sql
security definer
set search_path = public, pg_temp
as $$
  with sentences as (
    select
      ms.study_topic as topic,
      sp.id as progress_id,
      coalesce(sp.correct_count, 0) as correct_count,
      sp.learning_step,
      sp.next_review_at,
      sp.last_studied_on
    from public.memory_sentences ms
    join public.memories m on m.id = ms.memory_id
    left join public.sentence_study_progress sp
      on sp.sentence_id = ms.id and sp.user_id = auth.uid()
    where auth.uid() is not null
      and m.user_id = auth.uid()
      and ms.study_topic is not null
  )
  select
    topic,
    count(*)::integer as total_count,
    count(*) filter (
      where (last_studied_on is null or last_studied_on < (now() at time zone 'Asia/Shanghai')::date)
        and (
          progress_id is null
          or (learning_step < 5 and (next_review_at at time zone 'Asia/Shanghai')::date <= (now() at time zone 'Asia/Shanghai')::date)
          or (learning_step >= 5 and (next_review_at at time zone 'Asia/Shanghai')::date <= (now() at time zone 'Asia/Shanghai')::date)
        )
    )::integer as due_count,
    count(*) filter (where correct_count > 0)::integer as studied_count,
    count(*) filter (where last_studied_on = (now() at time zone 'Asia/Shanghai')::date)::integer as reviewable_today_count
  from sentences
  group by topic;
$$;

revoke all on function public.get_sentence_study_topic_queue(text, integer) from public;
revoke all on function public.get_sentence_study_topic_queue(text, integer) from anon;
grant execute on function public.get_sentence_study_topic_queue(text, integer) to authenticated;

revoke all on function public.get_sentence_studied_today_topic_queue(text, integer) from public;
revoke all on function public.get_sentence_studied_today_topic_queue(text, integer) from anon;
grant execute on function public.get_sentence_studied_today_topic_queue(text, integer) to authenticated;

revoke all on function public.get_sentence_study_topic_summaries() from public;
revoke all on function public.get_sentence_study_topic_summaries() from anon;
grant execute on function public.get_sentence_study_topic_summaries() to authenticated;

revoke all on function public.finalize_authenticated_generation(uuid, uuid, uuid, text, timestamptz, text, jsonb, text[]) from public;
revoke all on function public.finalize_authenticated_generation(uuid, uuid, uuid, text, timestamptz, text, jsonb, text[]) from anon;
revoke all on function public.finalize_authenticated_generation(uuid, uuid, uuid, text, timestamptz, text, jsonb, text[]) from authenticated;
grant execute on function public.finalize_authenticated_generation(uuid, uuid, uuid, text, timestamptz, text, jsonb, text[]) to service_role;
