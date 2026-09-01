-- Sentence-level learning topics replace the free-form scene hint. Topic scenes
-- match exactly; manually named scenes continue to use semantic embeddings.

alter table public.memory_sentences
  add column if not exists learning_topic_ids text[] not null default '{}'::text[];

alter table public.memory_sentences
  drop constraint if exists memory_sentences_learning_topic_ids_check;

alter table public.memory_sentences
  add constraint memory_sentences_learning_topic_ids_check
  check (
    cardinality(learning_topic_ids) <= 2
    and learning_topic_ids <@ array[
      'daily_life', 'home_and_family', 'clothing_and_shopping', 'health_and_wellbeing',
      'feelings_and_emotions', 'hobbies_and_leisure', 'sports_and_fitness', 'social_relationships',
      'school_and_learning', 'work_and_career', 'food_and_cooking', 'eating_out',
      'services_and_consumer_life', 'celebrations_and_events', 'culture_and_arts',
      'media_and_entertainment', 'technology_and_online_life', 'news_and_public_information',
      'transportation', 'travel_and_holidays', 'cities_and_architecture',
      'community_and_public_places', 'weather_and_seasons', 'nature_and_landscapes',
      'animals_and_pets', 'plants_and_gardens', 'environment_and_sustainability',
      'people_and_activities'
    ]::text[]
  );

create index if not exists memory_sentences_learning_topic_ids_idx
  on public.memory_sentences using gin (learning_topic_ids);

alter table public.study_scenes
  add column if not exists learning_topic_id text;

alter table public.study_scenes
  drop constraint if exists study_scenes_learning_topic_id_check;

alter table public.study_scenes
  add constraint study_scenes_learning_topic_id_check
  check (
    learning_topic_id is null
    or learning_topic_id = any (array[
      'daily_life', 'home_and_family', 'clothing_and_shopping', 'health_and_wellbeing',
      'feelings_and_emotions', 'hobbies_and_leisure', 'sports_and_fitness', 'social_relationships',
      'school_and_learning', 'work_and_career', 'food_and_cooking', 'eating_out',
      'services_and_consumer_life', 'celebrations_and_events', 'culture_and_arts',
      'media_and_entertainment', 'technology_and_online_life', 'news_and_public_information',
      'transportation', 'travel_and_holidays', 'cities_and_architecture',
      'community_and_public_places', 'weather_and_seasons', 'nature_and_landscapes',
      'animals_and_pets', 'plants_and_gardens', 'environment_and_sustainability',
      'people_and_activities'
    ]::text[])
  );

create index if not exists study_scenes_user_learning_topic_idx
  on public.study_scenes (user_id, learning_topic_id)
  where learning_topic_id is not null;

create or replace function public.learning_topic_ids_from_json(p_value jsonb)
returns text[]
language sql
immutable
set search_path = public, pg_temp
as $$
  select coalesce(
    array(
      select topic_id
      from (
        select distinct on (items.value) items.value as topic_id, items.ordinality
        from jsonb_array_elements_text(
          case when jsonb_typeof(p_value) = 'array' then p_value else '[]'::jsonb end
        ) with ordinality as items(value, ordinality)
        where items.value = any (array[
          'daily_life', 'home_and_family', 'clothing_and_shopping', 'health_and_wellbeing',
          'feelings_and_emotions', 'hobbies_and_leisure', 'sports_and_fitness', 'social_relationships',
          'school_and_learning', 'work_and_career', 'food_and_cooking', 'eating_out',
          'services_and_consumer_life', 'celebrations_and_events', 'culture_and_arts',
          'media_and_entertainment', 'technology_and_online_life', 'news_and_public_information',
          'transportation', 'travel_and_holidays', 'cities_and_architecture',
          'community_and_public_places', 'weather_and_seasons', 'nature_and_landscapes',
          'animals_and_pets', 'plants_and_gardens', 'environment_and_sustainability',
          'people_and_activities'
        ]::text[])
        order by items.value, items.ordinality
      ) as unique_topics
      order by ordinality
      limit 2
    ),
    '{}'::text[]
  );
$$;

create or replace function public.refresh_learning_topic_study_scene_matches_for_owner(
  p_scene_id uuid,
  p_user_id uuid
)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_topic_id text;
  v_count integer := 0;
begin
  select learning_topic_id into v_topic_id
  from public.study_scenes
  where id = p_scene_id and user_id = p_user_id;

  if v_topic_id is null then
    return 0;
  end if;

  delete from public.study_scene_sentences where scene_id = p_scene_id;

  insert into public.study_scene_sentences (scene_id, sentence_id, match_score, match_source)
  select p_scene_id, sentence.id, 100, 'learning_topic'
  from public.memory_sentences as sentence
  join public.memories as memory on memory.id = sentence.memory_id
  where memory.user_id = p_user_id
    and v_topic_id = any(sentence.learning_topic_ids);

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

create or replace function public.match_sentence_to_learning_topic_study_scenes()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user_id uuid;
begin
  if cardinality(new.learning_topic_ids) = 0 then
    return new;
  end if;

  select user_id into v_user_id from public.memories where id = new.memory_id;
  if v_user_id is null then
    return new;
  end if;

  insert into public.study_scene_sentences (scene_id, sentence_id, match_score, match_source)
  select scene.id, new.id, 100, 'learning_topic'
  from public.study_scenes as scene
  where scene.user_id = v_user_id
    and scene.learning_topic_id = any(new.learning_topic_ids)
  on conflict (scene_id, sentence_id) do update
    set match_score = excluded.match_score,
        match_source = excluded.match_source;

  return new;
end;
$$;

drop trigger if exists match_sentence_to_learning_topic_study_scenes_trigger
  on public.memory_sentences;

create trigger match_sentence_to_learning_topic_study_scenes_trigger
after insert on public.memory_sentences
for each row execute function public.match_sentence_to_learning_topic_study_scenes();

-- Semantic scenes must never remove exact topic links when a new sentence is
-- embedded. They only operate on scenes without a controlled topic ID.
create or replace function public.refresh_semantic_study_scene_matches_for_owner(
  p_scene_id uuid,
  p_user_id uuid,
  p_threshold double precision default 0.42
)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_embedding real[];
  v_learning_topic_id text;
  v_count integer := 0;
begin
  select scene.learning_topic_id, embedding.embedding
    into v_learning_topic_id, v_embedding
  from public.study_scenes as scene
  left join public.study_scene_embeddings as embedding
    on embedding.scene_id = scene.id and embedding.user_id = p_user_id
  where scene.id = p_scene_id and scene.user_id = p_user_id;

  if v_learning_topic_id is not null or v_embedding is null then
    return 0;
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
    where embedding.user_id = p_user_id and memory.user_id = p_user_id
  ) as matches
  where matches.similarity >= p_threshold;

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

create or replace function public.refresh_semantic_study_scene_matches_for_sentence(
  p_sentence_id uuid,
  p_user_id uuid,
  p_threshold double precision default 0.42
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
  where sentence_id = p_sentence_id and user_id = p_user_id;

  if v_embedding is null then
    return 0;
  end if;

  delete from public.study_scene_sentences as link
  using public.study_scenes as scene
  where link.scene_id = scene.id
    and scene.user_id = p_user_id
    and scene.learning_topic_id is null
    and link.sentence_id = p_sentence_id;

  insert into public.study_scene_sentences (scene_id, sentence_id, match_score, match_source)
  select scene.id, p_sentence_id,
         least(100, greatest(1, round(public.cosine_similarity_real_arrays(scene_embedding.embedding, v_embedding) * 100)::integer)),
         'semantic'
  from public.study_scenes as scene
  join public.study_scene_embeddings as scene_embedding
    on scene_embedding.scene_id = scene.id and scene_embedding.user_id = p_user_id
  where scene.user_id = p_user_id
    and scene.learning_topic_id is null
    and public.cosine_similarity_real_arrays(scene_embedding.embedding, v_embedding) >= p_threshold;

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

create or replace function public.create_learning_topic_study_scene(
  p_user_id uuid,
  p_name text,
  p_learning_topic_id text
)
returns table (
  id uuid,
  name text,
  cover_memory_id uuid,
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
begin
  if char_length(v_name) < 2 or char_length(v_name) > 24 then
    raise exception 'Study scene name must be between 2 and 24 characters';
  end if;
  if p_learning_topic_id is null or not (p_learning_topic_id = any (array[
    'daily_life', 'home_and_family', 'clothing_and_shopping', 'health_and_wellbeing',
    'feelings_and_emotions', 'hobbies_and_leisure', 'sports_and_fitness', 'social_relationships',
    'school_and_learning', 'work_and_career', 'food_and_cooking', 'eating_out',
    'services_and_consumer_life', 'celebrations_and_events', 'culture_and_arts',
    'media_and_entertainment', 'technology_and_online_life', 'news_and_public_information',
    'transportation', 'travel_and_holidays', 'cities_and_architecture',
    'community_and_public_places', 'weather_and_seasons', 'nature_and_landscapes',
    'animals_and_pets', 'plants_and_gardens', 'environment_and_sustainability',
    'people_and_activities'
  ]::text[])) then
    raise exception 'Invalid learning topic';
  end if;

  insert into public.study_scenes as scene (user_id, name, learning_topic_id)
  values (p_user_id, v_name, p_learning_topic_id)
  on conflict on constraint study_scenes_user_id_name_key do update
    set learning_topic_id = excluded.learning_topic_id,
        updated_at = now()
  returning scene.id into v_scene_id;

  delete from public.study_scene_embeddings where scene_id = v_scene_id;
  perform public.refresh_learning_topic_study_scene_matches_for_owner(v_scene_id, p_user_id);

  return query
  select * from public.get_study_scene_summary_for_owner(p_user_id, v_scene_id);
end;
$$;

-- Keep creation, memory insertion, topic assignment and credit deduction in
-- one transaction for authenticated users.
create or replace function public.finalize_authenticated_generation(
  p_user_id uuid,
  p_memory_id uuid,
  p_client_request_id uuid,
  p_image_path text,
  p_created_at timestamptz,
  p_provider text,
  p_sentences jsonb,
  p_tags text[]
)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  current_balance integer := 0;
  remaining_balance integer := 0;
  generation_job record;
  sentence_item record;
begin
  if p_sentences is null or jsonb_typeof(p_sentences) <> 'array'
     or jsonb_array_length(p_sentences) not in (3, 6) then
    raise exception 'invalid sentences';
  end if;

  if p_client_request_id is not null then
    insert into public.generation_jobs (client_request_id, user_id, status, updated_at)
    values (p_client_request_id, p_user_id, 'pending', timezone('utc', now()))
    on conflict (client_request_id) do nothing;

    select * into generation_job
    from public.generation_jobs
    where client_request_id = p_client_request_id and user_id = p_user_id
    for update;

    if not found then raise exception 'generation job not found'; end if;
    if generation_job.status = 'completed' then
      return coalesce(generation_job.remaining_credits, (select available_generations from public.profiles where id = p_user_id));
    end if;
    if generation_job.status = 'failed' then raise exception 'generation job already failed'; end if;
  end if;

  select available_generations into current_balance
  from public.profiles where id = p_user_id for update;
  if not found then raise exception 'profile not found'; end if;
  if exists (select 1 from public.memories where id = p_memory_id and user_id = p_user_id) then
    return current_balance;
  end if;
  if coalesce(current_balance, 0) <= 0 then raise exception 'No credits left'; end if;

  remaining_balance := current_balance - 1;
  insert into public.memories (id, user_id, image_url, created_at, provider, tags)
  values (
    p_memory_id, p_user_id, p_image_path, coalesce(p_created_at, timezone('utc', now())), p_provider,
    coalesce(array(
      select tag from (
        select distinct on (tag) tag, position
        from unnest(coalesce(p_tags, '{}'::text[])) with ordinality as input(tag, position)
        where tag = any (array['人物','风景','旅行','美食','生活场景','动物','植物','建筑','活动','物品','截图/信息'])
        order by tag, position
      ) as unique_tags order by position limit 3
    ), '{}'::text[])
  );

  for sentence_item in select value, ordinality from jsonb_array_elements(p_sentences) with ordinality loop
    insert into public.memory_sentences (
      id, memory_id, sort_order, english, chinese, learning_topic_ids, presentation_group, is_favorite
    ) values (
      case when nullif(sentence_item.value ->> 'id', '') is null then gen_random_uuid() else (sentence_item.value ->> 'id')::uuid end,
      p_memory_id,
      sentence_item.ordinality - 1,
      btrim(sentence_item.value ->> 'english'),
      btrim(sentence_item.value ->> 'chinese'),
      public.learning_topic_ids_from_json(sentence_item.value -> 'learning_topic_ids'),
      case when sentence_item.value ->> 'presentation_group' = 'what_i_say' then 'what_i_say' else 'what_i_see' end,
      coalesce((sentence_item.value ->> 'is_favorite')::boolean, false)
    );
  end loop;

  update public.profiles set available_generations = remaining_balance where id = p_user_id;
  if to_regclass('public.generation_transactions') is not null then
    insert into public.generation_transactions (user_id, delta, balance_after, reason, note)
    values (p_user_id, -1, remaining_balance, 'generate', 'memory_id:' || p_memory_id::text);
  end if;
  if p_client_request_id is not null then
    update public.generation_jobs set
      status = 'completed', memory_id = p_memory_id, image_path = p_image_path,
      provider = p_provider, remaining_credits = remaining_balance, error_message = null,
      updated_at = timezone('utc', now()), completed_at = coalesce(completed_at, timezone('utc', now())), failed_at = null
    where client_request_id = p_client_request_id and user_id = p_user_id;
  end if;
  return remaining_balance;
end;
$$;

create or replace function public.finalize_guest_generation(
  p_user_id uuid,
  p_guest_job_id uuid,
  p_completed_at timestamptz,
  p_provider text,
  p_sentences jsonb,
  p_tags text[]
)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  current_balance integer := 0;
  remaining_balance integer := 0;
  guest_job record;
begin
  if p_sentences is null or jsonb_typeof(p_sentences) <> 'array'
     or jsonb_array_length(p_sentences) not in (3, 6) then
    raise exception 'invalid sentences';
  end if;
  select * into guest_job from public.guest_generation_jobs
  where id = p_guest_job_id and user_id = p_user_id for update;
  if not found then raise exception 'guest generation job not found'; end if;
  if guest_job.status in ('completed', 'acknowledged') then
    return coalesce(guest_job.remaining_credits, (select available_generations from public.profiles where id = p_user_id));
  end if;
  if guest_job.status = 'failed' then raise exception 'guest generation job already failed'; end if;
  select available_generations into current_balance from public.profiles where id = p_user_id for update;
  if not found then raise exception 'profile not found'; end if;
  if coalesce(current_balance, 0) <= 0 then raise exception 'No credits left'; end if;

  remaining_balance := current_balance - 1;
  update public.profiles set available_generations = remaining_balance where id = p_user_id;
  update public.guest_generation_jobs set
    status = 'completed', completed_at = coalesce(p_completed_at, timezone('utc', now())),
    provider = p_provider, sentences = p_sentences,
    tags = coalesce(array(
      select tag from (
        select distinct on (tag) tag, position
        from unnest(coalesce(p_tags, '{}'::text[])) with ordinality as input(tag, position)
        where tag = any (array['人物','风景','旅行','美食','生活场景','动物','植物','建筑','活动','物品','截图/信息'])
        order by tag, position
      ) as unique_tags order by position limit 3
    ), '{}'::text[]),
    remaining_credits = remaining_balance, error_message = null
  where id = p_guest_job_id and user_id = p_user_id;
  if to_regclass('public.generation_transactions') is not null then
    insert into public.generation_transactions (user_id, delta, balance_after, reason, note)
    values (p_user_id, -1, remaining_balance, 'generate', 'guest_job_id:' || p_guest_job_id::text);
  end if;
  return remaining_balance;
end;
$$;

alter table public.memory_sentences
  drop constraint if exists memory_sentences_scene_hint_length_check;

alter table public.memory_sentences
  drop column if exists scene_hint;

revoke all on function public.learning_topic_ids_from_json(jsonb) from public, anon, authenticated;
revoke all on function public.refresh_learning_topic_study_scene_matches_for_owner(uuid, uuid) from public, anon, authenticated;
revoke all on function public.match_sentence_to_learning_topic_study_scenes() from public, anon, authenticated;
revoke all on function public.create_learning_topic_study_scene(uuid, text, text) from public, anon, authenticated;
revoke all on function public.refresh_semantic_study_scene_matches_for_owner(uuid, uuid, double precision) from public, anon, authenticated;
revoke all on function public.refresh_semantic_study_scene_matches_for_sentence(uuid, uuid, double precision) from public, anon, authenticated;
revoke all on function public.finalize_authenticated_generation(uuid, uuid, uuid, text, timestamptz, text, jsonb, text[]) from public, anon, authenticated;
revoke all on function public.finalize_guest_generation(uuid, uuid, timestamptz, text, jsonb, text[]) from public, anon, authenticated;

grant execute on function public.create_learning_topic_study_scene(uuid, text, text) to service_role;
grant execute on function public.refresh_semantic_study_scene_matches_for_sentence(uuid, uuid, double precision) to service_role;
grant execute on function public.finalize_authenticated_generation(uuid, uuid, uuid, text, timestamptz, text, jsonb, text[]) to service_role;
grant execute on function public.finalize_guest_generation(uuid, uuid, timestamptz, text, jsonb, text[]) to service_role;
