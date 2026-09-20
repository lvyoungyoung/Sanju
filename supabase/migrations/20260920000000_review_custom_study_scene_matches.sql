-- Similarity only supplies candidates. Custom themes contain AI-approved links.
-- Keep the existing RPC signatures used by creation, generation and guest import.
create table public.study_scene_sentence_reviews (
  scene_id uuid not null references public.study_scenes(id) on delete cascade,
  sentence_id uuid not null references public.memory_sentences(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  input_hash text not null,
  similarity double precision not null check (similarity between -1 and 1),
  status text not null default 'pending' check (status in ('pending', 'accepted', 'rejected')),
  reason text,
  attempts integer not null default 0,
  retry_at timestamptz not null default now(),
  lease_token uuid,
  lease_until timestamptz,
  reviewed_at timestamptz,
  primary key (scene_id, sentence_id)
);
create index study_scene_sentence_reviews_pending_idx
  on public.study_scene_sentence_reviews (user_id, retry_at) where status = 'pending';
alter table public.study_scene_sentence_reviews enable row level security;
revoke all on public.study_scene_sentence_reviews from public, anon, authenticated;

create function public.study_scene_review_input_hash(p_name text, p_english text, p_chinese text)
returns text language sql immutable set search_path = public, pg_temp as $$
  select md5(jsonb_build_array('topic-relevance-v1', p_name, p_english, p_chinese)::text);
$$;

create or replace function public.refresh_semantic_study_scene_matches_for_owner(
  p_scene_id uuid, p_user_id uuid, p_threshold double precision default 0.42
)
returns integer language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_scene record;
  v_count integer;
begin
  select scene.name, embedding.embedding, embedding.model into v_scene
  from public.study_scenes scene
  join public.study_scene_embeddings embedding on embedding.scene_id = scene.id
  where scene.id = p_scene_id and scene.user_id = p_user_id
    and embedding.user_id = p_user_id and scene.learning_topic_id is null
  for update of scene;
  if not found then return 0; end if;

  with scores as materialized (
    select sentence.id, public.study_scene_review_input_hash(v_scene.name, sentence.english, sentence.chinese) as input_hash,
      public.cosine_similarity_real_arrays(v_scene.embedding, embedding.embedding) as similarity
    from public.sentence_embeddings embedding
    join public.memory_sentences sentence on sentence.id = embedding.sentence_id
    join public.memories memory on memory.id = sentence.memory_id
    where embedding.user_id = p_user_id and memory.user_id = p_user_id and embedding.model = v_scene.model
  ), candidates as materialized (
    select * from scores where similarity between greatest(0.42, coalesce(p_threshold, 0.42)) and 1
  ), removed as (
    delete from public.study_scene_sentence_reviews review where review.scene_id = p_scene_id
      and not exists (select 1 from candidates where candidates.id = review.sentence_id)
  )
  insert into public.study_scene_sentence_reviews as review (scene_id, sentence_id, user_id, input_hash, similarity)
  select p_scene_id, candidates.id, p_user_id, candidates.input_hash, candidates.similarity from candidates
  on conflict (scene_id, sentence_id) do update set
    input_hash = excluded.input_hash, similarity = excluded.similarity,
    status = 'pending', reason = null, attempts = 0, retry_at = now(),
    lease_token = null, lease_until = null, reviewed_at = null
  where review.input_hash <> excluded.input_hash;

  -- Refreshing unchanged inputs keeps both positive and negative decisions cached.
  delete from public.study_scene_sentences link where link.scene_id = p_scene_id
    and not exists (select 1 from public.study_scene_sentence_reviews review
      where review.scene_id = link.scene_id and review.sentence_id = link.sentence_id and review.status = 'accepted');
  select count(*)::integer into v_count from public.study_scene_sentences where scene_id = p_scene_id;
  return v_count;
end;
$$;

create or replace function public.refresh_semantic_study_scene_matches_for_sentence(
  p_sentence_id uuid, p_user_id uuid, p_threshold double precision default 0.42
)
returns integer language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_sentence record;
  v_scene record;
  v_similarity double precision;
  v_hash text;
  v_count integer := 0;
begin
  select sentence.english, sentence.chinese, embedding.embedding, embedding.model into v_sentence
  from public.sentence_embeddings embedding
  join public.memory_sentences sentence on sentence.id = embedding.sentence_id
  join public.memories memory on memory.id = sentence.memory_id
  where sentence.id = p_sentence_id and embedding.user_id = p_user_id and memory.user_id = p_user_id;
  if not found then return 0; end if;

  for v_scene in
    select scene.id, scene.name, embedding.embedding, embedding.model
    from public.study_scenes scene
    join public.study_scene_embeddings embedding on embedding.scene_id = scene.id
    where scene.user_id = p_user_id and embedding.user_id = p_user_id and scene.learning_topic_id is null
    order by scene.id for update of scene
  loop
    v_similarity := case when v_scene.model = v_sentence.model then
      public.cosine_similarity_real_arrays(v_scene.embedding, v_sentence.embedding) else null end;
    if coalesce(v_similarity between greatest(0.42, coalesce(p_threshold, 0.42)) and 1, false) then
      v_hash := public.study_scene_review_input_hash(v_scene.name, v_sentence.english, v_sentence.chinese);
      insert into public.study_scene_sentence_reviews as review (scene_id, sentence_id, user_id, input_hash, similarity)
      values (v_scene.id, p_sentence_id, p_user_id, v_hash, v_similarity)
      on conflict (scene_id, sentence_id) do update set
        input_hash = excluded.input_hash, similarity = excluded.similarity,
        status = 'pending', reason = null, attempts = 0, retry_at = now(),
        lease_token = null, lease_until = null, reviewed_at = null
      where review.input_hash <> excluded.input_hash;
    else
      delete from public.study_scene_sentence_reviews where scene_id = v_scene.id and sentence_id = p_sentence_id;
    end if;

    delete from public.study_scene_sentences link
    where link.scene_id = v_scene.id and link.sentence_id = p_sentence_id
      and not exists (select 1 from public.study_scene_sentence_reviews review
        where review.scene_id = link.scene_id and review.sentence_id = link.sentence_id and review.status = 'accepted');
    if exists (select 1 from public.study_scene_sentences where scene_id = v_scene.id and sentence_id = p_sentence_id) then
      v_count := v_count + 1;
    end if;
  end loop;
  return v_count;
end;
$$;

create function public.claim_study_scene_sentence_reviews(p_user_id uuid, p_scene_id uuid default null)
returns table (scene_id uuid, sentence_id uuid, topic text, english text, chinese text, input_hash text, lease_token uuid)
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  -- At most one active batch per user, including across devices/background calls.
  perform pg_advisory_xact_lock(hashtextextended(p_user_id::text, 0));
  if exists (select 1 from public.study_scene_sentence_reviews review
    where review.user_id = p_user_id and review.status = 'pending' and review.lease_until > now()) then
    return;
  end if;

  return query
  with candidates as (
    select review.scene_id, review.sentence_id
    from public.study_scene_sentence_reviews review
    join public.study_scenes scene on scene.id = review.scene_id
    join public.memory_sentences sentence on sentence.id = review.sentence_id
    join public.memories memory on memory.id = sentence.memory_id
    where review.user_id = p_user_id and scene.user_id = p_user_id and memory.user_id = p_user_id
      and scene.learning_topic_id is null and review.status = 'pending'
      and (p_scene_id is null or review.scene_id = p_scene_id)
      and review.retry_at <= now() and (review.lease_until is null or review.lease_until <= now())
    order by review.retry_at, review.similarity desc, review.scene_id, review.sentence_id
    limit 20 for update of review skip locked
  ), claimed as (
    update public.study_scene_sentence_reviews review
    set lease_token = gen_random_uuid(), lease_until = now() + interval '60 seconds', attempts = least(review.attempts + 1, 100)
    from candidates where review.scene_id = candidates.scene_id and review.sentence_id = candidates.sentence_id
    returning review.*
  )
  select claimed.scene_id, claimed.sentence_id, scene.name, sentence.english, sentence.chinese,
         claimed.input_hash, claimed.lease_token
  from claimed
  join public.study_scenes scene on scene.id = claimed.scene_id
  join public.memory_sentences sentence on sentence.id = claimed.sentence_id;
end;
$$;

create function public.complete_study_scene_sentence_reviews(p_user_id uuid, p_decisions jsonb)
returns integer language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_item jsonb;
  v_review record;
  v_current_hash text;
  v_count integer := 0;
begin
  if jsonb_typeof(p_decisions) <> 'array' or jsonb_array_length(p_decisions) > 20 then
    raise exception 'Invalid review decisions';
  end if;
  for v_item in select value from jsonb_array_elements(p_decisions)
  loop
    if jsonb_typeof(v_item -> 'keep') is distinct from 'boolean'
      or nullif(btrim(v_item ->> 'reason'), '') is null then
      raise exception 'Invalid review decision';
    end if;
    -- Lock in the same order as candidate refresh: scene, then review.
    perform 1 from public.study_scenes scene
      where scene.id = (v_item ->> 'scene_id')::uuid and scene.user_id = p_user_id
        and scene.learning_topic_id is null for update;
    if not found then continue; end if;
    select review.* into v_review from public.study_scene_sentence_reviews review
      where review.scene_id = (v_item ->> 'scene_id')::uuid
        and review.sentence_id = (v_item ->> 'sentence_id')::uuid and review.user_id = p_user_id
        and review.status = 'pending' and review.lease_token = (v_item ->> 'lease_token')::uuid
        and review.input_hash = v_item ->> 'input_hash' and review.lease_until > now()
      for update;
    if not found then continue; end if;
    select public.study_scene_review_input_hash(scene.name, sentence.english, sentence.chinese) into v_current_hash
      from public.study_scenes scene, public.memory_sentences sentence
      join public.memories memory on memory.id = sentence.memory_id
      where scene.id = v_review.scene_id and sentence.id = v_review.sentence_id
        and memory.user_id = p_user_id;
    if v_current_hash is distinct from v_review.input_hash then
      update public.study_scene_sentence_reviews set input_hash = coalesce(v_current_hash, input_hash),
        lease_token = null, lease_until = null, retry_at = now(), attempts = 0
        where scene_id = v_review.scene_id and sentence_id = v_review.sentence_id;
      continue;
    end if;
    update public.study_scene_sentence_reviews
      set status = case when (v_item ->> 'keep')::boolean then 'accepted' else 'rejected' end,
          reason = left(v_item ->> 'reason', 240), reviewed_at = now(), lease_token = null, lease_until = null
      where scene_id = v_review.scene_id and sentence_id = v_review.sentence_id;
    if (v_item ->> 'keep')::boolean then
      insert into public.study_scene_sentences (scene_id, sentence_id, match_score, match_source)
      values (v_review.scene_id, v_review.sentence_id,
        least(100, greatest(1, round(v_review.similarity * 100)::integer)), 'ai_review')
      on conflict (scene_id, sentence_id) do update set match_score = excluded.match_score, match_source = excluded.match_source;
    else
      delete from public.study_scene_sentences where scene_id = v_review.scene_id and sentence_id = v_review.sentence_id;
    end if;
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;

create function public.defer_study_scene_sentence_reviews(p_user_id uuid, p_claims jsonb)
returns void language sql security definer set search_path = public, pg_temp as $$
  update public.study_scene_sentence_reviews review
  set lease_token = null, lease_until = null,
      retry_at = now() + make_interval(secs => least(3600, 30 * power(2, least(review.attempts - 1, 7)))::integer)
  from jsonb_to_recordset(p_claims) as claim(scene_id uuid, sentence_id uuid, lease_token uuid)
  where review.user_id = p_user_id and review.scene_id = claim.scene_id and review.sentence_id = claim.sentence_id
    and review.status = 'pending' and review.lease_token = claim.lease_token;
$$;

create function public.get_study_scene_review_status(p_user_id uuid, p_scene_id uuid default null)
returns table (pending_count integer, retry_after_seconds integer)
language sql security definer set search_path = public, pg_temp as $$
  select count(*)::integer, coalesce(greatest(1, min(case when review.lease_until > now() then 2
    else ceil(extract(epoch from review.retry_at - now()))::integer end)), 0)
  from public.study_scene_sentence_reviews review
  join public.study_scenes scene on scene.id = review.scene_id
  where review.user_id = p_user_id and scene.user_id = p_user_id and scene.learning_topic_id is null
    and review.status = 'pending' and (p_scene_id is null or review.scene_id = p_scene_id);
$$;

-- Remove unverified legacy links without touching sentences, favorites or SRS.
delete from public.study_scene_sentences link using public.study_scenes scene
where scene.id = link.scene_id and scene.learning_topic_id is null;
do $$
declare v_scene record;
begin
  for v_scene in select id, user_id from public.study_scenes where learning_topic_id is null order by id loop
    perform public.refresh_semantic_study_scene_matches_for_owner(v_scene.id, v_scene.user_id);
  end loop;
end;
$$;

revoke all on function public.study_scene_review_input_hash(text, text, text) from public, anon, authenticated;
revoke all on function public.refresh_semantic_study_scene_matches_for_owner(uuid, uuid, double precision) from public, anon, authenticated;
revoke all on function public.refresh_semantic_study_scene_matches_for_sentence(uuid, uuid, double precision) from public, anon, authenticated;
revoke all on function public.claim_study_scene_sentence_reviews(uuid, uuid) from public, anon, authenticated;
revoke all on function public.complete_study_scene_sentence_reviews(uuid, jsonb) from public, anon, authenticated;
revoke all on function public.defer_study_scene_sentence_reviews(uuid, jsonb) from public, anon, authenticated;
revoke all on function public.get_study_scene_review_status(uuid, uuid) from public, anon, authenticated;
grant execute on function public.refresh_semantic_study_scene_matches_for_sentence(uuid, uuid, double precision) to service_role;
grant execute on function public.claim_study_scene_sentence_reviews(uuid, uuid) to service_role;
grant execute on function public.complete_study_scene_sentence_reviews(uuid, jsonb) to service_role;
grant execute on function public.defer_study_scene_sentence_reviews(uuid, jsonb) to service_role;
grant execute on function public.get_study_scene_review_status(uuid, uuid) to service_role;
