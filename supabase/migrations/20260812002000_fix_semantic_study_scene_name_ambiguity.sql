-- `name` is also an OUT parameter of this function. Use the named unique
-- constraint so PostgreSQL never interprets it as an ambiguous PL/pgSQL value.
create or replace function public.create_study_scene_with_embedding(
  p_user_id uuid,
  p_name text,
  p_embedding jsonb,
  p_model text default 'qwen3.7-text-embedding'
)
returns table (
  id uuid,
  name text,
  total_count integer,
  due_count integer,
  studied_count integer,
  reviewable_today_count integer,
  mastery_score integer
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_name text := btrim(coalesce(p_name, ''));
  v_scene_id uuid;
  v_embedding real[] := public.jsonb_to_embedding_real_array(p_embedding);
begin
  if char_length(v_name) < 2 or char_length(v_name) > 24 then
    raise exception 'Study scene name must be between 2 and 24 characters';
  end if;
  if cardinality(v_embedding) <> 1024 then
    raise exception 'Invalid study scene embedding';
  end if;

  insert into public.study_scenes as scene (user_id, name)
  values (p_user_id, v_name)
  on conflict on constraint study_scenes_user_id_name_key do update
    set updated_at = now()
  returning scene.id into v_scene_id;

  insert into public.study_scene_embeddings as scene_embedding (scene_id, user_id, embedding, model)
  values (v_scene_id, p_user_id, v_embedding, coalesce(nullif(btrim(p_model), ''), 'qwen3.7-text-embedding'))
  on conflict (scene_id) do update set
    embedding = excluded.embedding,
    model = excluded.model,
    updated_at = now();

  perform public.refresh_semantic_study_scene_matches_for_owner(v_scene_id, p_user_id);

  return query
  select * from public.get_study_scene_summary_for_owner(p_user_id, v_scene_id);
end;
$$;

revoke all on function public.create_study_scene_with_embedding(uuid, text, jsonb, text) from public, anon, authenticated;
grant execute on function public.create_study_scene_with_embedding(uuid, text, jsonb, text) to service_role;
