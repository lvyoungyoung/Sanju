-- Six-sentence memories need positions 0 through 5. Keep the original
-- zero-based convention so existing three-sentence clients stay unchanged.
alter table public.memory_sentences
  drop constraint if exists memory_sentences_sort_order_check;

alter table public.memory_sentences
  add constraint memory_sentences_sort_order_check
  check (sort_order >= 0 and sort_order < 6);

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
  if p_sentences is null
     or jsonb_typeof(p_sentences) <> 'array'
     or jsonb_array_length(p_sentences) not in (3, 6) then
    raise exception 'invalid sentences';
  end if;

  if p_client_request_id is not null then
    insert into public.generation_jobs (
      client_request_id,
      user_id,
      status,
      updated_at
    )
    values (
      p_client_request_id,
      p_user_id,
      'pending',
      timezone('utc', now())
    )
    on conflict (client_request_id) do nothing;

    select *
      into generation_job
      from public.generation_jobs
     where generation_jobs.client_request_id = p_client_request_id
       and generation_jobs.user_id = p_user_id
     for update;

    if not found then
      raise exception 'generation job not found';
    end if;

    if generation_job.status = 'completed' then
      return coalesce(
        generation_job.remaining_credits,
        (select available_generations from public.profiles where id = p_user_id)
      );
    end if;

    if generation_job.status = 'failed' then
      raise exception 'generation job already failed';
    end if;
  end if;

  select available_generations
    into current_balance
    from public.profiles
   where id = p_user_id
   for update;

  if not found then
    raise exception 'profile not found';
  end if;

  if exists (
    select 1 from public.memories
     where id = p_memory_id and user_id = p_user_id
  ) then
    return current_balance;
  end if;

  if coalesce(current_balance, 0) <= 0 then
    raise exception 'No credits left';
  end if;

  remaining_balance := current_balance - 1;

  insert into public.memories (
    id,
    user_id,
    image_url,
    created_at,
    provider,
    tags
  )
  values (
    p_memory_id,
    p_user_id,
    p_image_path,
    coalesce(p_created_at, timezone('utc', now())),
    p_provider,
    coalesce(
      array(
        select tag
        from (
          select distinct on (tag) tag, position
          from unnest(coalesce(p_tags, '{}'::text[])) with ordinality as input(tag, position)
          where tag = any (array[
            '人物', '风景', '旅行', '美食', '生活场景', '动物',
            '植物', '建筑', '活动', '物品', '截图/信息'
          ])
          order by tag, position
        ) as unique_tags
        order by position
        limit 3
      ),
      '{}'::text[]
    )
  );

  for sentence_item in
    select value, ordinality
    from jsonb_array_elements(p_sentences) with ordinality
  loop
    insert into public.memory_sentences (
      id,
      memory_id,
      sort_order,
      english,
      chinese,
      scene_hint,
      presentation_group,
      is_favorite
    )
    values (
      case
        when nullif(sentence_item.value ->> 'id', '') is null then gen_random_uuid()
        else (sentence_item.value ->> 'id')::uuid
      end,
      p_memory_id,
      sentence_item.ordinality - 1,
      btrim(sentence_item.value ->> 'english'),
      btrim(sentence_item.value ->> 'chinese'),
      coalesce(left(nullif(btrim(sentence_item.value ->> 'scene_hint'), ''), 24), ''),
      case
        when sentence_item.value ->> 'presentation_group' = 'what_i_say' then 'what_i_say'
        else 'what_i_see'
      end,
      coalesce((sentence_item.value ->> 'is_favorite')::boolean, false)
    );
  end loop;

  update public.profiles
     set available_generations = remaining_balance
   where id = p_user_id;

  if to_regclass('public.generation_transactions') is not null then
    insert into public.generation_transactions (
      user_id,
      delta,
      balance_after,
      reason,
      note
    )
    values (
      p_user_id,
      -1,
      remaining_balance,
      'generate',
      'memory_id:' || p_memory_id::text
    );
  end if;

  if p_client_request_id is not null then
    update public.generation_jobs
       set status = 'completed',
           memory_id = p_memory_id,
           image_path = p_image_path,
           provider = p_provider,
           remaining_credits = remaining_balance,
           error_message = null,
           updated_at = timezone('utc', now()),
           completed_at = coalesce(completed_at, timezone('utc', now())),
           failed_at = null
     where client_request_id = p_client_request_id
       and user_id = p_user_id;
  end if;

  return remaining_balance;
end;
$$;

revoke all on function public.finalize_authenticated_generation(uuid, uuid, uuid, text, timestamptz, text, jsonb, text[]) from public, anon, authenticated;
grant execute on function public.finalize_authenticated_generation(uuid, uuid, uuid, text, timestamptz, text, jsonb, text[]) to service_role;
