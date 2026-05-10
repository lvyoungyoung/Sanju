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
declare
    remaining_balance integer := 0;
    generation_job record;
begin
    if p_client_request_id is null then
        return public.finalize_authenticated_generation(
            p_user_id,
            p_memory_id,
            p_image_path,
            p_created_at,
            p_provider,
            p_sentences
        );
    end if;

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
            (
                select profiles.available_generations
                  from public.profiles
                 where profiles.id = p_user_id
            )
        );
    end if;

    if generation_job.status = 'failed' then
        raise exception 'generation job already failed';
    end if;

    remaining_balance := public.finalize_authenticated_generation(
        p_user_id,
        p_memory_id,
        p_image_path,
        p_created_at,
        p_provider,
        p_sentences
    );

    update public.generation_jobs
       set status = 'completed',
           memory_id = p_memory_id,
           image_path = p_image_path,
           provider = p_provider,
           remaining_credits = remaining_balance,
           error_message = null,
           updated_at = timezone('utc', now()),
           completed_at = coalesce(generation_jobs.completed_at, timezone('utc', now())),
           failed_at = null
     where generation_jobs.client_request_id = p_client_request_id
       and generation_jobs.user_id = p_user_id;

    return remaining_balance;
end;
$$;

revoke all on function public.finalize_authenticated_generation(uuid, uuid, uuid, text, timestamptz, text, jsonb) from public;
revoke all on function public.finalize_authenticated_generation(uuid, uuid, uuid, text, timestamptz, text, jsonb) from anon;
revoke all on function public.finalize_authenticated_generation(uuid, uuid, uuid, text, timestamptz, text, jsonb) from authenticated;
grant execute on function public.finalize_authenticated_generation(uuid, uuid, uuid, text, timestamptz, text, jsonb) to service_role;
