-- Retire sentence metadata/indexing. Photo tags and all learning history remain.
-- Deploy together with the updated generation/content functions and client.
begin;

drop function public.finalize_generation_job_v3(uuid,uuid,boolean,text,jsonb,text,jsonb);

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
  if jsonb_array_length(p_memory->'sentences') not in (3,6) or jsonb_array_length(p_memory->'tags')>3
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
  insert into public.memories(id,user_id,image_url,created_at,tags,provider,target_language,translation_language,teaching_locale,content_schema_version,generation_spec)
  values(mid,p_user_id,p_memory->>'imagePath',(p_memory->>'createdAt')::timestamptz,
    array(select jsonb_array_elements_text(p_memory->'tags')),p_provider,c->>'targetLanguage',c->>'translationLanguage',c->>'teachingLocale',2,p_spec);
  for item in select value,ordinality from jsonb_array_elements(p_memory->'sentences') with ordinality loop
    insert into public.memory_sentences(id,memory_id,sort_order,target_text,translation_text,content_version,learning_material,presentation_group,is_favorite)
    values((item.value->>'id')::uuid,mid,item.ordinality-1,item.value->>'targetText',item.value->>'translationText',1,
      nullif(item.value->'learningMaterial','null'::jsonb),
      item.value->>'presentationGroup',(item.value->>'isFavorite')::boolean);
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
  if m->'context' is distinct from c or jsonb_array_length(m->'sentences')<>6
    or (select count(*) from jsonb_array_elements(m->'sentences') s where s->>'presentationGroup'='what_i_see')<>3
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

create or replace function public.import_guest_memory_v1(p_user_id uuid,p_guest_user_id uuid,p_memory jsonb)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,pg_temp as $$
declare mid uuid:=(p_memory->>'id')::uuid; owner_id uuid; existing jsonb; guest_job record; receipt record; fingerprint text;
begin
  perform public.validate_memory_import_v1(p_memory,p_user_id);
  perform pg_advisory_xact_lock(hashtextextended('memory-import:'||mid::text,0));
  fingerprint:=encode(sha256(convert_to(public.immutable_memory_identity_v1(p_memory)::text,'UTF8')),'hex');
  select * into receipt from public.guest_memory_import_receipts_v1 where memory_id=mid;
  if found then
    if receipt.user_id is distinct from p_user_id or receipt.content_digest is distinct from fingerprint then raise exception 'content_conflict'; end if;
    return jsonb_build_object('id',mid,'imported',true,'alreadyImported',true);
  end if;
  select user_id into owner_id from public.memories where id=mid for update;
  if found then
    if owner_id is distinct from p_user_id then raise exception 'content_conflict'; end if;
    existing:=public.memory_content_dto_v2(mid);
    if public.immutable_memory_identity_v1(existing) is distinct from public.immutable_memory_identity_v1(p_memory) then raise exception 'content_conflict'; end if;
    insert into public.guest_memory_import_receipts_v1(memory_id,user_id,content_digest) values(mid,p_user_id,fingerprint);
    return jsonb_build_object('id',mid,'imported',true,'alreadyImported',true);
  end if;
  select * into guest_job from public.guest_generation_jobs where id=mid for update;
  if found then
    if (guest_job.user_id is distinct from p_guest_user_id and guest_job.user_id is distinct from p_user_id)
      or guest_job.status not in ('completed','acknowledged') then raise exception 'content_conflict'; end if;
    if guest_job.request_schema_version=3 then existing:=guest_job.result_content;
    else
      existing:=jsonb_build_object('id',mid,'createdAt',guest_job.created_at,'context',jsonb_build_object('schemaVersion',2,
        'targetLanguage','en','translationLanguage','zh-Hans','teachingLocale','en-US'),'sentences',(
          select jsonb_agg(jsonb_build_object('id',s->>'id','targetText',s->>'english','translationText',s->>'chinese',
            'contentVersion',1,'presentationGroup',coalesce(s->>'presentation_group','what_i_see'))) from jsonb_array_elements(guest_job.sentences) s));
    end if;
    if public.immutable_memory_identity_v1(existing) is distinct from public.immutable_memory_identity_v1(p_memory) then raise exception 'content_conflict'; end if;
  end if;
  -- A cleaned-up guest job may be imported from its local copy, but never grants credits.
  perform public.insert_memory_content_v2(p_user_id,p_memory);
  insert into public.guest_memory_import_receipts_v1(memory_id,user_id,content_digest) values(mid,p_user_id,fingerprint);
  return jsonb_build_object('id',mid,'imported',true,'alreadyImported',false);
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
      'presentationGroup',s.presentation_group,'isFavorite',s.is_favorite,'learningMaterial',s.learning_material))
      order by s.sort_order,s.id) from public.memory_sentences s where s.memory_id=m.id),'[]'::jsonb))
  from public.memories m where m.id=p_memory_id
$$;

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
  current_balance integer := 0;
  remaining_balance integer := 0;
  generation_job record;
  sentence_item record;
begin
  if p_sentences is null or jsonb_typeof(p_sentences) <> 'array'
     or jsonb_array_length(p_sentences) not in (3, 6) then
    raise exception 'invalid sentences';
  end if;

  if p_client_request_id is not null then
    insert into public.generation_jobs (client_request_id, user_id, status, updated_at)
    values (p_client_request_id, p_user_id, 'pending', timezone('utc', now()))
    on conflict (client_request_id) do nothing;

    select * into generation_job
    from public.generation_jobs
    where client_request_id = p_client_request_id and user_id = p_user_id
    for update;

    if not found then raise exception 'generation job not found'; end if;
    if generation_job.status = 'completed' then
      return coalesce(generation_job.remaining_credits, (select available_generations from public.profiles where id = p_user_id));
    end if;
    if generation_job.status = 'failed' then raise exception 'generation job already failed'; end if;
  end if;

  select available_generations into current_balance
  from public.profiles where id = p_user_id for update;
  if not found then raise exception 'profile not found'; end if;
  if exists (select 1 from public.memories where id = p_memory_id and user_id = p_user_id) then
    return current_balance;
  end if;
  if coalesce(current_balance, 0) <= 0 then raise exception 'No credits left'; end if;

  remaining_balance := current_balance - 1;
  insert into public.memories (id, user_id, image_url, created_at, provider, tags)
  values (
    p_memory_id, p_user_id, p_image_path, coalesce(p_created_at, timezone('utc', now())), p_provider,
    public.normalize_memory_photo_categories(p_tags)
  );

  for sentence_item in select value, ordinality from jsonb_array_elements(p_sentences) with ordinality loop
    insert into public.memory_sentences (
      id, memory_id, sort_order, english, chinese, presentation_group, is_favorite
    ) values (
      case when nullif(sentence_item.value ->> 'id', '') is null then gen_random_uuid() else (sentence_item.value ->> 'id')::uuid end,
      p_memory_id,
      sentence_item.ordinality - 1,
      btrim(sentence_item.value ->> 'english'),
      btrim(sentence_item.value ->> 'chinese'),
      case when sentence_item.value ->> 'presentation_group' = 'what_i_say' then 'what_i_say' else 'what_i_see' end,
      coalesce((sentence_item.value ->> 'is_favorite')::boolean, false)
    );
  end loop;

  update public.profiles set available_generations = remaining_balance where id = p_user_id;
  if to_regclass('public.generation_transactions') is not null then
    insert into public.generation_transactions (user_id, delta, balance_after, reason, note)
    values (p_user_id, -1, remaining_balance, 'generate', 'memory_id:' || p_memory_id::text);
  end if;
  if p_client_request_id is not null then
    update public.generation_jobs set
      status = 'completed', memory_id = p_memory_id, image_path = p_image_path,
      provider = p_provider, remaining_credits = remaining_balance, error_message = null,
      updated_at = timezone('utc', now()), completed_at = coalesce(completed_at, timezone('utc', now())), failed_at = null
    where client_request_id = p_client_request_id and user_id = p_user_id;
  end if;
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
set search_path = public, pg_temp
as $$
declare
  current_balance integer := 0;
  remaining_balance integer := 0;
  guest_job record;
begin
  if p_sentences is null or jsonb_typeof(p_sentences) <> 'array'
     or jsonb_array_length(p_sentences) not in (3, 6) then
    raise exception 'invalid sentences';
  end if;
  select * into guest_job from public.guest_generation_jobs
  where id = p_guest_job_id and user_id = p_user_id for update;
  if not found then raise exception 'guest generation job not found'; end if;
  if guest_job.status in ('completed', 'acknowledged') then
    return coalesce(guest_job.remaining_credits, (select available_generations from public.profiles where id = p_user_id));
  end if;
  if guest_job.status = 'failed' then raise exception 'guest generation job already failed'; end if;
  select available_generations into current_balance from public.profiles where id = p_user_id for update;
  if not found then raise exception 'profile not found'; end if;
  if coalesce(current_balance, 0) <= 0 then raise exception 'No credits left'; end if;

  remaining_balance := current_balance - 1;
  update public.profiles set available_generations = remaining_balance where id = p_user_id;
  update public.guest_generation_jobs set
    status = 'completed', completed_at = coalesce(p_completed_at, timezone('utc', now())),
    provider = p_provider, sentences = public.strip_sentence_metadata_v1(p_sentences),
    tags = public.normalize_memory_photo_categories(p_tags),
    remaining_credits = remaining_balance, error_message = null
  where id = p_guest_job_id and user_id = p_user_id;
  if to_regclass('public.generation_transactions') is not null then
    insert into public.generation_transactions (user_id, delta, balance_after, reason, note)
    values (p_user_id, -1, remaining_balance, 'generate', 'guest_job_id:' || p_guest_job_id::text);
  end if;
  return remaining_balance;
end;
$$;

-- Remove only derived fields from retained guest recovery payloads.
create function public.strip_sentence_metadata_v1(p_sentences jsonb)
returns jsonb language sql immutable set search_path=pg_catalog,public,pg_temp as $$
  select case when jsonb_typeof(p_sentences)='array' then
    coalesce((select jsonb_agg(value - array['learning_topic_ids','learningTopicIDs',
      'expression_purpose','expressionPurpose','embedding','purpose_embedding'] order by ordinality)
      from jsonb_array_elements(p_sentences) with ordinality), '[]'::jsonb)
    else p_sentences end
$$;

-- Only the transaction's maintenance update bypasses immutable result guards.
alter table public.guest_generation_jobs disable trigger protect_generation_job_result;
alter table public.guest_generation_jobs disable trigger protect_generation_context_v3;
update public.guest_generation_jobs
set sentences=public.strip_sentence_metadata_v1(sentences),
    result_content=case when result_content ? 'sentences'
      then jsonb_set(result_content,'{sentences}',public.strip_sentence_metadata_v1(result_content->'sentences'))
      else result_content end;
alter table public.guest_generation_jobs enable trigger protect_generation_job_result;
alter table public.guest_generation_jobs enable trigger protect_generation_context_v3;
revoke all on function public.strip_sentence_metadata_v1(jsonb) from public,anon,authenticated;

-- Retired matching/indexing triggers must not query columns removed below.
drop trigger if exists preserve_enriched_sentence_categories on public.memory_sentences;
drop trigger if exists match_sentence_to_learning_topic_study_scenes_trigger on public.memory_sentences;
drop trigger if exists match_sentence_to_semantic_study_scenes on public.memory_sentences;
drop trigger if exists promote_guest_sentence_embedding_after_memory_sentence_insert on public.memory_sentences;

-- Remove the retired routine family, not arbitrary routines or application data.
-- No CASCADE: unexpected external dependencies must abort this migration.
do $$
declare r record;
begin
  for r in select t.tgname,t.tgrelid::regclass as relation
    from pg_trigger t join pg_proc p on p.oid=t.tgfoid
    where not t.tgisinternal and p.pronamespace='public'::regnamespace
      and (p.proname like '%sentence_embedding%' or p.proname like '%study_scene%')
  loop execute format('drop trigger %I on %s',r.tgname,r.relation); end loop;
  for r in select p.oid::regprocedure as signature from pg_proc p
    where p.pronamespace='public'::regnamespace and p.prokind='f'
      and (p.proname like '%generation_enrichment%' or p.proname like '%sentence_embedding%'
        or p.proname like '%study_scene%' or p.proname in
          ('learning_topic_ids_from_json','preserve_enriched_sentence_categories'))
  loop execute format('drop function %s',r.signature); end loop;
end;
$$;

drop table if exists public.generation_enrichment_timings;
drop table if exists public.study_scene_enrichment_jobs;
drop table if exists public.generation_enrichment_jobs;
drop table if exists public.multilingual_sentence_embeddings_v1;
drop table if exists public.guest_sentence_embeddings;
drop table if exists public.sentence_embeddings;
drop table if exists public.learning_topic_embeddings;
drop table if exists public.study_scene_embeddings;
alter table public.memory_sentences drop column learning_topic_ids;

-- Existing grants survive CREATE OR REPLACE; explicitly fence the new signature.
revoke all on function public.finalize_generation_job_v3(uuid,uuid,boolean,text,jsonb,text)
  from public,anon,authenticated;
grant execute on function public.finalize_generation_job_v3(uuid,uuid,boolean,text,jsonb,text)
  to service_role;
notify pgrst,'reload schema';
commit;
