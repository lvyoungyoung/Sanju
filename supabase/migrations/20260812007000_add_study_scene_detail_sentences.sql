-- A scene detail page needs every matched sentence, not just the subset that
-- happens to be due today. Learning still uses the existing queue RPCs.
create or replace function public.get_study_scene_detail_sentences(
  p_scene_id uuid,
  p_limit integer default 1000
)
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
    sentence.id,
    sentence.memory_id,
    sentence.english,
    sentence.chinese,
    memory.image_url,
    memory.created_at,
    coalesce(progress.learning_step, 0),
    coalesce(progress.mastered_review_count, 0),
    coalesce(progress.correct_count, 0),
    coalesce(progress.wrong_count, 0),
    progress.last_result,
    progress.next_review_at
  from public.study_scenes as scene
  join public.study_scene_sentences as link on link.scene_id = scene.id
  join public.memory_sentences as sentence on sentence.id = link.sentence_id
  join public.memories as memory on memory.id = sentence.memory_id
  left join public.sentence_study_progress as progress
    on progress.sentence_id = sentence.id
   and progress.user_id = auth.uid()
   and progress.study_scope = 'scene:' || scene.id::text
  where auth.uid() is not null
    and scene.id = p_scene_id
    and scene.user_id = auth.uid()
    and memory.user_id = auth.uid()
  order by memory.created_at desc, sentence.sort_order asc
  limit least(greatest(coalesce(p_limit, 1000), 1), 1000);
$$;

revoke all on function public.get_study_scene_detail_sentences(uuid, integer) from public, anon;
grant execute on function public.get_study_scene_detail_sentences(uuid, integer) to authenticated;
