-- Two independent document vectors. Nullable original vectors allow a valid
-- purpose vector to survive a failure of the original-text embedding request.
alter table public.sentence_embeddings
  alter column embedding drop not null,
  add column if not exists expression_purpose text
    check (expression_purpose is null or char_length(btrim(expression_purpose)) between 1 and 240),
  add column if not exists purpose_embedding real[] check (
    purpose_embedding is null or (
      cardinality(purpose_embedding) = 1024 and array_ndims(purpose_embedding) = 1
      and array_position(purpose_embedding, null) is null
      and not (purpose_embedding && array['NaN'::real, 'Infinity'::real, '-Infinity'::real])
      and purpose_embedding <> array_fill(0::real, array[1024])
    )
  );
alter table public.guest_sentence_embeddings
  alter column embedding drop not null,
  add column if not exists expression_purpose text
    check (expression_purpose is null or char_length(btrim(expression_purpose)) between 1 and 240),
  add column if not exists purpose_embedding real[] check (
    purpose_embedding is null or (
      cardinality(purpose_embedding) = 1024 and array_ndims(purpose_embedding) = 1
      and array_position(purpose_embedding, null) is null
      and not (purpose_embedding && array['NaN'::real, 'Infinity'::real, '-Infinity'::real])
      and purpose_embedding <> array_fill(0::real, array[1024])
    )
  );

create or replace function public.semantic_study_scene_candidates(
  p_scene_id uuid, p_user_id uuid, p_sentence_id uuid default null,
  p_threshold double precision default 0.42
)
returns table (sentence_id uuid, match_score integer, match_source text)
language sql stable security definer set search_path = public, pg_temp as $$
  with scores as (
    select sentence.id,
      public.cosine_similarity_real_arrays(scene_vector.embedding, embedding.embedding) as sentence_similarity,
      case when nullif(btrim(embedding.expression_purpose), '') is not null then
        public.cosine_similarity_real_arrays(scene_vector.embedding, embedding.purpose_embedding)
      end as purpose_similarity
    from public.study_scenes scene
    join public.study_scene_embeddings scene_vector on scene_vector.scene_id = scene.id
      and scene_vector.user_id = p_user_id
    join public.sentence_embeddings embedding on embedding.user_id = p_user_id
      and embedding.model = scene_vector.model
    join public.memory_sentences sentence on sentence.id = embedding.sentence_id
    join public.memories memory on memory.id = sentence.memory_id and memory.user_id = p_user_id
    where scene.id = p_scene_id and scene.user_id = p_user_id and scene.learning_topic_id is null
      and (p_sentence_id is null or sentence.id = p_sentence_id)
  ), eligible as (
    select id,
      case when sentence_similarity between greatest(0.42, coalesce(p_threshold, 0.42)) and 1.000001
        then sentence_similarity end as sentence_score,
      case when purpose_similarity between greatest(0.42, coalesce(p_threshold, 0.42)) and 1.000001
        then purpose_similarity end as purpose_score
    from scores
  )
  select id, least(100, greatest(1, round(greatest(sentence_score, purpose_score) * 100)::integer)),
    case when sentence_score is not null and purpose_score is not null then 'semantic_both'
         when purpose_score is not null then 'purpose_semantic' else 'semantic' end
  from eligible where sentence_score is not null or purpose_score is not null;
$$;

-- Shared by both arrival orders: local memory first, or staged vectors first.
create or replace function public.promote_guest_sentence_embedding_for_id(p_sentence_id uuid)
returns boolean language plpgsql security definer set search_path = public, pg_temp as $$
declare v_owner_id uuid; v_count integer;
begin
  select memory.user_id into v_owner_id
  from public.memory_sentences sentence join public.memories memory on memory.id = sentence.memory_id
  where sentence.id = p_sentence_id;
  if v_owner_id is null then return false; end if;
  insert into public.sentence_embeddings as target (
    sentence_id, user_id, embedding, model, expression_purpose, purpose_embedding, updated_at
  )
  select staged.sentence_id, v_owner_id, staged.embedding, staged.model,
    staged.expression_purpose, staged.purpose_embedding, now()
  from public.guest_sentence_embeddings staged where staged.sentence_id = p_sentence_id
  on conflict (sentence_id) do update set
    user_id = excluded.user_id, embedding = excluded.embedding, model = excluded.model,
    expression_purpose = excluded.expression_purpose, purpose_embedding = excluded.purpose_embedding,
    updated_at = excluded.updated_at;
  get diagnostics v_count = row_count;
  if v_count = 0 then return false; end if;
  delete from public.guest_sentence_embeddings where sentence_id = p_sentence_id;
  perform public.refresh_semantic_study_scene_matches_for_sentence(p_sentence_id, v_owner_id);
  return true;
end;
$$;

create or replace function public.promote_guest_sentence_embedding()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform public.promote_guest_sentence_embedding_for_id(new.id);
  return new;
end;
$$;

create or replace function public.promote_late_guest_sentence_embedding()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform public.promote_guest_sentence_embedding_for_id(new.sentence_id);
  return new;
end;
$$;
drop trigger if exists promote_late_guest_sentence_embedding on public.guest_sentence_embeddings;
create trigger promote_late_guest_sentence_embedding after insert or update on public.guest_sentence_embeddings
for each row execute function public.promote_late_guest_sentence_embedding();

revoke all on function public.promote_guest_sentence_embedding_for_id(uuid) from public, anon, authenticated;
revoke all on function public.promote_late_guest_sentence_embedding() from public, anon, authenticated;
grant execute on function public.promote_guest_sentence_embedding_for_id(uuid) to service_role;

-- Remove category-only links with the new rule, without touching SRS or favorites.
-- Existing query vectors are not regenerated in SQL; resubmitting a theme's name
-- through the updated endpoint replaces its old interpreted query vector.
do $$
declare v_scene record;
begin
  for v_scene in
    select scene.id, scene.user_id from public.study_scenes scene
    join public.study_scene_embeddings embedding on embedding.scene_id = scene.id and embedding.user_id = scene.user_id
    where scene.learning_topic_id is null order by scene.id
  loop
    perform public.refresh_semantic_study_scene_matches_for_owner(v_scene.id, v_scene.user_id);
  end loop;
end;
$$;

-- Old intent/context RPCs and cache remain for rolling-deploy compatibility, but
-- match_scope, category cache and search_description no longer affect admission.
notify pgrst, 'reload schema';
