create table if not exists public.generation_request_slots (
  request_id uuid primary key,
  user_id uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default timezone('utc'::text, now()),
  expires_at timestamptz not null
);

create index if not exists generation_request_slots_expires_at_idx
  on public.generation_request_slots (expires_at);

create or replace function public.try_acquire_generation_slot(
  p_request_id uuid,
  p_user_id uuid,
  p_max_slots integer default 8,
  p_ttl_seconds integer default 180
)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_active_count integer;
begin
  perform pg_advisory_xact_lock(284731);

  delete from public.generation_request_slots
  where expires_at <= timezone('utc'::text, now());

  if exists (
    select 1
    from public.generation_request_slots
    where request_id = p_request_id
  ) then
    return true;
  end if;

  select count(*)
    into v_active_count
  from public.generation_request_slots
  where expires_at > timezone('utc'::text, now());

  if v_active_count >= greatest(coalesce(p_max_slots, 8), 1) then
    return false;
  end if;

  insert into public.generation_request_slots (
    request_id,
    user_id,
    expires_at
  )
  values (
    p_request_id,
    p_user_id,
    timezone('utc'::text, now()) + make_interval(secs => greatest(coalesce(p_ttl_seconds, 180), 30))
  );

  return true;
end;
$$;

grant execute on function public.try_acquire_generation_slot(uuid, uuid, integer, integer) to service_role;

create or replace function public.release_generation_slot(p_request_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  delete from public.generation_request_slots
  where request_id = p_request_id;
end;
$$;

grant execute on function public.release_generation_slot(uuid) to service_role;
