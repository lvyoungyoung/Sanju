-- Independent of image-generation credits. Only the authenticated Edge Function
-- can consume this budget; one row per auth user also covers anonymous users.
create table if not exists public.speech_request_limits (
  user_id uuid primary key references auth.users(id) on delete cascade,
  minute_started_at timestamptz not null,
  minute_count integer not null,
  request_day date not null,
  day_count integer not null
);
alter table public.speech_request_limits enable row level security;
revoke all on public.speech_request_limits from public, anon, authenticated;

create or replace function public.consume_speech_request(p_user_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  current_minute timestamptz := date_trunc('minute', now());
  current_day_utc date := (now() at time zone 'UTC')::date;
  accepted_user uuid;
begin
  insert into public.speech_request_limits as limits
    (user_id, minute_started_at, minute_count, request_day, day_count)
  values (p_user_id, current_minute, 1, current_day_utc, 1)
  on conflict (user_id) do update set
    minute_started_at = current_minute,
    minute_count = case when limits.minute_started_at = current_minute
      then limits.minute_count + 1 else 1 end,
    request_day = current_day_utc,
    day_count = case when limits.request_day = current_day_utc
      then limits.day_count + 1 else 1 end
  where (limits.minute_started_at <> current_minute or limits.minute_count < 20)
    and (limits.request_day <> current_day_utc or limits.day_count < 300)
  returning user_id into accepted_user;
  return accepted_user is not null;
end;
$$;
revoke all on function public.consume_speech_request(uuid) from public, anon, authenticated;
grant execute on function public.consume_speech_request(uuid) to service_role;
