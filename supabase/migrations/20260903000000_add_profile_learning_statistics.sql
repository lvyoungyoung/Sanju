-- Count distinct sentences that have reached the mastered threshold in any study scope.
create or replace function public.count_mastered_sentences()
returns integer
language sql
security definer
set search_path = public, pg_temp
as $$
  select count(distinct progress.sentence_id)::integer
  from public.sentence_study_progress as progress
  join public.memory_sentences as sentence on sentence.id = progress.sentence_id
  join public.memories as memory on memory.id = sentence.memory_id
  where auth.uid() is not null
    and progress.user_id = auth.uid()
    and memory.user_id = auth.uid()
    and progress.correct_count >= 5;
$$;

revoke all on function public.count_mastered_sentences() from public, anon;
grant execute on function public.count_mastered_sentences() to authenticated;
