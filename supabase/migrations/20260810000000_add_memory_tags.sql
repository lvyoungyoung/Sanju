alter table if exists public.memories
  add column if not exists tags text[] not null default '{}';

alter table if exists public.guest_generation_jobs
  add column if not exists tags text[] not null default '{}';

create index if not exists memories_tags_gin_idx
  on public.memories using gin (tags);

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
set search_path = public
as $$
declare
    remaining_balance integer := 0;
begin
    remaining_balance := public.finalize_authenticated_generation(
        p_user_id,
        p_memory_id,
        p_client_request_id,
        p_image_path,
        p_created_at,
        p_provider,
        p_sentences
    );

    update public.memories
       set tags = coalesce(
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
     where id = p_memory_id
       and user_id = p_user_id;

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
set search_path = public
as $$
declare
    remaining_balance integer := 0;
begin
    remaining_balance := public.finalize_guest_generation(
        p_user_id,
        p_guest_job_id,
        p_completed_at,
        p_provider,
        p_sentences
    );

    update public.guest_generation_jobs
       set tags = coalesce(
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
     where id = p_guest_job_id
       and user_id = p_user_id;

    return remaining_balance;
end;
$$;

revoke all on function public.finalize_authenticated_generation(uuid, uuid, uuid, text, timestamptz, text, jsonb, text[]) from public;
revoke all on function public.finalize_authenticated_generation(uuid, uuid, uuid, text, timestamptz, text, jsonb, text[]) from anon;
revoke all on function public.finalize_authenticated_generation(uuid, uuid, uuid, text, timestamptz, text, jsonb, text[]) from authenticated;
grant execute on function public.finalize_authenticated_generation(uuid, uuid, uuid, text, timestamptz, text, jsonb, text[]) to service_role;

revoke all on function public.finalize_guest_generation(uuid, uuid, timestamptz, text, jsonb, text[]) from public;
revoke all on function public.finalize_guest_generation(uuid, uuid, timestamptz, text, jsonb, text[]) from anon;
revoke all on function public.finalize_guest_generation(uuid, uuid, timestamptz, text, jsonb, text[]) from authenticated;
grant execute on function public.finalize_guest_generation(uuid, uuid, timestamptz, text, jsonb, text[]) to service_role;
