-- Cache high-value vocabulary and phrases distilled from a topic's own
-- sentences. The source fingerprint makes the cache self-invalidating whenever
-- its matched sentence set changes.
create table if not exists public.study_topic_expression_sets (
  user_id uuid not null references auth.users(id) on delete cascade,
  topic_key text not null check (char_length(btrim(topic_key)) between 1 and 80),
  source_fingerprint text not null check (char_length(source_fingerprint) = 64),
  generated_at timestamptz not null default now(),
  primary key (user_id, topic_key)
);

create table if not exists public.study_topic_expressions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  topic_key text not null check (char_length(btrim(topic_key)) between 1 and 80),
  kind text not null check (kind in ('word', 'phrase')),
  english text not null check (char_length(btrim(english)) between 1 and 120),
  chinese text not null check (char_length(btrim(chinese)) between 1 and 120),
  part_of_speech text,
  occurrence_count integer not null check (occurrence_count >= 2),
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  unique (user_id, topic_key, kind, english)
);

create table if not exists public.study_topic_expression_examples (
  expression_id uuid not null references public.study_topic_expressions(id) on delete cascade,
  sentence_id uuid not null references public.memory_sentences(id) on delete cascade,
  sort_order integer not null default 0,
  primary key (expression_id, sentence_id)
);

create index if not exists study_topic_expressions_owner_topic_kind_idx
  on public.study_topic_expressions (user_id, topic_key, kind, sort_order);

create index if not exists study_topic_expression_examples_expression_idx
  on public.study_topic_expression_examples (expression_id, sort_order);

-- A deleted custom topic must not leave its generated expression cache behind.
create or replace function public.cleanup_deleted_study_scene_expressions()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_topic_key text := 'scene:' || old.id::text;
begin
  delete from public.study_topic_expressions
  where user_id = old.user_id
    and topic_key = v_topic_key;

  delete from public.study_topic_expression_sets
  where user_id = old.user_id
    and topic_key = v_topic_key;

  return old;
end;
$$;

drop trigger if exists cleanup_deleted_study_scene_expressions on public.study_scenes;
create trigger cleanup_deleted_study_scene_expressions
after delete on public.study_scenes
for each row execute function public.cleanup_deleted_study_scene_expressions();

alter table public.study_topic_expression_sets enable row level security;
alter table public.study_topic_expressions enable row level security;
alter table public.study_topic_expression_examples enable row level security;

drop policy if exists study_topic_expression_sets_owner_read on public.study_topic_expression_sets;
create policy study_topic_expression_sets_owner_read on public.study_topic_expression_sets
  for select using (auth.uid() = user_id);

drop policy if exists study_topic_expressions_owner_read on public.study_topic_expressions;
create policy study_topic_expressions_owner_read on public.study_topic_expressions
  for select using (auth.uid() = user_id);

drop policy if exists study_topic_expression_examples_owner_read on public.study_topic_expression_examples;
create policy study_topic_expression_examples_owner_read on public.study_topic_expression_examples
  for select using (
    exists (
      select 1
      from public.study_topic_expressions expression
      where expression.id = study_topic_expression_examples.expression_id
        and expression.user_id = auth.uid()
    )
  );

-- The service-role extraction function is the only writer. It atomically
-- replaces one topic's stale extraction while verifying every linked example.
create or replace function public.replace_study_topic_expressions(
  p_user_id uuid,
  p_topic_key text,
  p_source_fingerprint text,
  p_expressions jsonb
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_topic_key text := btrim(coalesce(p_topic_key, ''));
  v_expression jsonb;
  v_expression_id uuid;
  v_kind text;
  v_english text;
  v_chinese text;
  v_part_of_speech text;
  v_occurrence_count integer;
  v_sort_order integer := 0;
  v_sentence_id uuid;
  v_example_order integer;
  v_is_topic_sentence boolean;
begin
  if p_user_id is null or v_topic_key = '' or char_length(v_topic_key) > 80 then
    raise exception 'Invalid study topic expression owner or topic';
  end if;
  if p_source_fingerprint !~ '^[0-9a-f]{64}$' then
    raise exception 'Invalid study topic expression fingerprint';
  end if;
  if p_expressions is null or jsonb_typeof(p_expressions) <> 'array' then
    raise exception 'Invalid study topic expressions';
  end if;

  delete from public.study_topic_expressions
  where user_id = p_user_id
    and topic_key = v_topic_key;

  for v_expression in select value from jsonb_array_elements(p_expressions)
  loop
    v_kind := nullif(btrim(v_expression ->> 'kind'), '');
    v_english := left(nullif(btrim(v_expression ->> 'english'), ''), 120);
    v_chinese := left(nullif(btrim(v_expression ->> 'chinese'), ''), 120);
    v_part_of_speech := left(nullif(btrim(v_expression ->> 'part_of_speech'), ''), 40);
    v_occurrence_count := greatest(coalesce(nullif(v_expression ->> 'occurrence_count', '')::integer, 0), 0);

    if v_kind not in ('word', 'phrase')
      or v_english is null
      or v_chinese is null
      or v_occurrence_count < 2 then
      continue;
    end if;

    v_sort_order := v_sort_order + 1;
    insert into public.study_topic_expressions (
      user_id, topic_key, kind, english, chinese, part_of_speech,
      occurrence_count, sort_order
    ) values (
      p_user_id, v_topic_key, v_kind, v_english, v_chinese, v_part_of_speech,
      v_occurrence_count, v_sort_order
    ) returning id into v_expression_id;

    v_example_order := 0;
    for v_sentence_id in
      select value::uuid
      from jsonb_array_elements_text(coalesce(v_expression -> 'sentence_ids', '[]'::jsonb))
      where value ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      limit 3
    loop
      v_is_topic_sentence := case
        when v_topic_key = 'favorites' then exists (
          select 1
          from public.memory_sentences sentence
          join public.memories memory on memory.id = sentence.memory_id
          where sentence.id = v_sentence_id
            and memory.user_id = p_user_id
            and sentence.is_favorite = true
        )
        when v_topic_key ~ '^scene:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then exists (
          select 1
          from public.study_scene_sentences link
          join public.study_scenes scene on scene.id = link.scene_id
          join public.memory_sentences sentence on sentence.id = link.sentence_id
          join public.memories memory on memory.id = sentence.memory_id
          where link.scene_id = substring(v_topic_key from 7)::uuid
            and link.sentence_id = v_sentence_id
            and scene.user_id = p_user_id
            and memory.user_id = p_user_id
        )
        else false
      end;

      if v_is_topic_sentence then
        v_example_order := v_example_order + 1;
        insert into public.study_topic_expression_examples (expression_id, sentence_id, sort_order)
        values (v_expression_id, v_sentence_id, v_example_order)
        on conflict do nothing;
      end if;
    end loop;

    if v_example_order = 0 then
      delete from public.study_topic_expressions where id = v_expression_id;
    end if;
  end loop;

  insert into public.study_topic_expression_sets (user_id, topic_key, source_fingerprint, generated_at)
  values (p_user_id, v_topic_key, p_source_fingerprint, now())
  on conflict (user_id, topic_key) do update set
    source_fingerprint = excluded.source_fingerprint,
    generated_at = excluded.generated_at;
end;
$$;

create or replace function public.get_study_topic_expressions(
  p_topic_key text,
  p_source_fingerprint text
)
returns table (
  id uuid,
  kind text,
  english text,
  chinese text,
  part_of_speech text,
  occurrence_count integer,
  examples jsonb
)
language sql
security definer
set search_path = public, pg_temp
as $$
  select
    expression.id,
    expression.kind,
    expression.english,
    expression.chinese,
    expression.part_of_speech,
    expression.occurrence_count,
    coalesce(
      jsonb_agg(
        jsonb_build_object(
          'id', sentence.id,
          'english', sentence.english,
          'chinese', sentence.chinese
        ) order by example.sort_order
      ) filter (where sentence.id is not null),
      '[]'::jsonb
    ) as examples
  from public.study_topic_expression_sets expression_set
  join public.study_topic_expressions expression
    on expression.user_id = expression_set.user_id
   and expression.topic_key = expression_set.topic_key
  left join public.study_topic_expression_examples example
    on example.expression_id = expression.id
  left join public.memory_sentences sentence
    on sentence.id = example.sentence_id
  where auth.uid() is not null
    and expression_set.user_id = auth.uid()
    and expression_set.topic_key = btrim(coalesce(p_topic_key, ''))
    and expression_set.source_fingerprint = p_source_fingerprint
  group by
    expression.id,
    expression.kind,
    expression.english,
    expression.chinese,
    expression.part_of_speech,
    expression.occurrence_count,
    expression.sort_order
  order by expression.kind, expression.sort_order, expression.english;
$$;

revoke all on function public.replace_study_topic_expressions(uuid, text, text, jsonb) from public, anon, authenticated;
grant execute on function public.replace_study_topic_expressions(uuid, text, text, jsonb) to service_role;

revoke all on function public.get_study_topic_expressions(text, text) from public, anon;
grant execute on function public.get_study_topic_expressions(text, text) to authenticated;

create or replace function public.get_study_topic_source_sentences(
  p_topic_key text,
  p_limit integer default 120
)
returns table (
  id uuid,
  english text,
  chinese text
)
language sql
security definer
set search_path = public, pg_temp
as $$
  select sentence.id, sentence.english, sentence.chinese
  from public.memory_sentences sentence
  join public.memories memory on memory.id = sentence.memory_id
  where auth.uid() is not null
    and memory.user_id = auth.uid()
    and (
      (p_topic_key = 'favorites' and sentence.is_favorite = true)
      or (
        p_topic_key ~ '^scene:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
        and exists (
          select 1
          from public.study_scene_sentences link
          join public.study_scenes scene on scene.id = link.scene_id
          where link.scene_id = substring(p_topic_key from 7)::uuid
            and link.sentence_id = sentence.id
            and scene.user_id = auth.uid()
        )
      )
    )
  order by memory.created_at desc, sentence.sort_order asc
  limit least(greatest(coalesce(p_limit, 120), 1), 120);
$$;

revoke all on function public.get_study_topic_source_sentences(text, integer) from public, anon;
grant execute on function public.get_study_topic_source_sentences(text, integer) to authenticated;
