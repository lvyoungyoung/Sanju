alter table public.profiles
add column if not exists generation_banned_until timestamptz,
add column if not exists generation_violation_count integer not null default 0,
add column if not exists generation_violation_window_started_at timestamptz,
add column if not exists last_generation_violation_at timestamptz;

create or replace function public.record_generation_violation(
  p_user_id uuid,
  p_window_seconds integer default 86400,
  p_limit integer default 3,
  p_ban_seconds integer default 86400
)
returns table(
  violation_count integer,
  banned_until timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_now timestamptz := now();
  v_window_seconds integer := greatest(coalesce(p_window_seconds, 86400), 1);
  v_limit integer := greatest(coalesce(p_limit, 3), 1);
  v_ban_seconds integer := greatest(coalesce(p_ban_seconds, 86400), 1);
begin
  return query
  with locked_profile as (
    select
      profiles.id,
      profiles.generation_violation_window_started_at as old_window_started_at,
      profiles.generation_violation_count as old_violation_count
    from public.profiles
    where profiles.id = p_user_id
    for update
  ),
  computed as (
    select
      locked_profile.id,
      case
        when locked_profile.old_window_started_at is null
          or locked_profile.old_window_started_at < v_now - make_interval(secs => v_window_seconds)
        then v_now
        else locked_profile.old_window_started_at
      end as new_window_started_at,
      case
        when locked_profile.old_window_started_at is null
          or locked_profile.old_window_started_at < v_now - make_interval(secs => v_window_seconds)
        then 1
        else coalesce(locked_profile.old_violation_count, 0) + 1
      end as new_violation_count
    from locked_profile
  ),
  updated as (
    update public.profiles
       set generation_violation_window_started_at = computed.new_window_started_at,
           generation_violation_count = computed.new_violation_count,
           last_generation_violation_at = v_now,
           generation_banned_until = case
             when computed.new_violation_count >= v_limit then greatest(
               coalesce(public.profiles.generation_banned_until, '-infinity'::timestamptz),
               v_now + make_interval(secs => v_ban_seconds)
             )
             else public.profiles.generation_banned_until
           end
      from computed
     where public.profiles.id = computed.id
     returning
       public.profiles.generation_violation_count,
       public.profiles.generation_banned_until
  )
  select
    updated.generation_violation_count,
    updated.generation_banned_until
  from updated;
end;
$$;

revoke all on function public.record_generation_violation(uuid, integer, integer, integer) from public;
revoke all on function public.record_generation_violation(uuid, integer, integer, integer) from anon;
revoke all on function public.record_generation_violation(uuid, integer, integer, integer) from authenticated;
grant execute on function public.record_generation_violation(uuid, integer, integer, integer) to service_role;
