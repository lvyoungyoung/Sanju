-- Only the caller that inserts the job may execute its generation. No lease
-- takeover: a delayed original worker must never race a replacement worker.
create or replace function public.claim_generation_job(
  p_user_id uuid,
  p_request_id uuid,
  p_is_anonymous boolean,
  p_image_path text default null
)
returns text
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  inserted_id uuid;
  job_owner uuid;
  job_status text;
begin
  if p_user_id is null or p_request_id is null or p_is_anonymous is null then
    raise exception 'invalid generation claim';
  end if;

  if p_is_anonymous then
    insert into public.guest_generation_jobs(id, user_id, status, image_path)
    values (p_request_id, p_user_id, 'pending', p_image_path)
    on conflict (id) do nothing
    returning id into inserted_id;
    if inserted_id is not null then return 'acquired'; end if;

    select user_id, status into job_owner, job_status
    from public.guest_generation_jobs where id = p_request_id for update;
  else
    insert into public.generation_jobs(client_request_id, user_id, status)
    values (p_request_id, p_user_id, 'pending')
    on conflict (client_request_id) do nothing
    returning id into inserted_id;
    if inserted_id is not null then return 'acquired'; end if;

    select user_id, status into job_owner, job_status
    from public.generation_jobs where client_request_id = p_request_id for update;
  end if;

  if job_owner is distinct from p_user_id then
    raise exception 'generation job not found';
  end if;
  return job_status;
end;
$$;

revoke all on function public.claim_generation_job(uuid, uuid, boolean, text) from public, anon, authenticated;
grant execute on function public.claim_generation_job(uuid, uuid, boolean, text) to service_role;

-- Also guard against stale workers and accidental direct updates. Anonymous
-- completed -> acknowledged remains valid; deleting a memory may clear its FK.
create or replace function public.protect_generation_job_result()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if new.user_id is distinct from old.user_id or new.id is distinct from old.id then
    raise exception 'generation job identity is immutable';
  end if;
  if tg_table_name = 'generation_jobs' then
    if new.client_request_id is distinct from old.client_request_id then
      raise exception 'generation job identity is immutable';
    end if;
  end if;

  if old.status in ('completed', 'acknowledged', 'failed') then
    if new.status is distinct from old.status and not (
      tg_table_name = 'guest_generation_jobs' and old.status = 'completed' and new.status = 'acknowledged'
    ) then
      raise exception 'generation job terminal state is immutable';
    end if;

    if old.status in ('completed', 'acknowledged') then
      if new.image_path is distinct from old.image_path
         or new.remaining_credits is distinct from old.remaining_credits
         or new.provider is distinct from old.provider then
        raise exception 'generation job result is immutable';
      end if;
      if tg_table_name = 'generation_jobs' then
        if new.memory_id is distinct from old.memory_id and (
          new.memory_id is not null or exists(select 1 from public.memories where id = old.memory_id)
        ) then
          raise exception 'generation job result is immutable';
        end if;
      elsif new.sentences is distinct from old.sentences or new.tags is distinct from old.tags then
        raise exception 'generation job result is immutable';
      end if;
    end if;
  end if;
  return new;
end;
$$;

revoke all on function public.protect_generation_job_result() from public, anon, authenticated;
drop trigger if exists protect_generation_job_result on public.generation_jobs;
create trigger protect_generation_job_result before update on public.generation_jobs
for each row execute function public.protect_generation_job_result();
drop trigger if exists protect_generation_job_result on public.guest_generation_jobs;
create trigger protect_generation_job_result before update on public.guest_generation_jobs
for each row execute function public.protect_generation_job_result();
