create or replace function public.count_sentence_studied_today()
returns integer
language sql
security definer
set search_path = public, pg_temp
as $$
  select count(*)::integer
  from public.sentence_study_progress sp
  where sp.user_id = auth.uid()
    and sp.last_studied_on = (now() at time zone 'Asia/Shanghai')::date;
$$;

revoke all on function public.count_sentence_studied_today() from public;
revoke all on function public.count_sentence_studied_today() from anon;
grant execute on function public.count_sentence_studied_today() to authenticated;
