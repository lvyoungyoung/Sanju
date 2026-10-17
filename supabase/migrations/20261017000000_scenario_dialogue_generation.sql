-- Named scenarios use flat A/B/A rows. Historical pair identities and receipts
-- remain byte-for-byte unchanged; title presence, not row count, selects family.
begin;

alter table public.memories drop constraint memories_dialogue_format_v1;
alter table public.memories add constraint memories_dialogue_format_v1
  check (dialogue_format in ('dialogue_tabs_v1','dialogue_trio_v1','scenario_dialogue_v1'));
alter table public.memories add column scenario_count integer;
alter table public.memories add constraint memories_scenario_count_v1 check (
  case when dialogue_format='scenario_dialogue_v1' then scenario_count is not null and scenario_count in (2,3)
    else scenario_count is null end);

create or replace function public.valid_generation_spec_v3(p_spec jsonb)
returns boolean language sql stable set search_path=pg_catalog,public,pg_temp as $$
  select coalesce(jsonb_typeof(p_spec)='object'
    and p_spec @> '{"schemaVersion":1,"catalogVersion":1}'::jsonb
    and p_spec->>'generationFormat' in ('dual_tabs_v1','dialogue_tabs_v1','dialogue_trio_v1','scenario_dialogue_v1')
    and p_spec->>'level' in ('starter','beginner','intermediate','advanced')
    and exists(select 1 from public.language_capabilities_v1 c
      where c.target_language=p_spec->>'targetLanguage' and c.translation_language=p_spec->>'translationLanguage'
        and c.teaching_locale=p_spec->>'teachingLocale'),false)
$$;

create or replace function public.valid_sentence_dialogue_v1(p_dialogue jsonb)
returns boolean language plpgsql immutable set search_path=pg_catalog,public,pg_temp as $$
declare title text;
begin
  if jsonb_typeof(p_dialogue) is distinct from 'object' then return false; end if;
  if not coalesce(p_dialogue->'index' in ('0'::jsonb,'1'::jsonb,'2'::jsonb),false)
    or exists(select 1 from jsonb_object_keys(p_dialogue) k where k not in ('index','turn','title')) then return false; end if;
  if p_dialogue ? 'title' then
    title:=p_dialogue->>'title';
    -- ECMAScript trim whitespace, including NBSP, ideographic space and BOM;
    -- Unicode code points are counted by PostgreSQL length, matching [...text].
    return coalesce(jsonb_typeof(p_dialogue->'title')='string'
      and length(title) between 1 and 24
      and title=btrim(title,U&'\0009\000A\000B\000C\000D\0020\00A0\1680\2000\2001\2002\2003\2004\2005\2006\2007\2008\2009\200A\2028\2029\202F\205F\3000\FEFF')
      and title !~ U&'[\0001-\001F\007F-\009F]'
      and p_dialogue->'turn' in ('0'::jsonb,'1'::jsonb,'2'::jsonb),false);
  end if;
  return coalesce(p_dialogue->'turn' in ('0'::jsonb,'1'::jsonb),false);
end;
$$;

create or replace function public.valid_sentence_collection_v1(p_sentences jsonb,p_format text default null)
returns boolean language plpgsql immutable set search_path=pg_catalog,public,pg_temp as $$
declare n integer; has_dialogue boolean; has_title boolean;
begin
  if jsonb_typeof(p_sentences) is distinct from 'array' then return false; end if;
  n:=jsonb_array_length(p_sentences);
  select exists(select 1 from jsonb_array_elements(p_sentences) s
    where nullif(s->'dialogue','null'::jsonb) is not null),
    exists(select 1 from jsonb_array_elements(p_sentences) s where s->'dialogue' ? 'title')
    into has_dialogue,has_title;
  if p_format is not null and p_format not in ('dual_tabs_v1','dialogue_tabs_v1','dialogue_trio_v1','scenario_dialogue_v1') then return false; end if;
  if p_format='scenario_dialogue_v1' or has_title then
    if (p_format is not null and p_format<>'scenario_dialogue_v1') or n not in (6,9) then return false; end if;
    if exists(select 1 from jsonb_array_elements(p_sentences) s
      where not public.valid_sentence_dialogue_v1(s->'dialogue')
        or not coalesce(s->'dialogue' ? 'title',false)
        or s->>'presentationGroup' is distinct from 'what_i_say'
        or (n=6 and s->'dialogue'->'index'='2'::jsonb)) then return false; end if;
    -- Bounded indices + unique turns exhaust exactly 2 or 3 complete scenarios.
    return (select count(distinct jsonb_build_array(s->'dialogue'->'index',s->'dialogue'->'turn'))=n
        and count(distinct s->'dialogue'->>'title')=n/3 from jsonb_array_elements(p_sentences) s)
      and not exists(select 1 from jsonb_array_elements(p_sentences) s
        group by s->'dialogue'->'index' having count(distinct s->'dialogue'->>'title')<>1);
  end if;
  if p_format='dialogue_trio_v1' or (p_format is null and has_dialogue and n=6) then
    if n<>6 then return false; end if;
    if exists(select 1 from jsonb_array_elements(p_sentences) s
      where not public.valid_sentence_dialogue_v1(s->'dialogue')
        or not coalesce(s->>'presentationGroup' in ('what_i_see','what_i_say'),false)
        or (s->'dialogue'->'index'='0'::jsonb and s->>'presentationGroup'<>'what_i_see')
        or (s->'dialogue'->'index'='2'::jsonb and s->>'presentationGroup'<>'what_i_say')) then return false; end if;
    return (select count(distinct jsonb_build_array(s->'dialogue'->'index',s->'dialogue'->'turn'))=6
      from jsonb_array_elements(p_sentences) s)
      and (select count(distinct s->>'presentationGroup')=1
        from jsonb_array_elements(p_sentences) s where s->'dialogue'->'index'='1'::jsonb);
  end if;
  if p_format='dialogue_tabs_v1' or has_dialogue or n=12 then
    if p_format='dual_tabs_v1' or n<>12 then return false; end if;
    if exists(select 1 from jsonb_array_elements(p_sentences) s
      where not public.valid_sentence_dialogue_v1(s->'dialogue')
        or not coalesce(s->>'presentationGroup' in ('what_i_see','what_i_say'),false)) then return false; end if;
    return (select count(distinct jsonb_build_array(s->'presentationGroup',s->'dialogue'->'index',s->'dialogue'->'turn'))=12
      from jsonb_array_elements(p_sentences) s);
  end if;
  if p_format='dual_tabs_v1' then
    return n=6 and (select count(*)=3 from jsonb_array_elements(p_sentences) s where s->>'presentationGroup'='what_i_see')
      and (select count(*)=3 from jsonb_array_elements(p_sentences) s where s->>'presentationGroup'='what_i_say');
  end if;
  return n in (3,6);
end;
$$;

create or replace function public.protect_memory_content_v2()
returns trigger language plpgsql set search_path=pg_catalog,public,pg_temp as $$
begin
  if tg_op='UPDATE' and
    (new.id,new.user_id,new.target_language,new.translation_language,new.teaching_locale,
     new.content_schema_version,new.created_at,new.image_url,new.generation_spec,new.dialogue_format,new.scenario_count)
    is distinct from
    (old.id,old.user_id,old.target_language,old.translation_language,old.teaching_locale,
     old.content_schema_version,old.created_at,old.image_url,old.generation_spec,old.dialogue_format,old.scenario_count) then
    raise exception 'immutable_content' using errcode='22023';
  end if;
  if current_user in ('anon','authenticated') then
    if not public.is_legacy_content_v1(new.target_language,new.translation_language,new.teaching_locale)
      or (tg_op='INSERT' and (new.generation_spec is not null or new.dialogue_format is not null or new.scenario_count is not null)) then
      raise exception 'legacy_content_only' using errcode='42501'; end if;
    if tg_op='UPDATE' and to_jsonb(new) is distinct from to_jsonb(old) then
      raise exception 'immutable_content' using errcode='22023'; end if;
  end if;
  return new;
end;
$$;

create or replace function public.insert_memory_content_v2(p_user_id uuid,p_memory jsonb,p_spec jsonb default null,p_provider text default null)
returns void language plpgsql set search_path=pg_catalog,public,pg_temp as $$
declare item record; c jsonb:=p_memory->'context'; mid uuid:=(p_memory->>'id')::uuid; named boolean;
begin
  perform public.validate_memory_import_v1(p_memory,p_user_id);
  if p_spec is not null and not public.valid_sentence_collection_v1(p_memory->'sentences',p_spec->>'generationFormat') then
    raise exception 'invalid_content'; end if;
  select exists(select 1 from jsonb_array_elements(p_memory->'sentences') s where s->'dialogue' ? 'title') into named;
  insert into public.memories(id,user_id,image_url,created_at,tags,provider,target_language,translation_language,teaching_locale,content_schema_version,generation_spec,dialogue_format,scenario_count)
  values(mid,p_user_id,p_memory->>'imagePath',(p_memory->>'createdAt')::timestamptz,
    array(select jsonb_array_elements_text(p_memory->'tags')),p_provider,c->>'targetLanguage',c->>'translationLanguage',c->>'teachingLocale',2,p_spec,
    case when named then 'scenario_dialogue_v1'
      when exists(select 1 from jsonb_array_elements(p_memory->'sentences') s where nullif(s->'dialogue','null'::jsonb) is not null) then
        case when jsonb_array_length(p_memory->'sentences')=6 then 'dialogue_trio_v1' else 'dialogue_tabs_v1' end
    end,case when named then jsonb_array_length(p_memory->'sentences')/3 end);
  for item in select value,ordinality from jsonb_array_elements(p_memory->'sentences') with ordinality loop
    insert into public.memory_sentences(id,memory_id,sort_order,target_text,translation_text,content_version,learning_material,presentation_group,is_favorite,dialogue)
    values((item.value->>'id')::uuid,mid,item.ordinality-1,item.value->>'targetText',item.value->>'translationText',1,
      nullif(item.value->'learningMaterial','null'::jsonb),item.value->>'presentationGroup',
      (item.value->>'isFavorite')::boolean,nullif(item.value->'dialogue','null'::jsonb));
  end loop;
end;
$$;

create or replace function public.protect_dialogue_collection_v1()
returns trigger language plpgsql security definer set search_path=pg_catalog,public,pg_temp as $$
declare mid uuid; format text; expected_scenarios integer; sentences jsonb;
begin
  mid:=case when tg_op='DELETE' then old.memory_id else new.memory_id end;
  select dialogue_format,scenario_count into format,expected_scenarios from public.memories where id=mid;
  if not found then return null; end if;
  select coalesce(jsonb_agg(jsonb_build_object('presentationGroup',presentation_group,'dialogue',dialogue)),'[]'::jsonb)
    into sentences from public.memory_sentences where memory_id=mid;
  if format is not null
    or (tg_op='DELETE' and old.dialogue is not null)
    or exists(select 1 from public.memory_sentences where memory_id=mid and dialogue is not null) then
    if format is null or not public.valid_sentence_collection_v1(sentences,format)
      or (format='scenario_dialogue_v1' and jsonb_array_length(sentences) is distinct from expected_scenarios*3) then
      raise exception 'invalid_dialogue_collection' using errcode='22023'; end if;
  end if;
  return null;
end;
$$;

-- Existing claim/finalize/terminal-state guards apply the random middle policy
-- only to dialogue_trio_v1. Their transactional locks, debits and ACLs remain.
-- Collection triggers pin format and scenario count; DTOs and receipt identities already
-- carry the entire dialogue JSON, including the title. No rewrites are needed.
-- CREATE OR REPLACE retains all existing function grants and security modes.
notify pgrst,'reload schema';
commit;
