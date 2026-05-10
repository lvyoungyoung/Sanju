create or replace function public.finalize_authenticated_generation(
    p_user_id uuid,
    p_memory_id uuid,
    p_image_path text,
    p_created_at timestamptz,
    p_provider text,
    p_sentences jsonb
)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
    current_balance integer := 0;
    remaining_balance integer := 0;
    sentence_item record;
begin
    if p_sentences is null
       or jsonb_typeof(p_sentences) <> 'array'
       or jsonb_array_length(p_sentences) <> 3 then
        raise exception 'invalid sentences';
    end if;

    select profiles.available_generations
      into current_balance
      from public.profiles
     where profiles.id = p_user_id
     for update;

    if not found then
        raise exception 'profile not found';
    end if;

    if exists (
        select 1
          from public.memories
         where memories.id = p_memory_id
           and memories.user_id = p_user_id
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
        provider
    )
    values (
        p_memory_id,
        p_user_id,
        p_image_path,
        coalesce(p_created_at, timezone('utc', now())),
        p_provider
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
            is_favorite
        )
        values (
            case
                when nullif(sentence_item.value ->> 'id', '') is null then gen_random_uuid()
                else (sentence_item.value ->> 'id')::uuid
            end,
            p_memory_id,
            sentence_item.ordinality,
            trim(sentence_item.value ->> 'english'),
            trim(sentence_item.value ->> 'chinese'),
            coalesce((sentence_item.value ->> 'is_favorite')::boolean, false)
        );
    end loop;

    update public.profiles
       set available_generations = remaining_balance
     where profiles.id = p_user_id;

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

    return remaining_balance;
end;
$$;

create or replace function public.finalize_authenticated_generation(
    p_user_id uuid,
    p_memory_id uuid,
    p_client_request_id uuid,
    p_image_path text,
    p_created_at timestamptz,
    p_provider text,
    p_sentences jsonb
)
returns integer
language plpgsql
security definer
set search_path = public
as $$
begin
    return public.finalize_authenticated_generation(
        p_user_id,
        p_memory_id,
        p_image_path,
        p_created_at,
        p_provider,
        p_sentences
    );
end;
$$;

create or replace function public.finalize_guest_generation(
    p_user_id uuid,
    p_guest_job_id uuid,
    p_completed_at timestamptz,
    p_provider text,
    p_sentences jsonb
)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
    current_balance integer := 0;
    remaining_balance integer := 0;
    guest_job record;
begin
    if p_sentences is null
       or jsonb_typeof(p_sentences) <> 'array'
       or jsonb_array_length(p_sentences) <> 3 then
        raise exception 'invalid sentences';
    end if;

    select *
      into guest_job
      from public.guest_generation_jobs
     where guest_generation_jobs.id = p_guest_job_id
       and guest_generation_jobs.user_id = p_user_id
     for update;

    if not found then
        raise exception 'guest generation job not found';
    end if;

    if guest_job.status in ('completed', 'acknowledged') then
        return coalesce(
            guest_job.remaining_credits,
            (
                select profiles.available_generations
                  from public.profiles
                 where profiles.id = p_user_id
            )
        );
    end if;

    if guest_job.status = 'failed' then
        raise exception 'guest generation job already failed';
    end if;

    select profiles.available_generations
      into current_balance
      from public.profiles
     where profiles.id = p_user_id
     for update;

    if not found then
        raise exception 'profile not found';
    end if;

    if coalesce(current_balance, 0) <= 0 then
        raise exception 'No credits left';
    end if;

    remaining_balance := current_balance - 1;

    update public.profiles
       set available_generations = remaining_balance
     where profiles.id = p_user_id;

    update public.guest_generation_jobs
       set status = 'completed',
           completed_at = coalesce(p_completed_at, timezone('utc', now())),
           provider = p_provider,
           sentences = p_sentences,
           remaining_credits = remaining_balance,
           error_message = null
     where guest_generation_jobs.id = p_guest_job_id
       and guest_generation_jobs.user_id = p_user_id;

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
            'guest_job_id:' || p_guest_job_id::text
        );
    end if;

    return remaining_balance;
end;
$$;

create or replace function public.finalize_guest_generation(
    p_user_id uuid,
    p_guest_job_id uuid,
    p_client_request_id uuid,
    p_completed_at timestamptz,
    p_provider text,
    p_sentences jsonb
)
returns integer
language plpgsql
security definer
set search_path = public
as $$
begin
    return public.finalize_guest_generation(
        p_user_id,
        p_guest_job_id,
        p_completed_at,
        p_provider,
        p_sentences
    );
end;
$$;

revoke all on function public.finalize_authenticated_generation(uuid, uuid, text, timestamptz, text, jsonb) from public;
revoke all on function public.finalize_authenticated_generation(uuid, uuid, text, timestamptz, text, jsonb) from anon;
revoke all on function public.finalize_authenticated_generation(uuid, uuid, text, timestamptz, text, jsonb) from authenticated;
grant execute on function public.finalize_authenticated_generation(uuid, uuid, text, timestamptz, text, jsonb) to service_role;

revoke all on function public.finalize_authenticated_generation(uuid, uuid, uuid, text, timestamptz, text, jsonb) from public;
revoke all on function public.finalize_authenticated_generation(uuid, uuid, uuid, text, timestamptz, text, jsonb) from anon;
revoke all on function public.finalize_authenticated_generation(uuid, uuid, uuid, text, timestamptz, text, jsonb) from authenticated;
grant execute on function public.finalize_authenticated_generation(uuid, uuid, uuid, text, timestamptz, text, jsonb) to service_role;

revoke all on function public.finalize_guest_generation(uuid, uuid, timestamptz, text, jsonb) from public;
revoke all on function public.finalize_guest_generation(uuid, uuid, timestamptz, text, jsonb) from anon;
revoke all on function public.finalize_guest_generation(uuid, uuid, timestamptz, text, jsonb) from authenticated;
grant execute on function public.finalize_guest_generation(uuid, uuid, timestamptz, text, jsonb) to service_role;

revoke all on function public.finalize_guest_generation(uuid, uuid, uuid, timestamptz, text, jsonb) from public;
revoke all on function public.finalize_guest_generation(uuid, uuid, uuid, timestamptz, text, jsonb) from anon;
revoke all on function public.finalize_guest_generation(uuid, uuid, uuid, timestamptz, text, jsonb) from authenticated;
grant execute on function public.finalize_guest_generation(uuid, uuid, uuid, timestamptz, text, jsonb) to service_role;
