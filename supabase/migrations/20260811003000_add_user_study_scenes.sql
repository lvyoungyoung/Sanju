-- User-created study scenes use a stable UUID rather than their display name.
-- This keeps scene progress intact when users choose the same name or rename it later.
create table if not exists public.study_scenes (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  name text not null check (char_length(btrim(name)) between 2 and 24),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (user_id, name)
);

create table if not exists public.study_scene_sentences (
  scene_id uuid not null references public.study_scenes(id) on delete cascade,
  sentence_id uuid not null references public.memory_sentences(id) on delete cascade,
  match_score integer not null check (match_score between 1 and 100),
  match_source text not null default 'automatic',
  created_at timestamptz not null default now(),
  primary key (scene_id, sentence_id)
);

create index if not exists study_scenes_user_created_at_idx
  on public.study_scenes (user_id, created_at desc);

create index if not exists study_scene_sentences_sentence_id_idx
  on public.study_scene_sentences (sentence_id);

alter table public.study_scenes enable row level security;
alter table public.study_scene_sentences enable row level security;

drop policy if exists study_scenes_owner_access on public.study_scenes;
create policy study_scenes_owner_access on public.study_scenes
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

drop policy if exists study_scene_sentences_owner_read on public.study_scene_sentences;
create policy study_scene_sentences_owner_read on public.study_scene_sentences
  for select using (
    exists (
      select 1 from public.study_scenes scene
      where scene.id = study_scene_sentences.scene_id
        and scene.user_id = auth.uid()
    )
  );

-- A lightweight fuzzy score for the first version. It compares the requested
-- scene with AI topic names, generated text and memory tags. It intentionally
-- keeps matching conservative so unrelated sentences are not pulled in.
create or replace function public.study_scene_match_score(
  p_scene_name text,
  p_study_topic text,
  p_english text,
  p_chinese text,
  p_tags text[]
)
returns integer
language plpgsql
immutable
set search_path = public, pg_temp
as $$
declare
  v_scene text := lower(regexp_replace(btrim(coalesce(p_scene_name, '')), '\\s+', '', 'g'));
  v_content text := lower(regexp_replace(concat_ws(' ', p_study_topic, p_english, p_chinese, array_to_string(coalesce(p_tags, '{}'::text[]), ' ')), '\\s+', '', 'g'));
  v_token text;
  v_matches integer := 0;
  v_index integer;
begin
  if v_scene = '' or v_content = '' then
    return 0;
  end if;

  if position(v_scene in v_content) > 0 then
    return 100;
  end if;

  if char_length(v_scene) < 2 then
    return 0;
  end if;

  for v_index in 1..char_length(v_scene) - 1 loop
    v_token := substr(v_scene, v_index, 2);
    if position(v_token in v_content) > 0 then
      v_matches := v_matches + 1;
    end if;
  end loop;

  if v_matches >= 2 then
    return 80;
  end if;
  if v_matches = 1 then
    return 55;
  end if;
  return 0;
end;
$$;

create or replace function public.refresh_study_scene_matches(p_scene_id uuid)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_scene public.study_scenes%rowtype;
  v_count integer := 0;
begin
  select * into v_scene
  from public.study_scenes
  where id = p_scene_id
    and user_id = auth.uid();

  if not found then
    raise exception 'Study scene not found';
  end if;

  insert into public.study_scene_sentences (scene_id, sentence_id, match_score)
  select
    v_scene.id,
    ms.id,
    public.study_scene_match_score(v_scene.name, ms.study_topic, ms.english, ms.chinese, m.tags)
  from public.memory_sentences ms
  join public.memories m on m.id = ms.memory_id
  where m.user_id = v_scene.user_id
    and public.study_scene_match_score(v_scene.name, ms.study_topic, ms.english, ms.chinese, m.tags) > 0
  on conflict (scene_id, sentence_id) do update
    set match_score = excluded.match_score;

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

-- New generated or migrated sentences are matched against all existing scenes
-- for their owner. This keeps a scene current without requiring a re-scan.
create or replace function public.match_sentence_to_user_study_scenes()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user_id uuid;
  v_scene record;
  v_tags text[];
  v_score integer;
begin
  select m.user_id, m.tags into v_user_id, v_tags
  from public.memories m
  where m.id = new.memory_id;

  if v_user_id is null then
    return new;
  end if;

  for v_scene in
    select id, name
    from public.study_scenes
    where user_id = v_user_id
  loop
    v_score := public.study_scene_match_score(
      v_scene.name,
      new.study_topic,
      new.english,
      new.chinese,
      v_tags
    );

    if v_score > 0 then
      insert into public.study_scene_sentences (scene_id, sentence_id, match_score)
      values (v_scene.id, new.id, v_score)
      on conflict (scene_id, sentence_id) do update
        set match_score = excluded.match_score;
    end if;
  end loop;

  return new;
end;
$$;

drop trigger if exists match_sentence_to_user_study_scenes_trigger on public.memory_sentences;
create trigger match_sentence_to_user_study_scenes_trigger
after insert or update of study_topic, english, chinese on public.memory_sentences
for each row execute function public.match_sentence_to_user_study_scenes();

create or replace function public.get_study_scenes()
returns table (
  id uuid,
  name text,
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
  with scene_sentences as (
    select
      scene.id,
      scene.name,
      link.sentence_id,
      sp.id as progress_id,
      coalesce(sp.correct_count, 0) as correct_count,
      sp.learning_step,
      sp.next_review_at,
      sp.last_studied_on
    from public.study_scenes scene
    left join public.study_scene_sentences link on link.scene_id = scene.id
    left join public.sentence_study_progress sp
      on sp.sentence_id = link.sentence_id
     and sp.user_id = auth.uid()
     and sp.study_scope = 'scene:' || scene.id::text
    where scene.user_id = auth.uid()
  )
  select
    id,
    name,
    count(sentence_id)::integer as total_count,
    count(sentence_id) filter (
      where (last_studied_on is null or last_studied_on < (now() at time zone 'Asia/Shanghai')::date)
        and (
          progress_id is null
          or (next_review_at at time zone 'Asia/Shanghai')::date <= (now() at time zone 'Asia/Shanghai')::date
        )
    )::integer as due_count,
    count(sentence_id) filter (where correct_count > 0)::integer as studied_count,
    count(sentence_id) filter (where last_studied_on = (now() at time zone 'Asia/Shanghai')::date)::integer as reviewable_today_count,
    coalesce(round(avg(
      case
        when correct_count <= 0 then 0
        when correct_count <= 2 then 40
        when correct_count <= 4 then 70
        else 100
      end
    ))::integer, 0) as mastery_score
  from scene_sentences
  group by id, name
  order by name;
$$;

create or replace function public.create_study_scene(p_name text)
returns table (
  id uuid,
  name text,
  total_count integer,
  due_count integer,
  studied_count integer,
  reviewable_today_count integer,
  mastery_score integer
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_name text := btrim(coalesce(p_name, ''));
  v_scene_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;
  if char_length(v_name) < 2 or char_length(v_name) > 24 then
    raise exception 'Study scene name must be between 2 and 24 characters';
  end if;

  insert into public.study_scenes (user_id, name)
  values (auth.uid(), v_name)
  on conflict (user_id, name) do update
    set updated_at = now()
  returning study_scenes.id into v_scene_id;

  perform public.refresh_study_scene_matches(v_scene_id);

  return query
  select * from public.get_study_scenes() as scenes
  where scenes.id = v_scene_id;
end;
$$;

create or replace function public.get_study_scene_queue(
  p_scene_id uuid,
  p_limit integer default 1000
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
    from public.study_scenes scene
    join public.study_scene_sentences link on link.scene_id = scene.id
    join public.memory_sentences ms on ms.id = link.sentence_id
    join public.memories m on m.id = ms.memory_id
    left join public.sentence_study_progress sp
      on sp.sentence_id = ms.id
     and sp.user_id = auth.uid()
     and sp.study_scope = 'scene:' || scene.id::text
    where scene.id = p_scene_id
      and scene.user_id = auth.uid()
      and m.user_id = auth.uid()
      and (sp.last_studied_on is null or sp.last_studied_on < (now() at time zone 'Asia/Shanghai')::date)
  )
  select sentence_id, memory_id, english, chinese, image_path, memory_created_at,
         learning_step, mastered_review_count, correct_count, wrong_count, last_result, next_review_at
  from candidates
  where priority < 99
  order by priority asc, memory_created_at desc
  limit least(greatest(coalesce(p_limit, 1000), 1), 1000);
$$;

create or replace function public.get_studied_today_scene_queue(
  p_scene_id uuid,
  p_limit integer default 1000
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
  from public.study_scenes scene
  join public.study_scene_sentences link on link.scene_id = scene.id
  join public.memory_sentences ms on ms.id = link.sentence_id
  join public.memories m on m.id = ms.memory_id
  join public.sentence_study_progress sp
    on sp.sentence_id = ms.id
   and sp.user_id = auth.uid()
   and sp.study_scope = 'scene:' || scene.id::text
  where scene.id = p_scene_id
    and scene.user_id = auth.uid()
    and m.user_id = auth.uid()
    and sp.last_studied_on = (now() at time zone 'Asia/Shanghai')::date
  order by sp.last_studied_at asc nulls last, m.created_at desc
  limit least(greatest(coalesce(p_limit, 1000), 1), 1000);
$$;

-- Scene UUID scopes are longer than AI topic names, so enlarge the shared
-- scope constraint and allow the study-result RPC to validate scene ownership.
alter table public.sentence_study_progress
  drop constraint if exists sentence_study_progress_study_scope_check;
alter table public.sentence_study_progress
  add constraint sentence_study_progress_study_scope_check
  check (char_length(btrim(study_scope)) between 2 and 64);

create or replace function public.record_sentence_study_result(
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
  v_scene_id uuid;
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
  if char_length(v_scope) > 64
     or (v_scope <> 'favorites' and char_length(v_scope) < 2) then
    raise exception 'Invalid study scope';
  end if;

  if v_scope like 'scene:%' then
    begin
      v_scene_id := substr(v_scope, 7)::uuid;
    exception when others then
      raise exception 'Invalid study scene scope';
    end;
  end if;

  perform 1
  from public.memory_sentences ms
  join public.memories m on m.id = ms.memory_id
  where ms.id = p_sentence_id
    and m.user_id = auth.uid()
    and (
      (v_scope = 'favorites' and ms.is_favorite = true)
      or (v_scope not like 'scene:%' and v_scope <> 'favorites' and ms.study_topic = v_scope)
      or (v_scene_id is not null and exists (
        select 1
        from public.study_scene_sentences link
        join public.study_scenes scene on scene.id = link.scene_id
        where link.scene_id = v_scene_id
          and link.sentence_id = ms.id
          and scene.user_id = auth.uid()
      ))
    );
  if not found then
    raise exception 'Sentence not available for study';
  end if;

  select * into v_existing
  from public.sentence_study_progress
  where user_id = auth.uid() and sentence_id = p_sentence_id and study_scope = v_scope
  for update;
  if found and v_existing.last_studied_on = v_today then return v_existing; end if;

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
      v_next_review_at := ((v_today + case when v_mastered_review_count = 1 then 30 else 60 end)::timestamp at time zone 'Asia/Shanghai');
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
  ) on conflict (user_id, sentence_id, study_scope) do update set
    learning_step = excluded.learning_step,
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

revoke all on function public.create_study_scene(text) from public, anon;
grant execute on function public.create_study_scene(text) to authenticated;
revoke all on function public.get_study_scenes() from public, anon;
grant execute on function public.get_study_scenes() to authenticated;
revoke all on function public.get_study_scene_queue(uuid, integer) from public, anon;
grant execute on function public.get_study_scene_queue(uuid, integer) to authenticated;
revoke all on function public.get_studied_today_scene_queue(uuid, integer) from public, anon;
grant execute on function public.get_studied_today_scene_queue(uuid, integer) to authenticated;
revoke all on function public.refresh_study_scene_matches(uuid) from public, anon, authenticated;
revoke all on function public.study_scene_match_score(text, text, text, text, text[]) from public, anon, authenticated;
