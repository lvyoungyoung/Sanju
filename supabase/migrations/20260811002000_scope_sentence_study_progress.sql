-- Keep an independent learning schedule for each sentence in each study scene.
-- Existing study history becomes the history of the Favorites scene.
alter table public.memory_sentences
  drop constraint if exists memory_sentences_study_topic_check;

alter table public.memory_sentences
  add constraint memory_sentences_study_topic_check
  check (
    study_topic is null
    or (
      char_length(btrim(study_topic)) between 2 and 8
      and btrim(study_topic) <> '收藏'
      and btrim(study_topic) <> 'favorites'
    )
  );

-- Redefine the generation wrapper as well, so this migration works whether
-- the prior fixed-topic migration has already run or is replayed from scratch.
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

    update public.memory_sentences ms
       set study_topic = case
            when char_length(btrim(coalesce(payload.value ->> 'study_topic', ''))) between 2 and 8
              and btrim(payload.value ->> 'study_topic') <> '收藏'
              and btrim(payload.value ->> 'study_topic') <> 'favorites'
              then btrim(payload.value ->> 'study_topic')
            else null
       end
      from jsonb_array_elements(p_sentences) with ordinality as payload(value, sort_order)
     where ms.memory_id = p_memory_id
       and ms.sort_order = payload.sort_order
       and exists (
            select 1
            from public.memories m
            where m.id = ms.memory_id
              and m.user_id = p_user_id
       );

    return remaining_balance;
end;
$$;

alter table public.sentence_study_progress
  add column if not exists study_scope text not null default 'favorites';

update public.sentence_study_progress
set study_scope = 'favorites'
where study_scope is null;

alter table public.sentence_study_progress
  drop constraint if exists sentence_study_progress_study_scope_check;

alter table public.sentence_study_progress
  add constraint sentence_study_progress_study_scope_check
  check (char_length(btrim(study_scope)) between 2 and 24);

alter table public.sentence_study_progress
  drop constraint if exists sentence_study_progress_user_id_sentence_id_key;

alter table public.sentence_study_progress
  drop constraint if exists sentence_study_progress_user_id_sentence_id_scope_key;

alter table public.sentence_study_progress
  add constraint sentence_study_progress_user_id_sentence_id_scope_key
  unique (user_id, sentence_id, study_scope);

create index if not exists sentence_study_progress_user_scope_next_review_at_idx
  on public.sentence_study_progress (user_id, study_scope, next_review_at);

create index if not exists sentence_study_progress_user_scope_last_studied_on_idx
  on public.sentence_study_progress (user_id, study_scope, last_studied_on);

-- The legacy Favorites endpoints stay in place for released clients. They now
-- explicitly read only Favorites progress.
drop function if exists public.get_sentence_study_queue(integer);
create function public.get_sentence_study_queue(p_limit integer default 5)
returns table (
  sentence_id uuid,
  memory_id uuid,
  english text,
  chinese text,
  image_path text,
  memory_created_at timestamptz,
  learning_step integer,
  mastered_review_count integer,
  correct_count integer,
  wrong_count integer,
  last_result text,
  next_review_at timestamptz
)
language sql
security definer
set search_path = public, pg_temp
as $$
  with candidates as (
    select
      ms.id as sentence_id,
      ms.memory_id,
      ms.english,
      ms.chinese,
      m.image_url as image_path,
      m.created_at as memory_created_at,
      coalesce(sp.learning_step, 0) as learning_step,
      coalesce(sp.mastered_review_count, 0) as mastered_review_count,
      coalesce(sp.correct_count, 0) as correct_count,
      coalesce(sp.wrong_count, 0) as wrong_count,
      sp.last_result,
      sp.next_review_at,
      case
        when sp.id is not null and sp.learning_step < 5
          and (sp.next_review_at at time zone 'Asia/Shanghai')::date <= (now() at time zone 'Asia/Shanghai')::date then 1
        when sp.id is null then 2
        when sp.id is not null and sp.learning_step >= 5
          and (sp.next_review_at at time zone 'Asia/Shanghai')::date <= (now() at time zone 'Asia/Shanghai')::date then 3
        else 99
      end as priority
    from public.memory_sentences ms
    join public.memories m on m.id = ms.memory_id
    left join public.sentence_study_progress sp
      on sp.sentence_id = ms.id
     and sp.user_id = auth.uid()
     and sp.study_scope = 'favorites'
    where auth.uid() is not null
      and m.user_id = auth.uid()
      and ms.is_favorite = true
      and (sp.last_studied_on is null or sp.last_studied_on < (now() at time zone 'Asia/Shanghai')::date)
  )
  select sentence_id, memory_id, english, chinese, image_path, memory_created_at,
         learning_step, mastered_review_count, correct_count, wrong_count, last_result, next_review_at
  from candidates
  where priority < 99
  order by priority asc,
           coalesce((next_review_at at time zone 'Asia/Shanghai')::date, (now() at time zone 'Asia/Shanghai')::date) asc,
           memory_created_at desc
  limit least(greatest(coalesce(p_limit, 5), 1), 1000);
$$;

drop function if exists public.count_sentence_study_queue();
create function public.count_sentence_study_queue()
returns integer
language sql
security definer
set search_path = public, pg_temp
as $$
  with candidates as (
    select case
      when sp.id is not null and sp.learning_step < 5
        and (sp.next_review_at at time zone 'Asia/Shanghai')::date <= (now() at time zone 'Asia/Shanghai')::date then 1
      when sp.id is null then 2
      when sp.id is not null and sp.learning_step >= 5
        and (sp.next_review_at at time zone 'Asia/Shanghai')::date <= (now() at time zone 'Asia/Shanghai')::date then 3
      else 99
    end as priority
    from public.memory_sentences ms
    join public.memories m on m.id = ms.memory_id
    left join public.sentence_study_progress sp
      on sp.sentence_id = ms.id
     and sp.user_id = auth.uid()
     and sp.study_scope = 'favorites'
    where auth.uid() is not null
      and m.user_id = auth.uid()
      and ms.is_favorite = true
      and (sp.last_studied_on is null or sp.last_studied_on < (now() at time zone 'Asia/Shanghai')::date)
  )
  select count(*)::integer
  from candidates
  where priority < 99;
$$;

create or replace function public.get_sentence_studied_today_queue(p_limit integer default 30)
returns table (
  sentence_id uuid,
  memory_id uuid,
  english text,
  chinese text,
  image_path text,
  memory_created_at timestamptz,
  learning_step integer,
  mastered_review_count integer,
  correct_count integer,
  wrong_count integer,
  last_result text,
  next_review_at timestamptz
)
language sql
security definer
set search_path = public, pg_temp
as $$
  select
    ms.id, ms.memory_id, ms.english, ms.chinese, m.image_url, m.created_at,
    coalesce(sp.learning_step, 0), coalesce(sp.mastered_review_count, 0),
    coalesce(sp.correct_count, 0), coalesce(sp.wrong_count, 0),
    sp.last_result, sp.next_review_at
  from public.sentence_study_progress sp
  join public.memory_sentences ms on ms.id = sp.sentence_id
  join public.memories m on m.id = ms.memory_id
  where auth.uid() is not null
    and sp.user_id = auth.uid()
    and sp.study_scope = 'favorites'
    and m.user_id = auth.uid()
    and ms.is_favorite = true
    and sp.last_studied_on = (now() at time zone 'Asia/Shanghai')::date
  order by sp.last_studied_at asc nulls last, m.created_at desc
  limit least(greatest(coalesce(p_limit, 30), 1), 1000);
$$;

create or replace function public.count_sentence_studied_today_reviewable()
returns integer
language sql
security definer
set search_path = public, pg_temp
as $$
  select count(*)::integer
  from public.sentence_study_progress sp
  join public.memory_sentences ms on ms.id = sp.sentence_id
  join public.memories m on m.id = ms.memory_id
  where auth.uid() is not null
    and sp.user_id = auth.uid()
    and sp.study_scope = 'favorites'
    and m.user_id = auth.uid()
    and ms.is_favorite = true
    and sp.last_studied_on = (now() at time zone 'Asia/Shanghai')::date;
$$;

-- New clients send p_scope. The default preserves the two-argument call used
-- by installed versions and directs it to Favorites.
drop function if exists public.record_sentence_study_result(uuid, boolean);
create function public.record_sentence_study_result(
  p_sentence_id uuid,
  p_was_correct boolean,
  p_scope text default 'favorites'
)
returns public.sentence_study_progress
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_now timestamptz := now();
  v_today date := (now() at time zone 'Asia/Shanghai')::date;
  v_scope text := coalesce(nullif(trim(p_scope), ''), 'favorites');
  v_existing public.sentence_study_progress%rowtype;
  v_result public.sentence_study_progress%rowtype;
  v_learning_step integer;
  v_mastered_review_count integer;
  v_correct_count integer;
  v_wrong_count integer;
  v_next_review_at timestamptz;
  v_last_result text;
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;

  if char_length(v_scope) > 24
     or (v_scope <> 'favorites' and char_length(v_scope) < 2) then
    raise exception 'Invalid study scope';
  end if;

  perform 1
  from public.memory_sentences ms
  join public.memories m on m.id = ms.memory_id
  where ms.id = p_sentence_id
    and m.user_id = auth.uid()
    and (
      (v_scope = 'favorites' and ms.is_favorite = true)
      or (v_scope <> 'favorites' and ms.study_topic = v_scope)
    );

  if not found then
    raise exception 'Sentence not available for study';
  end if;

  select * into v_existing
  from public.sentence_study_progress
  where user_id = auth.uid()
    and sentence_id = p_sentence_id
    and study_scope = v_scope
  for update;

  if found and v_existing.last_studied_on = v_today then
    return v_existing;
  end if;

  if p_was_correct then
    v_correct_count := coalesce(v_existing.correct_count, 0) + 1;
    v_wrong_count := coalesce(v_existing.wrong_count, 0);
    v_last_result := 'correct';

    if coalesce(v_existing.learning_step, 0) < 5 then
      v_learning_step := coalesce(v_existing.learning_step, 0) + 1;
      v_mastered_review_count := coalesce(v_existing.mastered_review_count, 0);
      case v_learning_step
        when 1 then v_next_review_at := ((v_today + 1)::timestamp at time zone 'Asia/Shanghai');
        when 2 then v_next_review_at := ((v_today + 2)::timestamp at time zone 'Asia/Shanghai');
        when 3 then v_next_review_at := ((v_today + 4)::timestamp at time zone 'Asia/Shanghai');
        when 4 then v_next_review_at := ((v_today + 7)::timestamp at time zone 'Asia/Shanghai');
        else v_next_review_at := ((v_today + 14)::timestamp at time zone 'Asia/Shanghai');
      end case;
    else
      v_learning_step := 5;
      v_mastered_review_count := coalesce(v_existing.mastered_review_count, 0) + 1;
      if v_mastered_review_count = 1 then
        v_next_review_at := ((v_today + 30)::timestamp at time zone 'Asia/Shanghai');
      else
        v_next_review_at := ((v_today + 60)::timestamp at time zone 'Asia/Shanghai');
      end if;
    end if;
  else
    v_learning_step := least(coalesce(v_existing.learning_step, 0), 5);
    v_mastered_review_count := coalesce(v_existing.mastered_review_count, 0);
    v_correct_count := coalesce(v_existing.correct_count, 0);
    v_wrong_count := coalesce(v_existing.wrong_count, 0) + 1;
    v_last_result := 'incorrect';
    v_next_review_at := ((v_today + 1)::timestamp at time zone 'Asia/Shanghai');
  end if;

  insert into public.sentence_study_progress (
    user_id, sentence_id, study_scope, learning_step, mastered_review_count,
    correct_count, wrong_count, last_result, last_studied_at, last_studied_on, next_review_at
  ) values (
    auth.uid(), p_sentence_id, v_scope, v_learning_step, v_mastered_review_count,
    v_correct_count, v_wrong_count, v_last_result, v_now, v_today, v_next_review_at
  )
  on conflict (user_id, sentence_id, study_scope) do update
    set learning_step = excluded.learning_step,
        mastered_review_count = excluded.mastered_review_count,
        correct_count = excluded.correct_count,
        wrong_count = excluded.wrong_count,
        last_result = excluded.last_result,
        last_studied_at = excluded.last_studied_at,
        last_studied_on = excluded.last_studied_on,
        next_review_at = excluded.next_review_at,
        updated_at = v_now
  returning * into v_result;

  return v_result;
end;
$$;

-- Anonymous progress merges on the same sentence + scope key. Old payloads
-- omit study_scope and therefore continue to merge into Favorites.
drop function if exists public.merge_local_sentence_study_progress(jsonb);
create function public.merge_local_sentence_study_progress(p_items jsonb)
returns table (
  sentence_id uuid,
  study_scope text
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_item jsonb;
  v_sentence_id uuid;
  v_scope text;
  v_learning_step integer;
  v_mastered_review_count integer;
  v_correct_count integer;
  v_wrong_count integer;
  v_last_result text;
  v_last_studied_at timestamptz;
  v_last_studied_on date;
  v_next_review_on date;
  v_next_review_at timestamptz;
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;

  if p_items is null or jsonb_typeof(p_items) <> 'array' then
    return;
  end if;

  for v_item in select value from jsonb_array_elements(p_items)
  loop
    begin
      v_sentence_id := nullif(v_item->>'sentence_id', '')::uuid;
      v_scope := coalesce(nullif(trim(v_item->>'study_scope'), ''), 'favorites');
      v_learning_step := least(greatest(coalesce(nullif(v_item->>'learning_step', '')::integer, 0), 0), 5);
      v_mastered_review_count := greatest(coalesce(nullif(v_item->>'mastered_review_count', '')::integer, 0), 0);
      v_correct_count := greatest(coalesce(nullif(v_item->>'correct_count', '')::integer, 0), 0);
      v_wrong_count := greatest(coalesce(nullif(v_item->>'wrong_count', '')::integer, 0), 0);
      v_last_result := case when v_item->>'last_result' in ('correct', 'incorrect') then v_item->>'last_result' else null end;
      v_last_studied_at := nullif(v_item->>'last_studied_at', '')::timestamptz;
      v_last_studied_on := nullif(v_item->>'last_studied_on', '')::date;
      v_next_review_on := nullif(v_item->>'next_review_on', '')::date;
    exception when others then
      continue;
    end;

    if v_sentence_id is null
       or char_length(v_scope) > 24
       or (v_scope <> 'favorites' and char_length(v_scope) < 2) then
      continue;
    end if;

    if v_last_studied_on is null and v_last_studied_at is not null then
      v_last_studied_on := (v_last_studied_at at time zone 'Asia/Shanghai')::date;
    end if;

    v_next_review_on := coalesce(v_next_review_on, v_last_studied_on, (now() at time zone 'Asia/Shanghai')::date);
    v_next_review_at := (v_next_review_on::timestamp at time zone 'Asia/Shanghai');

    perform 1
    from public.memory_sentences ms
    join public.memories m on m.id = ms.memory_id
    where ms.id = v_sentence_id
      and m.user_id = auth.uid()
      and (
        (v_scope = 'favorites' and ms.is_favorite = true)
        or (v_scope <> 'favorites' and ms.study_topic = v_scope)
      );

    if not found then
      continue;
    end if;

    insert into public.sentence_study_progress as sp (
      user_id, sentence_id, study_scope, learning_step, mastered_review_count,
      correct_count, wrong_count, last_result, last_studied_at, last_studied_on, next_review_at
    ) values (
      auth.uid(), v_sentence_id, v_scope, v_learning_step, v_mastered_review_count,
      v_correct_count, v_wrong_count, v_last_result, v_last_studied_at, v_last_studied_on, v_next_review_at
    )
    on conflict on constraint sentence_study_progress_user_id_sentence_id_scope_key do update
      set learning_step = greatest(sp.learning_step, excluded.learning_step),
          mastered_review_count = greatest(sp.mastered_review_count, excluded.mastered_review_count),
          correct_count = greatest(sp.correct_count, excluded.correct_count),
          wrong_count = greatest(sp.wrong_count, excluded.wrong_count),
          last_result = case
            when excluded.last_studied_on is not null
              and (sp.last_studied_on is null or excluded.last_studied_on >= sp.last_studied_on)
              then coalesce(excluded.last_result, sp.last_result)
            else sp.last_result
          end,
          last_studied_at = case
            when excluded.last_studied_at is null then sp.last_studied_at
            when sp.last_studied_at is null then excluded.last_studied_at
            else greatest(sp.last_studied_at, excluded.last_studied_at)
          end,
          last_studied_on = case
            when excluded.last_studied_on is null then sp.last_studied_on
            when sp.last_studied_on is null then excluded.last_studied_on
            else greatest(sp.last_studied_on, excluded.last_studied_on)
          end,
          next_review_at = greatest(sp.next_review_at, excluded.next_review_at),
          updated_at = timezone('utc'::text, now());

    return query select v_sentence_id, v_scope;
  end loop;
end;
$$;

-- Topic queues use the progress record for their own topic, not the shared
-- Favorites record.
create or replace function public.get_sentence_study_topic_queue(
  p_topic text,
  p_limit integer default 30
)
returns table (
  sentence_id uuid,
  memory_id uuid,
  english text,
  chinese text,
  image_path text,
  memory_created_at timestamptz,
  learning_step integer,
  mastered_review_count integer,
  correct_count integer,
  wrong_count integer,
  last_result text,
  next_review_at timestamptz
)
language sql
security definer
set search_path = public, pg_temp
as $$
  with candidates as (
    select
      ms.id as sentence_id, ms.memory_id, ms.english, ms.chinese,
      m.image_url as image_path, m.created_at as memory_created_at,
      coalesce(sp.learning_step, 0) as learning_step,
      coalesce(sp.mastered_review_count, 0) as mastered_review_count,
      coalesce(sp.correct_count, 0) as correct_count,
      coalesce(sp.wrong_count, 0) as wrong_count,
      sp.last_result, sp.next_review_at,
      case
        when sp.id is not null and sp.learning_step < 5
          and (sp.next_review_at at time zone 'Asia/Shanghai')::date <= (now() at time zone 'Asia/Shanghai')::date then 1
        when sp.id is null then 2
        when sp.id is not null and sp.learning_step >= 5
          and (sp.next_review_at at time zone 'Asia/Shanghai')::date <= (now() at time zone 'Asia/Shanghai')::date then 3
        else 99
      end as priority
    from public.memory_sentences ms
    join public.memories m on m.id = ms.memory_id
    left join public.sentence_study_progress sp
      on sp.sentence_id = ms.id
     and sp.user_id = auth.uid()
     and sp.study_scope = p_topic
    where auth.uid() is not null
      and m.user_id = auth.uid()
      and ms.study_topic = p_topic
      and (sp.last_studied_on is null or sp.last_studied_on < (now() at time zone 'Asia/Shanghai')::date)
  )
  select sentence_id, memory_id, english, chinese, image_path, memory_created_at,
         learning_step, mastered_review_count, correct_count, wrong_count, last_result, next_review_at
  from candidates
  where priority < 99
  order by priority asc,
           coalesce((next_review_at at time zone 'Asia/Shanghai')::date, (now() at time zone 'Asia/Shanghai')::date) asc,
           memory_created_at desc
  limit least(greatest(coalesce(p_limit, 30), 1), 1000);
$$;

create or replace function public.get_sentence_studied_today_topic_queue(
  p_topic text,
  p_limit integer default 200
)
returns table (
  sentence_id uuid,
  memory_id uuid,
  english text,
  chinese text,
  image_path text,
  memory_created_at timestamptz,
  learning_step integer,
  mastered_review_count integer,
  correct_count integer,
  wrong_count integer,
  last_result text,
  next_review_at timestamptz
)
language sql
security definer
set search_path = public, pg_temp
as $$
  select
    ms.id, ms.memory_id, ms.english, ms.chinese, m.image_url, m.created_at,
    coalesce(sp.learning_step, 0), coalesce(sp.mastered_review_count, 0),
    coalesce(sp.correct_count, 0), coalesce(sp.wrong_count, 0),
    sp.last_result, sp.next_review_at
  from public.sentence_study_progress sp
  join public.memory_sentences ms on ms.id = sp.sentence_id
  join public.memories m on m.id = ms.memory_id
  where auth.uid() is not null
    and sp.user_id = auth.uid()
    and sp.study_scope = p_topic
    and m.user_id = auth.uid()
    and ms.study_topic = p_topic
    and sp.last_studied_on = (now() at time zone 'Asia/Shanghai')::date
  order by sp.last_studied_at asc nulls last, m.created_at desc
  limit least(greatest(coalesce(p_limit, 200), 1), 1000);
$$;

drop function if exists public.get_sentence_study_topic_summaries();
create function public.get_sentence_study_topic_summaries()
returns table (
  topic text,
  total_count integer,
  due_count integer,
  studied_count integer,
  reviewable_today_count integer,
  mastery_score integer
)
language sql
security definer
set search_path = public, pg_temp
as $$
  with sentences as (
    select
      ms.study_topic as topic,
      sp.id as progress_id,
      coalesce(sp.correct_count, 0) as correct_count,
      sp.next_review_at,
      sp.last_studied_on
    from public.memory_sentences ms
    join public.memories m on m.id = ms.memory_id
    left join public.sentence_study_progress sp
      on sp.sentence_id = ms.id
     and sp.user_id = auth.uid()
     and sp.study_scope = ms.study_topic
    where auth.uid() is not null
      and m.user_id = auth.uid()
      and ms.study_topic is not null
  )
  select
    topic,
    count(*)::integer as total_count,
    count(*) filter (
      where (last_studied_on is null or last_studied_on < (now() at time zone 'Asia/Shanghai')::date)
        and (progress_id is null or (next_review_at at time zone 'Asia/Shanghai')::date <= (now() at time zone 'Asia/Shanghai')::date)
    )::integer as due_count,
    count(*) filter (where correct_count > 0)::integer as studied_count,
    count(*) filter (where last_studied_on = (now() at time zone 'Asia/Shanghai')::date)::integer as reviewable_today_count,
    round(avg(case
      when correct_count <= 0 then 0
      when correct_count <= 2 then 40
      when correct_count <= 4 then 70
      else 100
    end))::integer as mastery_score
  from sentences
  group by topic;
$$;

revoke all on function public.get_sentence_study_queue(integer) from public;
revoke all on function public.get_sentence_study_queue(integer) from anon;
grant execute on function public.get_sentence_study_queue(integer) to authenticated;
revoke all on function public.count_sentence_study_queue() from public;
revoke all on function public.count_sentence_study_queue() from anon;
grant execute on function public.count_sentence_study_queue() to authenticated;
revoke all on function public.get_sentence_studied_today_queue(integer) from public;
revoke all on function public.get_sentence_studied_today_queue(integer) from anon;
grant execute on function public.get_sentence_studied_today_queue(integer) to authenticated;
revoke all on function public.count_sentence_studied_today_reviewable() from public;
revoke all on function public.count_sentence_studied_today_reviewable() from anon;
grant execute on function public.count_sentence_studied_today_reviewable() to authenticated;
revoke all on function public.record_sentence_study_result(uuid, boolean, text) from public;
revoke all on function public.record_sentence_study_result(uuid, boolean, text) from anon;
grant execute on function public.record_sentence_study_result(uuid, boolean, text) to authenticated;
revoke all on function public.merge_local_sentence_study_progress(jsonb) from public;
revoke all on function public.merge_local_sentence_study_progress(jsonb) from anon;
grant execute on function public.merge_local_sentence_study_progress(jsonb) to authenticated;
revoke all on function public.get_sentence_study_topic_queue(text, integer) from public;
revoke all on function public.get_sentence_study_topic_queue(text, integer) from anon;
grant execute on function public.get_sentence_study_topic_queue(text, integer) to authenticated;
revoke all on function public.get_sentence_studied_today_topic_queue(text, integer) from public;
revoke all on function public.get_sentence_studied_today_topic_queue(text, integer) from anon;
grant execute on function public.get_sentence_studied_today_topic_queue(text, integer) to authenticated;
revoke all on function public.get_sentence_study_topic_summaries() from public;
revoke all on function public.get_sentence_study_topic_summaries() from anon;
grant execute on function public.get_sentence_study_topic_summaries() to authenticated;
