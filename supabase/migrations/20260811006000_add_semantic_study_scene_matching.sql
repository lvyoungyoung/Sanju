-- User-created scenes are matched semantically.  We deliberately store plain
-- REAL arrays for the first version: it keeps deployment independent from a
-- vector extension/index while the amount of per-user content is still small.

drop trigger if exists match_sentence_to_user_study_scenes_trigger on public.memory_sentences;

create table if not exists public.sentence_embeddings (
  sentence_id uuid primary key references public.memory_sentences(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  embedding real[] not null check (cardinality(embedding) = 1024),
  model text not null default 'qwen3.7-text-embedding',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.study_scene_embeddings (
  scene_id uuid primary key references public.study_scenes(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  embedding real[] not null check (cardinality(embedding) = 1024),
  model text not null default 'qwen3.7-text-embedding',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists sentence_embeddings_user_id_idx
  on public.sentence_embeddings (user_id);

alter table public.sentence_embeddings enable row level security;
alter table public.study_scene_embeddings enable row level security;

-- Only service-role Edge Functions write these vectors.  Clients never need
-- the raw embeddings, so intentionally do not add client-facing policies.

create or replace function public.cosine_similarity_real_arrays(
  p_left real[],
  p_right real[]
)
returns double precision
language sql
immutable
strict
set search_path = public, pg_temp
as $$
  with components as (
    select left_value::double precision, right_value::double precision
    from unnest(p_left, p_right) as pairs(left_value, right_value)
  )
  select case
    when cardinality(p_left) <> cardinality(p_right)
      or cardinality(p_left) = 0 then null
    when sqrt(sum(left_value * left_value)) = 0
      or sqrt(sum(right_value * right_value)) = 0 then null
    else sum(left_value * right_value)
      / (sqrt(sum(left_value * left_value)) * sqrt(sum(right_value * right_value)))
  end
  from components;
$$;

create or replace function public.jsonb_to_embedding_real_array(p_embedding jsonb)
returns real[]
language sql
immutable
strict
set search_path = public, pg_temp
as $$
  select array_agg(value::real order by ordinality)
  from jsonb_array_elements_text(p_embedding) with ordinality as items(value, ordinality);
$$;

create or replace function public.get_study_scene_summary_for_owner(
  p_user_id uuid,
  p_scene_id uuid
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
language sql
security definer
set search_path = public, pg_temp
as $$
  with scene_sentences as (
    select
      scene.id,
      scene.name,
      link.sentence_id,
      progress.id as progress_id,
      coalesce(progress.correct_count, 0) as correct_count,
      progress.next_review_at,
      progress.last_studied_on
    from public.study_scenes as scene
    left join public.study_scene_sentences as link on link.scene_id = scene.id
    left join public.sentence_study_progress as progress
      on progress.sentence_id = link.sentence_id
     and progress.user_id = p_user_id
     and progress.study_scope = 'scene:' || scene.id::text
    where scene.id = p_scene_id
      and scene.user_id = p_user_id
  )
  select
    scene_sentences.id,
    scene_sentences.name,
    count(scene_sentences.sentence_id)::integer,
    count(scene_sentences.sentence_id) filter (
      where (scene_sentences.last_studied_on is null or scene_sentences.last_studied_on < (now() at time zone 'Asia/Shanghai')::date)
        and (scene_sentences.progress_id is null or (scene_sentences.next_review_at at time zone 'Asia/Shanghai')::date <= (now() at time zone 'Asia/Shanghai')::date)
    )::integer,
    count(scene_sentences.sentence_id) filter (where scene_sentences.correct_count > 0)::integer,
    count(scene_sentences.sentence_id) filter (where scene_sentences.last_studied_on = (now() at time zone 'Asia/Shanghai')::date)::integer,
    coalesce(round(avg(case
      when scene_sentences.correct_count <= 0 then 0
      when scene_sentences.correct_count <= 2 then 40
      when scene_sentences.correct_count <= 4 then 70
      else 100
    end))::integer, 0)
  from scene_sentences
  group by scene_sentences.id, scene_sentences.name;
$$;

create or replace function public.refresh_semantic_study_scene_matches_for_owner(
  p_scene_id uuid,
  p_user_id uuid,
  p_threshold double precision default 0.55
)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_embedding real[];
  v_count integer := 0;
begin
  select embedding into v_embedding
  from public.study_scene_embeddings
  where scene_id = p_scene_id
    and user_id = p_user_id;

  if v_embedding is null then
    raise exception 'Study scene embedding not found';
  end if;

  delete from public.study_scene_sentences where scene_id = p_scene_id;

  insert into public.study_scene_sentences (scene_id, sentence_id, match_score, match_source)
  select p_scene_id, matches.sentence_id,
         least(100, greatest(1, round(matches.similarity * 100)::integer)),
         'semantic'
  from (
    select embedding.sentence_id,
           public.cosine_similarity_real_arrays(v_embedding, embedding.embedding) as similarity
    from public.sentence_embeddings as embedding
    join public.memory_sentences as sentence on sentence.id = embedding.sentence_id
    join public.memories as memory on memory.id = sentence.memory_id
    where embedding.user_id = p_user_id
      and memory.user_id = p_user_id
  ) as matches
  where matches.similarity >= p_threshold;

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

create or replace function public.refresh_semantic_study_scene_matches_for_sentence(
  p_sentence_id uuid,
  p_user_id uuid,
  p_threshold double precision default 0.55
)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_embedding real[];
  v_count integer := 0;
begin
  select embedding into v_embedding
  from public.sentence_embeddings
  where sentence_id = p_sentence_id
    and user_id = p_user_id;

  if v_embedding is null then
    return 0;
  end if;

  delete from public.study_scene_sentences as link
  using public.study_scenes as scene
  where link.scene_id = scene.id
    and scene.user_id = p_user_id
    and link.sentence_id = p_sentence_id;

  insert into public.study_scene_sentences (scene_id, sentence_id, match_score, match_source)
  select scene.id, p_sentence_id,
         least(100, greatest(1, round(public.cosine_similarity_real_arrays(scene_embedding.embedding, v_embedding) * 100)::integer)),
         'semantic'
  from public.study_scenes as scene
  join public.study_scene_embeddings as scene_embedding on scene_embedding.scene_id = scene.id
  where scene.user_id = p_user_id
    and scene_embedding.user_id = p_user_id
    and public.cosine_similarity_real_arrays(scene_embedding.embedding, v_embedding) >= p_threshold;

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

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
  on conflict on constraint study_scenes_user_id_name_key do update set updated_at = now()
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

revoke all on function public.cosine_similarity_real_arrays(real[], real[]) from public, anon, authenticated;
revoke all on function public.jsonb_to_embedding_real_array(jsonb) from public, anon, authenticated;
revoke all on function public.get_study_scene_summary_for_owner(uuid, uuid) from public, anon, authenticated;
revoke all on function public.refresh_semantic_study_scene_matches_for_owner(uuid, uuid, double precision) from public, anon, authenticated;
revoke all on function public.refresh_semantic_study_scene_matches_for_sentence(uuid, uuid, double precision) from public, anon, authenticated;
revoke all on function public.create_study_scene_with_embedding(uuid, text, jsonb, text) from public, anon, authenticated;
grant execute on function public.create_study_scene_with_embedding(uuid, text, jsonb, text) to service_role;
grant execute on function public.refresh_semantic_study_scene_matches_for_sentence(uuid, uuid, double precision) to service_role;
