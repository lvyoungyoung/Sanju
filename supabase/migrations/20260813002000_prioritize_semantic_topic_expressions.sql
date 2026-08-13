-- Expression quality is based on topic relevance and learning value, not on
-- literal repetition. A selected expression still needs at least one real
-- example sentence from its topic.
alter table public.study_topic_expressions
  drop constraint if exists study_topic_expressions_occurrence_count_check;

alter table public.study_topic_expressions
  add constraint study_topic_expressions_occurrence_count_check
  check (occurrence_count >= 1);

-- Results generated under the old repetition-only rule should never be reused.
delete from public.study_topic_expressions;
delete from public.study_topic_expression_sets;

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
      or v_occurrence_count < 1 then
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
      limit 2
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

revoke all on function public.replace_study_topic_expressions(uuid, text, text, jsonb) from public, anon, authenticated;
grant execute on function public.replace_study_topic_expressions(uuid, text, text, jsonb) to service_role;
