create or replace function public.count_sentence_studied_today_reviewable()
returns integer
language sql
security definer
set search_path = public, pg_temp
as $$
  select count(*)::integer
  from public.sentence_study_progress sp
  join public.memory_sentences ms
    on ms.id = sp.sentence_id
  join public.memories m
    on m.id = ms.memory_id
  where auth.uid() is not null
    and sp.user_id = auth.uid()
    and m.user_id = auth.uid()
    and ms.is_favorite = true
    and sp.last_studied_on = (now() at time zone 'Asia/Shanghai')::date;
$$;

revoke all on function public.count_sentence_studied_today_reviewable() from public;
revoke all on function public.count_sentence_studied_today_reviewable() from anon;
grant execute on function public.count_sentence_studied_today_reviewable() to authenticated;
