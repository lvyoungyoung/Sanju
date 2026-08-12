-- Keep one concise, hidden scene description for every generated sentence.
-- It enriches the embedding used to match user-created study scenes without
-- reintroducing visible automatic sentence categories.
alter table public.memory_sentences
  add column if not exists scene_hint text not null default '';

alter table public.memory_sentences
  drop constraint if exists memory_sentences_scene_hint_length_check;

alter table public.memory_sentences
  add constraint memory_sentences_scene_hint_length_check
  check (char_length(btrim(scene_hint)) <= 24);

-- Preserve the existing atomic memory creation / credit deduction RPC, then
-- attach the generated hint to the sentence rows created by that same call.
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

  update public.memory_sentences as sentence
     set scene_hint = coalesce(
       left(nullif(btrim(item.value ->> 'scene_hint'), ''), 24),
       ''
     )
    from jsonb_array_elements(coalesce(p_sentences, '[]'::jsonb))
      with ordinality as item(value, sort_order)
   where sentence.memory_id = p_memory_id
     and sentence.sort_order = item.sort_order;

  return remaining_balance;
end;
$$;

revoke all on function public.finalize_authenticated_generation(uuid, uuid, uuid, text, timestamptz, text, jsonb, text[]) from public, anon, authenticated;
grant execute on function public.finalize_authenticated_generation(uuid, uuid, uuid, text, timestamptz, text, jsonb, text[]) to service_role;
