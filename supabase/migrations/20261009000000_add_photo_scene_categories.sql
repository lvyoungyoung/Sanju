-- Photo categories use the existing ordered tags array: primary first, then up
-- to two secondary categories. No sentence topics or existing data are rewritten.
create or replace function public.normalize_memory_photo_categories(p_tags text[])
returns text[]
language sql
immutable
set search_path = public, pg_temp
as $$
  select coalesce(array(
    select tag from (
      select btrim(tag) as tag, min(position) as position
      from unnest(coalesce(p_tags, '{}'::text[])) with ordinality as input(tag, position)
      where btrim(tag) = any (array[
        'people_and_portraits', 'food_and_drinks', 'restaurants_and_cafes',
        'pets_and_animals', 'flowers_and_plants', 'natural_scenery',
        'cities_and_architecture', 'home_life', 'work_and_office',
        'school_and_study', 'sports_and_outdoors', 'parties_and_celebrations',
        'culture_and_entertainment', 'transportation', 'clothing_and_style',
        'objects_and_details', 'screenshots_and_documents'
      ]::text[])
      group by btrim(tag)
    ) as unique_tags order by position limit 3
  ), '{}'::text[]);
$$;

-- Keep the existing signatures, locks, idempotency and enrichment enqueueing.
-- The only change to finalization is photo tag normalization.
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
    public.normalize_memory_photo_categories(p_tags)
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
  insert into public.generation_enrichment_jobs(user_id, memory_id, sentences)
  select p_user_id, p_memory_id, jsonb_agg(jsonb_build_object(
    'id', s.id, 'english', s.english, 'chinese', s.chinese,
    'learning_topic_ids', s.learning_topic_ids,
    'expression_purpose', input.value->>'expression_purpose') order by s.sort_order)
  from public.memory_sentences s
  join jsonb_array_elements(p_sentences) with ordinality input(value, position)
    on s.sort_order = input.position - 1
  where s.memory_id = p_memory_id;
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
    tags = public.normalize_memory_photo_categories(p_tags),
    remaining_credits = remaining_balance, error_message = null
  where id = p_guest_job_id and user_id = p_user_id;
  if to_regclass('public.generation_transactions') is not null then
    insert into public.generation_transactions (user_id, delta, balance_after, reason, note)
    values (p_user_id, -1, remaining_balance, 'generate', 'guest_job_id:' || p_guest_job_id::text);
  end if;
  insert into public.generation_enrichment_jobs(user_id, guest_job_id, sentences)
  values (p_user_id, p_guest_job_id, p_sentences);
  return remaining_balance;
end;
$$;

revoke all on function public.normalize_memory_photo_categories(text[]) from public, anon, authenticated;
grant execute on function public.normalize_memory_photo_categories(text[]) to service_role;
revoke all on function public.finalize_authenticated_generation(uuid, uuid, uuid, text, timestamptz, text, jsonb, text[]) from public, anon, authenticated;
revoke all on function public.finalize_guest_generation(uuid, uuid, timestamptz, text, jsonb, text[]) from public, anon, authenticated;
grant execute on function public.finalize_authenticated_generation(uuid, uuid, uuid, text, timestamptz, text, jsonb, text[]) to service_role;
grant execute on function public.finalize_guest_generation(uuid, uuid, timestamptz, text, jsonb, text[]) to service_role;
notify pgrst, 'reload schema';
