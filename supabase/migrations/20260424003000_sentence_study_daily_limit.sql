drop function if exists public.get_sentence_study_queue(integer);
drop function if exists public.count_sentence_study_queue();

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
  with daily_budget as (
    select greatest(
      30 - count(*)::integer,
      0
    ) as remaining_slots
    from public.sentence_study_progress sp
    where sp.user_id = auth.uid()
      and sp.last_studied_on = (now() at time zone 'Asia/Shanghai')::date
  ),
  candidates as (
    select
      ms.id as sentence_id,
      ms.memory_id,
      ms.english,
      ms.chinese,
      m.image_url,
      m.created_at,
      coalesce(sp.learning_step, 0) as learning_step,
      coalesce(sp.mastered_review_count, 0) as mastered_review_count,
      coalesce(sp.correct_count, 0) as correct_count,
      coalesce(sp.wrong_count, 0) as wrong_count,
      sp.last_result,
      sp.next_review_at,
      case
        when sp.id is not null
          and sp.learning_step < 5
          and (sp.next_review_at at time zone 'Asia/Shanghai')::date <= (now() at time zone 'Asia/Shanghai')::date then 1
        when sp.id is null then 2
        when sp.id is not null
          and sp.learning_step >= 5
          and (sp.next_review_at at time zone 'Asia/Shanghai')::date <= (now() at time zone 'Asia/Shanghai')::date then 3
        else 99
      end as priority
    from public.memory_sentences ms
    join public.memories m
      on m.id = ms.memory_id
    left join public.sentence_study_progress sp
      on sp.sentence_id = ms.id
     and sp.user_id = auth.uid()
    where auth.uid() is not null
      and m.user_id = auth.uid()
      and ms.is_favorite = true
      and (
        sp.last_studied_on is null
        or sp.last_studied_on < (now() at time zone 'Asia/Shanghai')::date
      )
  )
  select
    sentence_id,
    memory_id,
    english,
    chinese,
    image_url,
    created_at,
    learning_step,
    mastered_review_count,
    correct_count,
    wrong_count,
    last_result,
    next_review_at
  from candidates
  where priority < 99
    and (select remaining_slots from daily_budget) > 0
  order by
    priority asc,
    coalesce((next_review_at at time zone 'Asia/Shanghai')::date, (now() at time zone 'Asia/Shanghai')::date) asc,
    created_at desc
  limit least(
    greatest(coalesce(p_limit, 5), 1),
    (select remaining_slots from daily_budget),
    30
  );
$$;

revoke all on function public.get_sentence_study_queue(integer) from public;
revoke all on function public.get_sentence_study_queue(integer) from anon;
grant execute on function public.get_sentence_study_queue(integer) to authenticated;

create or replace function public.count_sentence_study_queue()
returns integer
language sql
security definer
set search_path = public, pg_temp
as $$
  with daily_budget as (
    select greatest(
      30 - count(*)::integer,
      0
    ) as remaining_slots
    from public.sentence_study_progress sp
    where sp.user_id = auth.uid()
      and sp.last_studied_on = (now() at time zone 'Asia/Shanghai')::date
  ),
  candidates as (
    select
      case
        when sp.id is not null
          and sp.learning_step < 5
          and (sp.next_review_at at time zone 'Asia/Shanghai')::date <= (now() at time zone 'Asia/Shanghai')::date then 1
        when sp.id is null then 2
        when sp.id is not null
          and sp.learning_step >= 5
          and (sp.next_review_at at time zone 'Asia/Shanghai')::date <= (now() at time zone 'Asia/Shanghai')::date then 3
        else 99
      end as priority
    from public.memory_sentences ms
    join public.memories m
      on m.id = ms.memory_id
    left join public.sentence_study_progress sp
      on sp.sentence_id = ms.id
     and sp.user_id = auth.uid()
    where auth.uid() is not null
      and m.user_id = auth.uid()
      and ms.is_favorite = true
      and (
        sp.last_studied_on is null
        or sp.last_studied_on < (now() at time zone 'Asia/Shanghai')::date
      )
  )
  select least(
    count(*)::integer,
    (select remaining_slots from daily_budget)
  )
  from candidates
  where priority < 99;
$$;

revoke all on function public.count_sentence_study_queue() from public;
revoke all on function public.count_sentence_study_queue() from anon;
grant execute on function public.count_sentence_study_queue() to authenticated;
