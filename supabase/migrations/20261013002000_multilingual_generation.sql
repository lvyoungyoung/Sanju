-- Service-only generation/import transactions. No capability is opened here.
begin;

alter table public.generation_jobs
  add column if not exists request_schema_version integer not null default 1,
  add column if not exists generation_spec jsonb,
  add column if not exists request_fingerprint text,
  add column if not exists generation_policy jsonb;
alter table public.guest_generation_jobs
  add column if not exists request_schema_version integer not null default 1,
  add column if not exists generation_spec jsonb,
  add column if not exists request_fingerprint text,
  add column if not exists generation_policy jsonb,
  add column if not exists result_content jsonb;
alter table public.generation_enrichment_jobs
  add column if not exists content_schema_version integer not null default 1,
  add column if not exists content_context jsonb;

create function public.valid_generation_spec_v3(p_spec jsonb)
returns boolean language sql stable set search_path = pg_catalog, public, pg_temp as $$
  select coalesce(jsonb_typeof(p_spec) = 'object'
    and p_spec @> '{"schemaVersion":1,"catalogVersion":1,"generationFormat":"dual_tabs_v1"}'::jsonb
    and p_spec->>'level' in ('starter','beginner','intermediate','advanced')
    and exists (select 1 from public.language_capabilities_v1 c
      where c.target_language=p_spec->>'targetLanguage' and c.translation_language=p_spec->>'translationLanguage'
        and c.teaching_locale=p_spec->>'teachingLocale'),false)
$$;

create function public.protect_generation_context_v3()
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
      'translationLanguage',new.generation_spec->>'translationLanguage','teachingLocale',new.generation_spec->>'teachingLocale') then
      raise exception 'request_context_mismatch';
    end if;
  end if;
  return new;
end;
$$;
create trigger protect_generation_context_v3 before update on public.generation_jobs
for each row execute function public.protect_generation_context_v3();
create trigger protect_generation_context_v3 before update on public.guest_generation_jobs
for each row execute function public.protect_generation_context_v3();

-- policyVersion/kind/canBlank is the v1 public contract; no strategyVersion alias.
create or replace function public.valid_learning_material_v1(p_material jsonb,p_text text)
returns boolean language plpgsql immutable set search_path=pg_catalog,public,pg_temp as $$
declare s jsonb; ids text[] := '{}'; surfaces text := '';
begin
  if p_material is null then return true; end if;
  if jsonb_typeof(p_material) is distinct from 'object' or octet_length(p_material::text)>32768
    or not (p_material @> '{"schemaVersion":1,"policyVersion":1}'::jsonb)
    or p_material->>'textDigest' is distinct from encode(sha256(convert_to(p_text,'UTF8')),'hex')
    or jsonb_typeof(p_material->'segments') is distinct from 'array'
    or exists(select 1 from jsonb_object_keys(p_material) k where k not in ('schemaVersion','policyVersion','textDigest','segments')) then return false; end if;
  if jsonb_array_length(p_material->'segments') not between 1 and 256 then return false; end if;
  for s in select value from jsonb_array_elements(p_material->'segments') loop
    if jsonb_typeof(s) is distinct from 'object' or jsonb_typeof(s->'id') is distinct from 'string'
      or length(s->>'id') not between 1 and 100 or s->>'id'=any(ids)
      or jsonb_typeof(s->'surface') is distinct from 'string' or length(s->>'surface') not between 1 and 2000
      or not coalesce(s->>'kind' in ('word','particle','phrase','punctuation','whitespace'),false)
      or jsonb_typeof(s->'canBlank') is distinct from 'boolean'
      or (s->>'kind' in ('punctuation','whitespace') and (s->>'canBlank')::boolean)
      or (s->>'kind'='whitespace' and s->>'surface' !~ '^[[:space:]]+$')
      or (s ? 'reading' and (jsonb_typeof(s->'reading') is distinct from 'string' or length(s->>'reading') not between 1 and 500))
      or exists(select 1 from jsonb_object_keys(s) k where k not in ('id','surface','reading','kind','canBlank')) then return false; end if;
    ids:=array_append(ids,s->>'id'); surfaces:=surfaces||(s->>'surface');
  end loop;
  return surfaces=p_text;
end;
$$;

create function public.validate_memory_import_v1(p_memory jsonb,p_user_id uuid)
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
      or jsonb_typeof(s->'isFavorite') is distinct from 'boolean'
      or jsonb_typeof(s->'learningTopicIDs') is distinct from 'array' then raise exception 'invalid_content'; end if;
    if jsonb_array_length(s->'learningTopicIDs')>2 or exists(select 1 from jsonb_array_elements(s->'learningTopicIDs') t
      where jsonb_typeof(t)<>'string' or t#>>'{}' !~ '^[a-z][a-z0-9_]{0,79}$') then raise exception 'invalid_content'; end if;
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

create function public.insert_memory_content_v2(p_user_id uuid,p_memory jsonb,p_spec jsonb default null,p_provider text default null)
returns void language plpgsql set search_path=pg_catalog,public,pg_temp as $$
declare item record; c jsonb:=p_memory->'context'; mid uuid:=(p_memory->>'id')::uuid;
begin
  perform public.validate_memory_import_v1(p_memory,p_user_id);
  insert into public.memories(id,user_id,image_url,created_at,tags,provider,target_language,translation_language,teaching_locale,content_schema_version,generation_spec)
  values(mid,p_user_id,p_memory->>'imagePath',(p_memory->>'createdAt')::timestamptz,
    array(select jsonb_array_elements_text(p_memory->'tags')),p_provider,c->>'targetLanguage',c->>'translationLanguage',c->>'teachingLocale',2,p_spec);
  for item in select value,ordinality from jsonb_array_elements(p_memory->'sentences') with ordinality loop
    insert into public.memory_sentences(id,memory_id,sort_order,target_text,translation_text,content_version,learning_material,learning_topic_ids,presentation_group,is_favorite)
    values((item.value->>'id')::uuid,mid,item.ordinality-1,item.value->>'targetText',item.value->>'translationText',1,
      nullif(item.value->'learningMaterial','null'::jsonb),array(select jsonb_array_elements_text(item.value->'learningTopicIDs')),
      item.value->>'presentationGroup',(item.value->>'isFavorite')::boolean);
  end loop;
end;
$$;

create function public.recover_generation_job_v2(p_user_id uuid,p_request_id uuid,p_is_anonymous boolean,p_request_fingerprint text default null)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,pg_temp as $$
declare j record; m jsonb;
begin
  if p_is_anonymous then select * into j from public.guest_generation_jobs where id=p_request_id and user_id=p_user_id;
  else select * into j from public.generation_jobs where client_request_id=p_request_id and user_id=p_user_id; end if;
  if not found then return jsonb_build_object('status','not_found'); end if;
  if j.request_schema_version<>3 or (p_request_fingerprint is not null and j.request_fingerprint is distinct from p_request_fingerprint) then
    raise exception 'request_context_mismatch' using errcode='22023'; end if;
  if j.status in ('completed','acknowledged') then
    if p_is_anonymous then m:=j.result_content;
    else m:=public.memory_content_dto_v2(j.memory_id); end if;
  end if;
  return jsonb_build_object('status',j.status,'recovered',m is not null,'memory',m,'generationSpec',j.generation_spec,
    'guestImagePath',case when p_is_anonymous then j.image_path end,
    'remainingCredits',j.remaining_credits,case when p_is_anonymous then 'guestJobID' else 'clientRequestID' end,p_request_id);
end;
$$;

create function public.claim_generation_job_v3(p_user_id uuid,p_request_id uuid,p_is_anonymous boolean,p_image_path text,
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

create function public.finalize_generation_job_v3(p_user_id uuid,p_request_id uuid,p_is_anonymous boolean,
  p_request_fingerprint text,p_memory jsonb,p_provider text,p_expression_purposes jsonb)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public,pg_temp as $$
declare j record; balance integer; c jsonb; m jsonb:=p_memory; payload jsonb; legacy boolean;
begin
  if p_is_anonymous then select * into j from public.guest_generation_jobs where id=p_request_id and user_id=p_user_id for update;
  else select * into j from public.generation_jobs where client_request_id=p_request_id and user_id=p_user_id for update; end if;
  if not found then raise exception 'generation_job_not_found'; end if;
  if j.request_schema_version<>3 or j.request_fingerprint is distinct from p_request_fingerprint then raise exception 'request_context_mismatch'; end if;
  if j.status in ('completed','acknowledged') then return public.recover_generation_job_v2(p_user_id,p_request_id,p_is_anonymous,p_request_fingerprint); end if;
  if j.status<>'pending' then raise exception 'generation_failed'; end if;
  c:=jsonb_build_object('schemaVersion',2,'targetLanguage',j.generation_spec->>'targetLanguage',
    'translationLanguage',j.generation_spec->>'translationLanguage','teachingLocale',j.generation_spec->>'teachingLocale');
  if m->'context' is distinct from c or jsonb_array_length(m->'sentences')<>6
    or jsonb_typeof(p_expression_purposes) is distinct from 'array' or jsonb_array_length(p_expression_purposes)<>6
    or exists(select 1 from jsonb_array_elements(p_expression_purposes) p where jsonb_typeof(p)<>'string' or length(btrim(p#>>'{}')) not between 1 and 240)
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
  legacy:=public.is_legacy_content_v1(c->>'targetLanguage',c->>'translationLanguage',c->>'teachingLocale');
  select jsonb_agg(case when legacy then jsonb_build_object('id',s.value->>'id','english',s.value->>'targetText',
      'chinese',s.value->>'translationText','learning_topic_ids',s.value->'learningTopicIDs','expression_purpose',p_expression_purposes->(s.ordinality::integer-1))
    else s.value||jsonb_build_object('expressionPurpose',p_expression_purposes->(s.ordinality::integer-1)) end order by s.ordinality)
    into payload from jsonb_array_elements(m->'sentences') with ordinality s;
  insert into public.generation_enrichment_jobs(user_id,memory_id,guest_job_id,sentences,content_schema_version,content_context)
    values(p_user_id,case when not p_is_anonymous then (m->>'id')::uuid end,case when p_is_anonymous then p_request_id end,
      payload,case when legacy then 1 else 2 end,c);
  return public.recover_generation_job_v2(p_user_id,p_request_id,p_is_anonymous,p_request_fingerprint);
end;
$$;

create function public.immutable_memory_identity_v1(p_memory jsonb)
returns jsonb language sql immutable set search_path=pg_catalog,public,pg_temp as $$
  select jsonb_build_object('id',p_memory->'id','context',p_memory->'context','createdAt',
    to_jsonb((p_memory->>'createdAt')::timestamptz),'sentences',(select jsonb_agg(jsonb_build_object(
      'id',s->'id','targetText',s->'targetText','translationText',s->'translationText','contentVersion',s->'contentVersion',
      'presentationGroup',s->'presentationGroup') order by s->>'id') from jsonb_array_elements(p_memory->'sentences') s))
$$;

create table public.guest_memory_import_receipts_v1(
  memory_id uuid primary key,
  user_id uuid not null references public.profiles(id) on delete cascade,
  content_digest text not null,
  imported_at timestamptz not null default now()
);
alter table public.guest_memory_import_receipts_v1 enable row level security;
revoke all on public.guest_memory_import_receipts_v1 from public,anon,authenticated;
grant select,insert on public.guest_memory_import_receipts_v1 to service_role;

create function public.import_guest_memory_v1(p_user_id uuid,p_guest_user_id uuid,p_memory jsonb)
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
  -- Vectors that finished before login need the same promotion as late results.
  update public.multilingual_sentence_embeddings_v1 set user_id=p_user_id,memory_id=mid,guest_job_id=null
    where guest_job_id=mid and sentence_id in (select (s->>'id')::uuid from jsonb_array_elements(p_memory->'sentences') s);
  return jsonb_build_object('id',mid,'imported',true,'alreadyImported',false);
end;
$$;

-- Different languages/vector input versions never enter the old English matcher.
create table public.multilingual_sentence_embeddings_v1(
  sentence_id uuid primary key,
  user_id uuid not null references public.profiles(id) on delete cascade,
  memory_id uuid references public.memories(id) on delete cascade,
  guest_job_id uuid,
  content_context jsonb not null,
  model text not null,
  embedding real[] not null,
  purpose_embedding real[] not null,
  updated_at timestamptz not null default now()
);
alter table public.multilingual_sentence_embeddings_v1 enable row level security;
revoke all on public.multilingual_sentence_embeddings_v1 from public,anon,authenticated;
grant select,insert,update,delete on public.multilingual_sentence_embeddings_v1 to service_role;

create function public.complete_multilingual_generation_enrichment_v1(p_job_id uuid,p_lease_token uuid,p_rows jsonb)
returns boolean language plpgsql security definer set search_path=pg_catalog,public,pg_temp as $$
declare j record; r jsonb; original real[]; purpose real[]; sid uuid; imported_owner uuid; imported_memory uuid;
begin
  select * into j from public.generation_enrichment_jobs where id=p_job_id and status='processing'
    and lease_token=p_lease_token and lease_until>now() for update;
  if not found then return false; end if;
  if j.content_schema_version<>2 or j.content_context is null or jsonb_typeof(p_rows) is distinct from 'array'
    or jsonb_array_length(p_rows)<>jsonb_array_length(j.sentences)
    or (select count(distinct s->>'sentence_id') from jsonb_array_elements(p_rows) s)<>jsonb_array_length(p_rows) then raise exception 'invalid_indexing_result'; end if;
  for r in select value from jsonb_array_elements(p_rows) loop
    sid:=(r->>'sentence_id')::uuid;
    if not exists(select 1 from jsonb_array_elements(j.sentences) s where (s->>'id')::uuid=sid)
      or r->>'model' is distinct from 'qwen3.7-text-embedding:multilingual-v1' then raise exception 'invalid_indexing_result'; end if;
    original:=array(select value::real from jsonb_array_elements_text(r->'embedding'));
    purpose:=array(select value::real from jsonb_array_elements_text(r->'purpose_embedding'));
    if cardinality(original)<>1024 or cardinality(purpose)<>1024 or array_position(original,null) is not null
      or array_position(purpose,null) is not null or original && array['NaN'::real,'Infinity'::real,'-Infinity'::real]
      or purpose && array['NaN'::real,'Infinity'::real,'-Infinity'::real]
      or original=array_fill(0::real,array[1024]) or purpose=array_fill(0::real,array[1024]) then raise exception 'invalid_indexing_vectors'; end if;
    if j.memory_id is not null and not exists(select 1 from public.memory_sentences s join public.memories m on m.id=s.memory_id
      where s.id=sid and m.id=j.memory_id and m.user_id=j.user_id) then continue; end if;
    imported_owner:=null; imported_memory:=null;
    if j.guest_job_id is not null then
      select m.user_id,m.id into imported_owner,imported_memory from public.guest_memory_import_receipts_v1 receipt
        join public.memories m on m.id=receipt.memory_id join public.memory_sentences s on s.memory_id=m.id
        where receipt.memory_id=j.guest_job_id and s.id=sid;
      -- An imported-then-deleted result must not recreate a retained guest vector.
      if imported_memory is null and exists(select 1 from public.guest_memory_import_receipts_v1 where memory_id=j.guest_job_id) then continue; end if;
    end if;
    insert into public.multilingual_sentence_embeddings_v1(sentence_id,user_id,memory_id,guest_job_id,content_context,model,embedding,purpose_embedding)
      values(sid,coalesce(imported_owner,j.user_id),coalesce(imported_memory,j.memory_id),case when imported_memory is null then j.guest_job_id end,
        j.content_context,r->>'model',original,purpose)
      on conflict(sentence_id) do nothing;
  end loop;
  update public.generation_enrichment_jobs set status='completed',completed_at=now(),sentences='[]'::jsonb,
    lease_token=null,lease_until=null,last_error=null where id=j.id;
  return true;
end;
$$;

-- Fence old workers even when called concurrently with a new-version claim.
alter function public.promote_guest_sentence_embedding_for_id(uuid) rename to promote_guest_sentence_embedding_legacy_internal;
create function public.promote_guest_sentence_embedding_for_id(p_sentence_id uuid)
returns boolean language plpgsql security definer set search_path=pg_catalog,public,pg_temp as $$
begin
  if not exists(select 1 from public.memory_sentences s join public.memories m on m.id=s.memory_id
    where s.id=p_sentence_id and public.is_legacy_content_v1(m.target_language,m.translation_language,m.teaching_locale)) then return false; end if;
  return public.promote_guest_sentence_embedding_legacy_internal(p_sentence_id);
end;
$$;
revoke all on function public.promote_guest_sentence_embedding_legacy_internal(uuid) from public,anon,authenticated,service_role;
revoke all on function public.promote_guest_sentence_embedding_for_id(uuid) from public,anon,authenticated;
grant execute on function public.promote_guest_sentence_embedding_for_id(uuid) to service_role;

alter function public.complete_generation_enrichment(uuid,uuid,jsonb) rename to complete_generation_enrichment_legacy_internal;
create function public.complete_generation_enrichment(p_job_id uuid,p_lease_token uuid,p_rows jsonb)
returns boolean language plpgsql security definer set search_path=pg_catalog,public,pg_temp as $$
declare j public.generation_enrichment_jobs%rowtype;
begin
  select * into j from public.generation_enrichment_jobs where id=p_job_id and lease_token=p_lease_token
    and status='processing' and lease_until>now() for update;
  if not found then return false; end if;
  if j.content_schema_version<>1 or (j.content_context is not null and not public.is_legacy_content_v1(
    j.content_context->>'targetLanguage',j.content_context->>'translationLanguage',j.content_context->>'teachingLocale')) then
    raise exception 'legacy_enrichment_only';
  end if;
  return public.complete_generation_enrichment_legacy_internal(p_job_id,p_lease_token,p_rows);
end;
$$;
revoke all on function public.complete_generation_enrichment_legacy_internal(uuid,uuid,jsonb) from public,anon,authenticated,service_role;
revoke all on function public.complete_generation_enrichment(uuid,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.complete_generation_enrichment(uuid,uuid,jsonb) to service_role;

alter function public.claim_generation_job(uuid,uuid,boolean,text) rename to claim_generation_job_legacy_internal;
create function public.claim_generation_job(p_user_id uuid,p_request_id uuid,p_is_anonymous boolean,p_image_path text default null)
returns text language plpgsql security definer set search_path=pg_catalog,public,pg_temp as $$
declare version integer;
begin
  perform pg_advisory_xact_lock(hashtextextended('generation-request:'||p_request_id::text,0));
  if p_is_anonymous then select request_schema_version into version from public.guest_generation_jobs where id=p_request_id;
  else select request_schema_version into version from public.generation_jobs where client_request_id=p_request_id; end if;
  if coalesce(version,1)<>1 then raise exception 'request_context_mismatch'; end if;
  return public.claim_generation_job_legacy_internal(p_user_id,p_request_id,p_is_anonymous,p_image_path);
end;
$$;

do $$ declare signature text; begin
  foreach signature in array array[
    'valid_generation_spec_v3(jsonb)','protect_generation_context_v3()',
    'validate_memory_import_v1(jsonb,uuid)','insert_memory_content_v2(uuid,jsonb,jsonb,text)',
    'recover_generation_job_v2(uuid,uuid,boolean,text)',
    'claim_generation_job_v3(uuid,uuid,boolean,text,jsonb,text,jsonb)',
    'finalize_generation_job_v3(uuid,uuid,boolean,text,jsonb,text,jsonb)',
    'immutable_memory_identity_v1(jsonb)','import_guest_memory_v1(uuid,uuid,jsonb)',
    'complete_multilingual_generation_enrichment_v1(uuid,uuid,jsonb)',
    'claim_generation_job(uuid,uuid,boolean,text)'
  ] loop
    execute 'revoke all on function public.'||signature||' from public,anon,authenticated';
    execute 'grant execute on function public.'||signature||' to service_role';
  end loop;
end $$;
revoke all on function public.claim_generation_job_legacy_internal(uuid,uuid,boolean,text) from public,anon,authenticated,service_role;
notify pgrst,'reload schema';
commit;
