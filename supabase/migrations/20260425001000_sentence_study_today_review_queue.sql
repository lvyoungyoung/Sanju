create or replace function public.get_sentence_studied_today_queue(p_limit integer default 30)
returns table (
  sentence_id uuid,
  memory_id uuid,
  english text,
  chinese text,
  image_url text,
  created_at timestamptz,
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
    sp.next_review_at
  from public.sentence_study_progress sp
  join public.memory_sentences ms
    on ms.id = sp.sentence_id
  join public.memories m
    on m.id = ms.memory_id
  where auth.uid() is not null
    and sp.user_id = auth.uid()
    and m.user_id = auth.uid()
    and ms.is_favorite = true
    and sp.last_studied_on = (now() at time zone 'Asia/Shanghai')::date
  order by
    sp.last_studied_at asc nulls last,
    m.created_at desc
  limit least(greatest(coalesce(p_limit, 30), 1), 200);
$$;

revoke all on function public.get_sentence_studied_today_queue(integer) from public;
revoke all on function public.get_sentence_studied_today_queue(integer) from anon;
grant execute on function public.get_sentence_studied_today_queue(integer) to authenticated;
