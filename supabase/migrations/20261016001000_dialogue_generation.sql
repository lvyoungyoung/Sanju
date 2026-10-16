-- Add dialogue structure without rewriting historical records or import receipts.
begin;

-- Replace the six-sentence bound from 20260826001000, retaining zero-based
-- ordering and all existing positions while allowing the full dialogue photo.
alter table public.memory_sentences drop constraint if exists memory_sentences_sort_order_check;
alter table public.memory_sentences add constraint memory_sentences_sort_order_check
  check (sort_order >= 0 and sort_order < 12);

create function public.valid_sentence_dialogue_v1(p_dialogue jsonb)
returns boolean language plpgsql immutable set search_path=pg_catalog,public,pg_temp as $$
begin
  if jsonb_typeof(p_dialogue) is distinct from 'object' then return false; end if;
  return coalesce(p_dialogue->'index' in ('0'::jsonb,'1'::jsonb,'2'::jsonb)
    and p_dialogue->'turn' in ('0'::jsonb,'1'::jsonb)
    and not exists(select 1 from jsonb_object_keys(p_dialogue) k where k not in ('index','turn')),false);
end;
$$;

create function public.valid_sentence_collection_v1(p_sentences jsonb,p_format text default null)
returns boolean language plpgsql immutable set search_path=pg_catalog,public,pg_temp as $$
declare n integer; has_dialogue boolean;
begin
  if jsonb_typeof(p_sentences) is distinct from 'array' then return false; end if;
  n:=jsonb_array_length(p_sentences);
  select exists(select 1 from jsonb_array_elements(p_sentences) s
    where nullif(s->'dialogue','null'::jsonb) is not null) into has_dialogue;
  if p_format is not null and p_format not in ('dual_tabs_v1','dialogue_tabs_v1') then return false; end if;
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

alter table public.memory_sentences add column dialogue jsonb,
  add constraint memory_sentences_dialogue_v1 check (dialogue is null or public.valid_sentence_dialogue_v1(dialogue));
create unique index memory_sentences_dialogue_turn_v1
  on public.memory_sentences(memory_id,presentation_group,(dialogue->'index'),(dialogue->'turn'))
  where dialogue is not null;

create or replace function public.valid_generation_spec_v3(p_spec jsonb)
returns boolean language sql stable set search_path = pg_catalog, public, pg_temp as $$
  select coalesce(jsonb_typeof(p_spec) = 'object'
    and p_spec @> '{"schemaVersion":1,"catalogVersion":1}'::jsonb
    and p_spec->>'generationFormat' in ('dual_tabs_v1','dialogue_tabs_v1')
    and p_spec->>'level' in ('starter','beginner','intermediate','advanced')
    and exists (select 1 from public.language_capabilities_v1 c
      where c.target_language=p_spec->>'targetLanguage' and c.translation_language=p_spec->>'translationLanguage'
        and c.teaching_locale=p_spec->>'teachingLocale'),false)
$$;

alter table public.memories drop constraint memories_generation_spec_v1;
alter table public.memories add constraint memories_generation_spec_v1 check (generation_spec is null or (
  public.valid_generation_spec_v3(generation_spec)
  and generation_spec @> jsonb_build_object('targetLanguage',target_language,
    'translationLanguage',translation_language,'teachingLocale',teaching_locale)));

create or replace function public.validate_memory_import_v1(p_memory jsonb,p_user_id uuid)
returns void language plpgsql set search_path=pg_catalog,public,pg_temp as $$
declare s jsonb; ids uuid[] := '{}'; sid uuid; mid uuid; c jsonb; material jsonb;
begin
  mid:=(p_memory->>'id')::uuid; c:=p_memory->'context';
  if p_user_id is null or mid is null or not coalesce(p_memory @> '{"schemaVersion":2}'::jsonb,false)
    or not coalesce(c @> '{"schemaVersion":2}'::jsonb,false)
    or not public.valid_generation_spec_v3(c||'{"schemaVersion":1,"catalogVersion":1,"generationFormat":"dual_tabs_v1","level":"intermediate"}'::jsonb)
    or jsonb_typeof(p_memory->'sentences') is distinct from 'array'
    or jsonb_typeof(p_memory->'tags') is distinct from 'array'
    or jsonb_typeof(p_memory->'imagePath') is distinct from 'string'
    or p_memory->>'imagePath' not in ('',p_user_id::text||'/'||mid::text||'.jpg')
    or (p_memory->>'createdAt')::timestamptz is null
    or not isfinite((p_memory->>'createdAt')::timestamptz) then raise exception 'invalid_content' using errcode='22023'; end if;
  if not public.valid_sentence_collection_v1(p_memory->'sentences') or jsonb_array_length(p_memory->'tags')>3
    or exists(select 1 from jsonb_array_elements(p_memory->'tags') t where jsonb_typeof(t)<>'string' or t#>>'{}' !~ '^[a-z][a-z0-9_]{0,79}$') then raise exception 'invalid_content'; end if;
  for s in select value from jsonb_array_elements(p_memory->'sentences') loop
    sid:=(s->>'id')::uuid;
    if sid is null or sid=any(ids) or jsonb_typeof(s->'targetText') is distinct from 'string'
      or length(btrim(s->>'targetText')) not between 1 and 2000
      or jsonb_typeof(s->'translationText') is distinct from 'string' or length(btrim(s->>'translationText')) not between 1 and 2000
      or not coalesce(s @> '{"contentVersion":1}'::jsonb,false)
      or not coalesce(s->>'presentationGroup' in ('what_i_see','what_i_say'),false)
      or jsonb_typeof(s->'isFavorite') is distinct from 'boolean' then raise exception 'invalid_content'; end if;
    material:=nullif(s->'learningMaterial','null'::jsonb);
    if not public.valid_learning_material_v1(material,s->>'targetText')
      or (c->>'targetLanguage'<>'en' and (material is null or not exists (
        select 1 from jsonb_array_elements(material->'segments') segment where segment->>'canBlank'='true'))) then
      raise exception 'invalid_learning_material';
    end if;
    ids:=array_append(ids,sid);
  end loop;
end;
$$;

create or replace function public.insert_memory_content_v2(p_user_id uuid,p_memory jsonb,p_spec jsonb default null,p_provider text default null)
returns void language plpgsql set search_path=pg_catalog,public,pg_temp as $$
declare item record; c jsonb:=p_memory->'context'; mid uuid:=(p_memory->>'id')::uuid;
begin
  perform public.validate_memory_import_v1(p_memory,p_user_id);
  if p_spec is not null and not public.valid_sentence_collection_v1(p_memory->'sentences',p_spec->>'generationFormat') then
    raise exception 'invalid_content'; end if;
  insert into public.memories(id,user_id,image_url,created_at,tags,provider,target_language,translation_language,teaching_locale,content_schema_version,generation_spec)
  values(mid,p_user_id,p_memory->>'imagePath',(p_memory->>'createdAt')::timestamptz,
    array(select jsonb_array_elements_text(p_memory->'tags')),p_provider,c->>'targetLanguage',c->>'translationLanguage',c->>'teachingLocale',2,p_spec);
  for item in select value,ordinality from jsonb_array_elements(p_memory->'sentences') with ordinality loop
    insert into public.memory_sentences(id,memory_id,sort_order,target_text,translation_text,content_version,learning_material,presentation_group,is_favorite,dialogue)
    values((item.value->>'id')::uuid,mid,item.ordinality-1,item.value->>'targetText',item.value->>'translationText',1,
      nullif(item.value->'learningMaterial','null'::jsonb),
      item.value->>'presentationGroup',(item.value->>'isFavorite')::boolean,nullif(item.value->'dialogue','null'::jsonb));
  end loop;
end;
$$;

create or replace function public.finalize_generation_job_v3(p_user_id uuid,p_request_id uuid,p_is_anonymous boolean,
  p_request_fingerprint text,p_memory jsonb,p_provider text)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,pg_temp as $$
declare j record; balance integer; c jsonb; m jsonb:=p_memory;
begin
  m:=jsonb_set(m,'{sentences}',public.strip_sentence_metadata_v1(m->'sentences'));
  if p_is_anonymous then select * into j from public.guest_generation_jobs where id=p_request_id and user_id=p_user_id for update;
  else select * into j from public.generation_jobs where client_request_id=p_request_id and user_id=p_user_id for update; end if;
  if not found then raise exception 'generation_job_not_found'; end if;
  if j.request_schema_version<>3 or j.request_fingerprint is distinct from p_request_fingerprint then raise exception 'request_context_mismatch'; end if;
  if j.status in ('completed','acknowledged') then return public.recover_generation_job_v2(p_user_id,p_request_id,p_is_anonymous,p_request_fingerprint); end if;
  if j.status<>'pending' then raise exception 'generation_failed'; end if;
  c:=jsonb_build_object('schemaVersion',2,'targetLanguage',j.generation_spec->>'targetLanguage',
    'translationLanguage',j.generation_spec->>'translationLanguage','teachingLocale',j.generation_spec->>'teachingLocale');
  if m->'context' is distinct from c or not public.valid_sentence_collection_v1(m->'sentences',j.generation_spec->>'generationFormat')
    or exists(select 1 from jsonb_array_elements(m->'sentences') s where s->>'isFavorite'<>'false') then raise exception 'invalid_content'; end if;
  if p_is_anonymous then
    if (m->>'id')::uuid<>p_request_id or m->>'imagePath' is distinct from j.image_path then raise exception 'request_context_mismatch'; end if;
    -- Guest storage is private and separate; local/import DTOs do not reuse its path.
    m:=jsonb_set(m,'{imagePath}','""'::jsonb);
  end if;
  perform public.validate_memory_import_v1(m,p_user_id);
  select available_generations into balance from public.profiles where id=p_user_id for update;
  if not found then raise exception 'profile_not_found'; end if;
  if coalesce(balance,0)<=0 then raise exception 'No credits left'; end if;
  balance:=balance-1;
  if p_is_anonymous then
    update public.guest_generation_jobs set status='completed',result_content=m,sentences=m->'sentences',
      tags=array(select jsonb_array_elements_text(m->'tags')),provider=p_provider,remaining_credits=balance,completed_at=now(),error_message=null
    where id=p_request_id and user_id=p_user_id;
  else
    perform public.insert_memory_content_v2(p_user_id,m,j.generation_spec,p_provider);
    update public.generation_jobs set status='completed',memory_id=(m->>'id')::uuid,image_path=m->>'imagePath',provider=p_provider,
      remaining_credits=balance,completed_at=now(),updated_at=now(),error_message=null,failed_at=null
    where client_request_id=p_request_id and user_id=p_user_id;
  end if;
  update public.profiles set available_generations=balance where id=p_user_id;
  insert into public.generation_transactions(user_id,delta,balance_after,reason,note)
    values(p_user_id,-1,balance,'generate',case when p_is_anonymous then 'guest_job_id:' else 'memory_id:' end||(m->>'id'));
  return public.recover_generation_job_v2(p_user_id,p_request_id,p_is_anonymous,p_request_fingerprint);
end;
$$;

create or replace function public.memory_content_dto_v2(p_memory_id uuid)
returns jsonb language sql stable
set search_path = pg_catalog, public, pg_temp
as $$
  select jsonb_build_object('schemaVersion',2,'id',m.id,'createdAt',m.created_at,'imagePath',coalesce(m.image_url,''),
    'tags',coalesce(to_jsonb(m.tags),'[]'::jsonb),
    'context',jsonb_build_object('schemaVersion',2,'targetLanguage',m.target_language,
      'translationLanguage',m.translation_language,'teachingLocale',m.teaching_locale),
    'sentences',coalesce((select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
      'id',s.id,'targetText',s.target_text,'translationText',s.translation_text,'contentVersion',s.content_version,
      'presentationGroup',s.presentation_group,'isFavorite',s.is_favorite,'learningMaterial',s.learning_material,'dialogue',s.dialogue))
      order by s.sort_order,s.id) from public.memory_sentences s where s.memory_id=m.id),'[]'::jsonb))
  from public.memories m where m.id=p_memory_id
$$;

-- Omit dialogue entirely for old singles: adding a null key would invalidate
-- existing receipt digests, including receipts whose memories were deleted.
create or replace function public.immutable_memory_identity_v1(p_memory jsonb)
returns jsonb language sql immutable set search_path=pg_catalog,public,pg_temp as $$
  select jsonb_build_object('id',p_memory->'id','context',p_memory->'context','createdAt',
    to_jsonb((p_memory->>'createdAt')::timestamptz),'sentences',(select jsonb_agg(jsonb_build_object(
      'id',s->'id','targetText',s->'targetText','translationText',s->'translationText','contentVersion',s->'contentVersion',
      'presentationGroup',s->'presentationGroup') ||
      case when nullif(s->'dialogue','null'::jsonb) is null then '{}'::jsonb
        else jsonb_build_object('dialogue',s->'dialogue') end order by s->>'id') from jsonb_array_elements(p_memory->'sentences') s))
$$;

create or replace function public.protect_generation_context_v3()
returns trigger language plpgsql set search_path = pg_catalog, public, pg_temp as $$
begin
  if (new.request_schema_version,new.generation_spec,new.request_fingerprint,new.generation_policy)
    is distinct from (old.request_schema_version,old.generation_spec,old.request_fingerprint,old.generation_policy) then
    raise exception 'request_context_mismatch' using errcode='22023';
  end if;
  if tg_table_name='guest_generation_jobs' then
    if old.status in ('completed','acknowledged') and new.result_content is distinct from old.result_content then
      raise exception 'immutable_generation_result'; end if;
  end if;
  if new.request_schema_version=3 and old.status='pending' and new.status='completed' then
    if tg_table_name='generation_jobs' then
      if not exists(select 1 from public.memories m where m.id=new.memory_id and m.user_id=new.user_id
        and m.generation_spec=new.generation_spec) then raise exception 'request_context_mismatch'; end if;
    elsif new.result_content is null or new.result_content->'context' is distinct from jsonb_build_object(
      'schemaVersion',2,'targetLanguage',new.generation_spec->>'targetLanguage',
      'translationLanguage',new.generation_spec->>'translationLanguage','teachingLocale',new.generation_spec->>'teachingLocale')
      or not public.valid_sentence_collection_v1(new.result_content->'sentences',new.generation_spec->>'generationFormat') then
      raise exception 'request_context_mismatch';
    end if;
  end if;
  return new;
end;
$$;

create or replace function public.project_sentence_content_v2()
returns trigger language plpgsql
set search_path = pg_catalog, public, pg_temp
as $$
declare v_legacy boolean;
begin
  select public.is_legacy_content_v1(m.target_language,m.translation_language,m.teaching_locale)
    into v_legacy from public.memories m where m.id = new.memory_id;
  if v_legacy is null then raise exception 'memory_not_found' using errcode = '42501'; end if;
  if tg_op = 'INSERT' and v_legacy then
    new.target_text := coalesce(new.target_text,new.english);
    new.translation_text := coalesce(new.translation_text,new.chinese);
  end if;
  -- Test the submitted legacy projection before replacing it; stale UPSERTs
  -- must not silently overwrite or appear to accept different content.
  if (new.english is not null and new.english is distinct from new.target_text)
    or (new.chinese is not null and new.chinese is distinct from new.translation_text) then
    raise exception 'content_projection_mismatch' using errcode = '22023';
  end if;
  if tg_op = 'UPDATE' and
    (new.id,new.memory_id,new.target_text,new.translation_text,new.content_version,new.presentation_group,new.sort_order,new.dialogue)
    is distinct from
    (old.id,old.memory_id,old.target_text,old.translation_text,old.content_version,old.presentation_group,old.sort_order,old.dialogue) then
    raise exception 'immutable_content' using errcode = '22023';
  end if;
  if current_user in ('anon','authenticated') then
    if not v_legacy then raise exception 'legacy_content_only' using errcode = '42501'; end if;
    if (tg_op = 'INSERT' and (new.learning_material is not null or new.dialogue is not null))
      or (tg_op = 'UPDATE' and (to_jsonb(new) - 'is_favorite') is distinct from (to_jsonb(old) - 'is_favorite')) then
      raise exception 'immutable_content' using errcode = '22023';
    end if;
  end if;
  new.english := case when v_legacy then new.target_text else null end;
  new.chinese := case when v_legacy then new.translation_text else null end;
  return new;
end;
$$;

-- Defer cross-row completeness until all 12 rows have been inserted. Legacy
-- singles are untouched; a whole-memory cascade delete remains valid.
create function public.protect_dialogue_collection_v1()
returns trigger language plpgsql security definer set search_path=pg_catalog,public,pg_temp as $$
declare mid uuid; spec jsonb; sentences jsonb;
begin
  mid:=case when tg_op='DELETE' then old.memory_id else new.memory_id end;
  select generation_spec into spec from public.memories where id=mid;
  if not found then return null; end if;
  select coalesce(jsonb_agg(jsonb_build_object('presentationGroup',presentation_group,'dialogue',dialogue)),'[]'::jsonb)
    into sentences from public.memory_sentences where memory_id=mid;
  if spec->>'generationFormat'='dialogue_tabs_v1'
    or (tg_op='DELETE' and old.dialogue is not null)
    or exists(select 1 from public.memory_sentences where memory_id=mid and dialogue is not null) then
    if not public.valid_sentence_collection_v1(sentences,'dialogue_tabs_v1') then
      raise exception 'invalid_dialogue_collection' using errcode='22023'; end if;
  end if;
  return null;
end;
$$;
create constraint trigger protect_dialogue_collection_v1
after insert or update or delete on public.memory_sentences
deferrable initially deferred for each row execute function public.protect_dialogue_collection_v1();

revoke all on function public.valid_sentence_dialogue_v1(jsonb),
  public.valid_sentence_collection_v1(jsonb,text),public.protect_dialogue_collection_v1()
  from public,anon,authenticated;
grant execute on function public.valid_sentence_dialogue_v1(jsonb),
  public.valid_sentence_collection_v1(jsonb,text),public.protect_dialogue_collection_v1()
  to service_role;
-- Pure row validation is also needed by existing direct favorite updates.
grant execute on function public.valid_sentence_dialogue_v1(jsonb) to authenticated;
-- Existing CREATE OR REPLACE routines retain their service-only grants.
notify pgrst,'reload schema';
commit;
