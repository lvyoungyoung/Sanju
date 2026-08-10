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
          or (next_review_at at time zone 'Asia/Shanghai')::date <= (now() at time zone 'Asia/Shanghai')::date
        )
    )::integer as due_count,
    count(*) filter (where correct_count > 0)::integer as studied_count,
    count(*) filter (where last_studied_on = (now() at time zone 'Asia/Shanghai')::date)::integer as reviewable_today_count,
    round(avg(
      case
        when correct_count <= 0 then 0
        when correct_count <= 2 then 40
        when correct_count <= 4 then 70
        else 100
      end
    ))::integer as mastery_score
  from sentences
  group by topic;
$$;

revoke all on function public.get_sentence_study_topic_summaries() from public;
revoke all on function public.get_sentence_study_topic_summaries() from anon;
grant execute on function public.get_sentence_study_topic_summaries() to authenticated;
