-- Three global dialogue pairs, without changing deployed migrations or receipts.
begin;

alter table public.memories add column dialogue_format text
  constraint memories_dialogue_format_v1 check (dialogue_format in ('dialogue_tabs_v1','dialogue_trio_v1'));
-- Imported memories have no generation_spec. Preserve their original family so
-- deleting half of an old 12-turn memory cannot turn it into a valid trio.
update public.memories m set dialogue_format='dialogue_tabs_v1'
where m.generation_spec->>'generationFormat'='dialogue_tabs_v1'
  or exists(select 1 from public.memory_sentences s where s.memory_id=m.id and s.dialogue is not null);

create or replace function public.valid_generation_spec_v3(p_spec jsonb)
returns boolean language sql stable set search_path = pg_catalog, public, pg_temp as $$
  select coalesce(jsonb_typeof(p_spec) = 'object'
    and p_spec @> '{"schemaVersion":1,"catalogVersion":1}'::jsonb
    and p_spec->>'generationFormat' in ('dual_tabs_v1','dialogue_tabs_v1','dialogue_trio_v1')
    and p_spec->>'level' in ('starter','beginner','intermediate','advanced')
    and exists (select 1 from public.language_capabilities_v1 c
      where c.target_language=p_spec->>'targetLanguage' and c.translation_language=p_spec->>'translationLanguage'
        and c.teaching_locale=p_spec->>'teachingLocale'),false)
$$;

create or replace function public.valid_sentence_collection_v1(p_sentences jsonb,p_format text default null)
returns boolean language plpgsql immutable set search_path=pg_catalog,public,pg_temp as $$
declare n integer; has_dialogue boolean;
begin
  if jsonb_typeof(p_sentences) is distinct from 'array' then return false; end if;
  n:=jsonb_array_length(p_sentences);
  select exists(select 1 from jsonb_array_elements(p_sentences) s
    where nullif(s->'dialogue','null'::jsonb) is not null) into has_dialogue;
  if p_format is not null and p_format not in ('dual_tabs_v1','dialogue_tabs_v1','dialogue_trio_v1') then return false; end if;
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
returns trigger language plpgsql
set search_path = pg_catalog, public, pg_temp
as $$
begin
  if tg_op = 'UPDATE' and
    (new.id,new.user_id,new.target_language,new.translation_language,new.teaching_locale,
     new.content_schema_version,new.created_at,new.image_url,new.generation_spec,new.dialogue_format)
    is distinct from
    (old.id,old.user_id,old.target_language,old.translation_language,old.teaching_locale,
     old.content_schema_version,old.created_at,old.image_url,old.generation_spec,old.dialogue_format) then
    raise exception 'immutable_content' using errcode = '22023';
  end if;
  if current_user in ('anon','authenticated') then
    if not public.is_legacy_content_v1(new.target_language,new.translation_language,new.teaching_locale)
      or (tg_op = 'INSERT' and (new.generation_spec is not null or new.dialogue_format is not null)) then raise exception 'legacy_content_only' using errcode = '42501'; end if;
    if tg_op = 'UPDATE' and to_jsonb(new) is distinct from to_jsonb(old) then
      raise exception 'immutable_content' using errcode = '22023';
    end if;
  end if;
  return new;
end;
$$;

create or replace function public.insert_memory_content_v2(p_user_id uuid,p_memory jsonb,p_spec jsonb default null,p_provider text default null)
returns void language plpgsql set search_path=pg_catalog,public,pg_temp as $$
declare item record; c jsonb:=p_memory->'context'; mid uuid:=(p_memory->>'id')::uuid;
begin
  perform public.validate_memory_import_v1(p_memory,p_user_id);
  if p_spec is not null and not public.valid_sentence_collection_v1(p_memory->'sentences',p_spec->>'generationFormat') then
    raise exception 'invalid_content'; end if;
  insert into public.memories(id,user_id,image_url,created_at,tags,provider,target_language,translation_language,teaching_locale,content_schema_version,generation_spec,dialogue_format)
  values(mid,p_user_id,p_memory->>'imagePath',(p_memory->>'createdAt')::timestamptz,
    array(select jsonb_array_elements_text(p_memory->'tags')),p_provider,c->>'targetLanguage',c->>'translationLanguage',c->>'teachingLocale',2,p_spec,
    case when exists(select 1 from jsonb_array_elements(p_memory->'sentences') s
      where nullif(s->'dialogue','null'::jsonb) is not null) then
        case when jsonb_array_length(p_memory->'sentences')=6 then 'dialogue_trio_v1' else 'dialogue_tabs_v1' end
    end);
  for item in select value,ordinality from jsonb_array_elements(p_memory->'sentences') with ordinality loop
    insert into public.memory_sentences(id,memory_id,sort_order,target_text,translation_text,content_version,learning_material,presentation_group,is_favorite,dialogue)
    values((item.value->>'id')::uuid,mid,item.ordinality-1,item.value->>'targetText',item.value->>'translationText',1,
      nullif(item.value->'learningMaterial','null'::jsonb),
      item.value->>'presentationGroup',(item.value->>'isFavorite')::boolean,nullif(item.value->'dialogue','null'::jsonb));
  end loop;
end;
$$;

create or replace function public.claim_generation_job_v3(p_user_id uuid,p_request_id uuid,p_is_anonymous boolean,p_image_path text,
  p_generation_spec jsonb,p_request_fingerprint text,p_generation_policy jsonb)
returns text language plpgsql security definer set search_path=pg_catalog,public,pg_temp as $$
declare j record;
begin
  if p_user_id is null or p_request_id is null or p_is_anonymous is null or not public.valid_generation_spec_v3(p_generation_spec)
    or p_request_fingerprint is null or p_request_fingerprint !~ '^[0-9a-f]{64}$'
    or not coalesce(p_generation_policy @> '{"version":1}'::jsonb,false) then raise exception 'invalid_generation_request'; end if;
  -- Same lock fences v1/v3 races even before either task row exists.
  perform pg_advisory_xact_lock(hashtextextended('generation-request:'||p_request_id::text,0));
  if p_is_anonymous then select * into j from public.guest_generation_jobs where id=p_request_id for update;
  else select * into j from public.generation_jobs where client_request_id=p_request_id for update; end if;
  if found then
    if j.user_id is distinct from p_user_id then raise exception 'generation_job_not_found'; end if;
    if j.request_schema_version<>3 or j.request_fingerprint is distinct from p_request_fingerprint
      or j.generation_spec is distinct from p_generation_spec then raise exception 'request_context_mismatch' using errcode='22023'; end if;
    return j.status;
  end if;
  if p_generation_spec->>'generationFormat'='dialogue_trio_v1'
    and not coalesce(p_generation_policy->>'dialogueMiddleGroup' in ('what_i_see','what_i_say'),false) then
    raise exception 'invalid_generation_request'; end if;
  if not exists(select 1 from public.language_capabilities_v1 where target_language=p_generation_spec->>'targetLanguage'
    and translation_language=p_generation_spec->>'translationLanguage' and can_generate) then raise exception 'generation_disabled'; end if;
  if p_is_anonymous then
    if p_image_path is distinct from p_user_id::text||'/guest/'||p_request_id::text||'.jpg' then raise exception 'invalid_image_path'; end if;
    insert into public.guest_generation_jobs(id,user_id,status,image_path,request_schema_version,generation_spec,request_fingerprint,generation_policy)
    values(p_request_id,p_user_id,'pending',p_image_path,3,p_generation_spec,p_request_fingerprint,p_generation_policy);
  else
    insert into public.generation_jobs(client_request_id,user_id,status,request_schema_version,generation_spec,request_fingerprint,generation_policy)
    values(p_request_id,p_user_id,'pending',3,p_generation_spec,p_request_fingerprint,p_generation_policy);
  end if;
  return 'acquired';
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
    or (j.generation_spec->>'generationFormat'='dialogue_trio_v1' and (
      not coalesce(j.generation_policy->>'dialogueMiddleGroup' in ('what_i_see','what_i_say'),false)
      or exists(select 1 from jsonb_array_elements(m->'sentences') s
        where s->'dialogue'->'index'='1'::jsonb
          and s->>'presentationGroup' is distinct from j.generation_policy->>'dialogueMiddleGroup')))
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
      or not public.valid_sentence_collection_v1(new.result_content->'sentences',new.generation_spec->>'generationFormat')
      or (new.generation_spec->>'generationFormat'='dialogue_trio_v1' and (
      not coalesce(new.generation_policy->>'dialogueMiddleGroup' in ('what_i_see','what_i_say'),false)
      or exists(select 1 from jsonb_array_elements(new.result_content->'sentences') s
        where s->'dialogue'->'index'='1'::jsonb
          and s->>'presentationGroup' is distinct from new.generation_policy->>'dialogueMiddleGroup'))) then
      raise exception 'request_context_mismatch';
    end if;
  end if;
  return new;
end;
$$;

create or replace function public.protect_dialogue_collection_v1()
returns trigger language plpgsql security definer set search_path=pg_catalog,public,pg_temp as $$
declare mid uuid; format text; sentences jsonb;
begin
  mid:=case when tg_op='DELETE' then old.memory_id else new.memory_id end;
  select dialogue_format into format from public.memories where id=mid;
  if not found then return null; end if;
  select coalesce(jsonb_agg(jsonb_build_object('presentationGroup',presentation_group,'dialogue',dialogue)),'[]'::jsonb)
    into sentences from public.memory_sentences where memory_id=mid;
  if format is not null
    or (tg_op='DELETE' and old.dialogue is not null)
    or exists(select 1 from public.memory_sentences where memory_id=mid and dialogue is not null) then
    if format is null or not public.valid_sentence_collection_v1(sentences,format) then
      raise exception 'invalid_dialogue_collection' using errcode='22023'; end if;
  end if;
  return null;
end;
$$;

-- Retain the existing 0..11 sort_order bound for historical 12-turn records.
-- DTOs, immutable identities/receipts, and favorite grants remain unchanged.
-- All replaced function signatures retain their existing ACLs.
notify pgrst,'reload schema';
commit;
