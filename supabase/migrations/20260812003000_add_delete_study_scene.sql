-- Delete only a user-created scene and its scene-specific study progress.
-- The scene's sentence links and embedding are removed automatically by their
-- foreign-key cascades; memories and source sentences are deliberately kept.
create or replace function public.delete_study_scene(p_scene_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user_id uuid := auth.uid();
begin
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;

  if not exists (
    select 1
    from public.study_scenes as scene
    where scene.id = p_scene_id
      and scene.user_id = v_user_id
  ) then
    raise exception 'Study scene not found';
  end if;

  delete from public.sentence_study_progress as progress
  where progress.user_id = v_user_id
    and progress.study_scope = 'scene:' || p_scene_id::text;

  delete from public.study_scenes as scene
  where scene.id = p_scene_id
    and scene.user_id = v_user_id;
end;
$$;

revoke all on function public.delete_study_scene(uuid) from public, anon;
grant execute on function public.delete_study_scene(uuid) to authenticated;
