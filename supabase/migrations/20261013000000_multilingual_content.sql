-- Foundation only. No study activation, generation finalize or deployment here.
-- The repository lacks the original hosted schema. Unknown policies/functions
-- are retained; docs/multilingual-database-fixtures.md lists release blockers.
begin;

create function public.is_legacy_content_v1(p_target text, p_translation text, p_locale text)
returns boolean language sql immutable parallel safe
set search_path = pg_catalog, public, pg_temp
as $$ select coalesce(p_target = 'en' and p_translation = 'zh-Hans' and p_locale = 'en-US', false) $$;

create table public.language_capabilities_v1 (
  target_language text not null,
  translation_language text not null,
  teaching_locale text not null,
  can_generate boolean not null default false,
  primary key (target_language, translation_language),
  check ((target_language = 'en' and teaching_locale = 'en-US' and translation_language in ('zh-Hans','es','ja','fr'))
    or (target_language = 'es' and teaching_locale = 'es-419' and translation_language in ('zh-Hans','en'))
    or (target_language = 'ja' and teaching_locale = 'ja-JP' and translation_language in ('zh-Hans','en'))
    or (target_language = 'fr' and teaching_locale = 'fr-FR' and translation_language in ('zh-Hans','en')))
);
insert into public.language_capabilities_v1 values
  ('en','zh-Hans','en-US',true), ('en','es','en-US',false),
  ('en','ja','en-US',false), ('en','fr','en-US',false),
  ('es','zh-Hans','es-419',false), ('es','en','es-419',false),
  ('ja','zh-Hans','ja-JP',false), ('ja','en','ja-JP',false),
  ('fr','zh-Hans','fr-FR',false), ('fr','en','fr-FR',false);
alter table public.language_capabilities_v1 enable row level security;
revoke all on public.language_capabilities_v1 from public, anon, authenticated;
grant select on public.language_capabilities_v1 to service_role;

alter table public.memories
  add column target_language text not null default 'en',
  add column translation_language text not null default 'zh-Hans',
  add column teaching_locale text not null default 'en-US',
  add column content_schema_version integer not null default 2,
  add column generation_spec jsonb,
  add constraint memories_content_schema_v2 check (content_schema_version = 2),
  add constraint memories_language_pair_v1 foreign key (target_language, translation_language)
    references public.language_capabilities_v1(target_language, translation_language),
  add constraint memories_teaching_locale_v1 check (
    (target_language = 'en' and teaching_locale = 'en-US')
    or (target_language = 'es' and teaching_locale = 'es-419')
    or (target_language = 'ja' and teaching_locale = 'ja-JP')
    or (target_language = 'fr' and teaching_locale = 'fr-FR')),
  add constraint memories_generation_spec_v1 check (generation_spec is null or (
    jsonb_typeof(generation_spec) = 'object'
    and generation_spec @> jsonb_build_object('schemaVersion',1,'catalogVersion',1,
      'targetLanguage',target_language,'translationLanguage',translation_language,
      'teachingLocale',teaching_locale,'generationFormat','dual_tabs_v1')
    and coalesce(generation_spec->>'level' in ('starter','beginner','intermediate','advanced'), false)));

alter table public.memory_sentences
  add column target_text text,
  add column translation_text text,
  add column content_version integer not null default 1,
  add column learning_material jsonb;
-- Deliberately no trim, normalization, regenerated IDs, or state updates.
update public.memory_sentences set target_text = english, translation_text = chinese;
-- Abort rather than invent translations for malformed historical rows.
alter table public.memory_sentences
  alter column target_text set not null,
  alter column translation_text set not null,
  alter column english drop not null,
  alter column chinese drop not null,
  add constraint memory_sentences_content_version_v1 check (content_version = 1);

create function public.valid_learning_material_v1(p_material jsonb, p_text text)
returns boolean language plpgsql immutable
set search_path = pg_catalog, public, pg_temp
as $$
declare v_segment jsonb; v_text text := ''; v_ids text[] := '{}';
begin
  if p_material is null then return true; end if;
  if jsonb_typeof(p_material) <> 'object' or octet_length(p_material::text) > 32768
    or not (p_material @> '{"schemaVersion":1,"policyVersion":1}'::jsonb)
    or jsonb_typeof(p_material->'segments') is distinct from 'array'
    or (p_material->>'textDigest') is distinct from encode(sha256(convert_to(p_text,'UTF8')),'hex')
    or exists (select 1 from jsonb_object_keys(p_material) k
      where k not in ('schemaVersion','textDigest','policyVersion','segments')) then return false; end if;
  if jsonb_array_length(p_material->'segments') not between 1 and 256 then return false; end if;
  if p_material ? 'textDigest' and (jsonb_typeof(p_material->'textDigest') <> 'string'
    or length(p_material->>'textDigest') not between 1 and 128) then return false; end if;
  for v_segment in select value from jsonb_array_elements(p_material->'segments') loop
    if jsonb_typeof(v_segment) <> 'object'
      or jsonb_typeof(v_segment->'id') is distinct from 'string'
      or length(v_segment->>'id') not between 1 and 100
      or v_segment->>'id' = any(v_ids)
      or jsonb_typeof(v_segment->'surface') is distinct from 'string'
      or length(v_segment->>'surface') not between 1 and 2000
      or jsonb_typeof(v_segment->'canBlank') is distinct from 'boolean'
      or not coalesce(v_segment->>'kind' in ('word','particle','phrase','punctuation','whitespace'),false)
      or exists (select 1 from jsonb_object_keys(v_segment) k
        where k not in ('id','surface','reading','kind','canBlank')) then return false; end if;
    if v_segment ? 'reading' and (jsonb_typeof(v_segment->'reading') <> 'string'
      or length(v_segment->>'reading') not between 1 and 500) then return false; end if;
    if v_segment->>'kind' in ('punctuation','whitespace') and (v_segment->>'canBlank')::boolean then return false; end if;
    if v_segment->>'kind' = 'whitespace' and v_segment->>'surface' !~ '^[[:space:]]+$' then return false; end if;
    v_ids := array_append(v_ids,v_segment->>'id');
    v_text := v_text || (v_segment->>'surface');
  end loop;
  return v_text = p_text;
end;
$$;
alter table public.memory_sentences add constraint memory_sentences_learning_material_v1
  check (public.valid_learning_material_v1(learning_material,target_text));

create function public.protect_memory_content_v2()
returns trigger language plpgsql
set search_path = pg_catalog, public, pg_temp
as $$
begin
  if tg_op = 'UPDATE' and
    (new.id,new.user_id,new.target_language,new.translation_language,new.teaching_locale,
     new.content_schema_version,new.created_at,new.image_url,new.generation_spec)
    is distinct from
    (old.id,old.user_id,old.target_language,old.translation_language,old.teaching_locale,
     old.content_schema_version,old.created_at,old.image_url,old.generation_spec) then
    raise exception 'immutable_content' using errcode = '22023';
  end if;
  if current_user in ('anon','authenticated') then
    if not public.is_legacy_content_v1(new.target_language,new.translation_language,new.teaching_locale)
      or (tg_op = 'INSERT' and new.generation_spec is not null) then raise exception 'legacy_content_only' using errcode = '42501'; end if;
    if tg_op = 'UPDATE' and to_jsonb(new) is distinct from to_jsonb(old) then
      raise exception 'immutable_content' using errcode = '22023';
    end if;
  end if;
  return new;
end;
$$;
create trigger protect_memory_content_v2 before insert or update on public.memories
for each row execute function public.protect_memory_content_v2();

create function public.project_sentence_content_v2()
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
    (new.id,new.memory_id,new.target_text,new.translation_text,new.content_version,new.presentation_group,new.sort_order)
    is distinct from
    (old.id,old.memory_id,old.target_text,old.translation_text,old.content_version,old.presentation_group,old.sort_order) then
    raise exception 'immutable_content' using errcode = '22023';
  end if;
  if current_user in ('anon','authenticated') then
    if not v_legacy then raise exception 'legacy_content_only' using errcode = '42501'; end if;
    if (tg_op = 'INSERT' and new.learning_material is not null)
      or (tg_op = 'UPDATE' and (to_jsonb(new) - 'is_favorite') is distinct from (to_jsonb(old) - 'is_favorite')) then
      raise exception 'immutable_content' using errcode = '22023';
    end if;
  end if;
  new.english := case when v_legacy then new.target_text else null end;
  new.chinese := case when v_legacy then new.translation_text else null end;
  return new;
end;
$$;
create trigger project_sentence_content_v2 before insert or update on public.memory_sentences
for each row execute function public.project_sentence_content_v2();

create index memories_owner_language_page_v2 on public.memories(user_id,target_language,created_at desc,id desc);

-- RESTRICTIVE guards AND with every existing permissive policy. No hosted
-- policy is dropped, and no additional direct REST access is granted.
alter table public.memories enable row level security;
alter table public.memory_sentences enable row level security;
create policy multilingual_legacy_guard on public.memories as restrictive for all to anon, authenticated
using (user_id = auth.uid() and public.is_legacy_content_v1(target_language,translation_language,teaching_locale))
with check (user_id = auth.uid() and public.is_legacy_content_v1(target_language,translation_language,teaching_locale));
create policy multilingual_legacy_guard on public.memory_sentences as restrictive for all to anon, authenticated
using (exists (select 1 from public.memories m where m.id = memory_id and m.user_id = auth.uid()))
with check (exists (select 1 from public.memories m where m.id = memory_id and m.user_id = auth.uid()));

do $$
declare v_table text; v_predicate text;
begin
  foreach v_table in array array['sentence_study_progress','album_flip_progress','sentence_embeddings',
    'study_scene_sentences','study_scene_sentence_reviews','study_topic_expression_examples'] loop
    if to_regclass('public.' || v_table) is null then continue; end if;
    v_predicate := format('exists (select 1 from public.memory_sentences s join public.memories m on m.id=s.memory_id where s.id=%I.sentence_id and m.user_id=auth.uid())',v_table);
    if exists (select 1 from pg_attribute where attrelid = to_regclass('public.' || v_table) and attname='user_id' and not attisdropped) then
      v_predicate := v_predicate || format(' and %I.user_id=auth.uid()',v_table);
    end if;
    if exists (select 1 from pg_attribute where attrelid = to_regclass('public.' || v_table) and attname='memory_id' and not attisdropped) then
      v_predicate := v_predicate || format(' and exists (select 1 from public.memory_sentences s where s.id=%1$I.sentence_id and s.memory_id=%1$I.memory_id)',v_table);
    end if;
    if v_table in ('study_scene_sentences','study_scene_sentence_reviews')
      and to_regclass('public.study_scenes') is not null then
      v_predicate := v_predicate || format(' and exists (select 1 from public.study_scenes scene where scene.id=%I.scene_id and scene.user_id=auth.uid())',v_table);
    end if;
    execute format('alter table public.%I enable row level security',v_table);
    execute format('create policy multilingual_legacy_guard on public.%I as restrictive for all to anon, authenticated using (%s) with check (%s)',v_table,v_predicate,v_predicate);
  end loop;
  foreach v_table in array array['generation_jobs','guest_generation_jobs'] loop
    if to_regclass('public.' || v_table) is null then continue; end if;
    -- to_jsonb supports baseline job tables before the generation migration.
    v_predicate := format($p$%1$I.user_id=auth.uid() and coalesce(to_jsonb(%1$I)->>'request_schema_version','1')='1' and
      ((coalesce(to_jsonb(%1$I)->'generation_spec','null'::jsonb) = 'null'::jsonb
        and coalesce(to_jsonb(%1$I)->>'request_schema_version','1')='1')
       or (to_jsonb(%1$I)->'generation_spec') @> '{"schemaVersion":1,"catalogVersion":1,"targetLanguage":"en","translationLanguage":"zh-Hans","teachingLocale":"en-US","generationFormat":"dual_tabs_v1"}'::jsonb)$p$,v_table);
    if v_table = 'generation_jobs' then
      v_predicate := v_predicate || ' and (memory_id is null or exists (select 1 from public.memories m where m.id=generation_jobs.memory_id and m.user_id=auth.uid()))';
    end if;
    execute format('alter table public.%I enable row level security',v_table);
    execute format('create policy multilingual_legacy_guard on public.%I as restrictive for all to anon, authenticated using (%s) with check (%s)',v_table,v_predicate,v_predicate);
  end loop;
end;
$$;

-- These caches are explicitly server-only in their checked-in migrations.
-- Preserve grants/policies, but prevent a broad hosted permissive policy from
-- exposing generic payloads through a forgotten direct table path.
do $$
declare v_table text;
begin
  foreach v_table in array array['generation_enrichment_jobs','generation_enrichment_timings',
    'guest_sentence_embeddings','sentence_explanations','sentence_explanation_limits'] loop
    if to_regclass('public.' || v_table) is null then continue; end if;
    execute format('alter table public.%I enable row level security',v_table);
    execute format('create policy multilingual_server_only_guard on public.%I as restrictive for all to anon, authenticated using (false) with check (false)',v_table);
  end loop;
end;
$$;

-- Check cache provenance as definer: ordinary RLS would hide incompatible
-- examples before NOT EXISTS, accidentally marking a mixed cache as safe.
create function public.legacy_topic_expression_allowed_v1(p_expression_id uuid)
returns boolean language plpgsql stable security definer
set search_path = pg_catalog, public, pg_temp
as $$
begin
  return exists (select 1 from public.study_topic_expressions e
    where e.id=p_expression_id and e.user_id=auth.uid())
    and not exists (
      select 1 from public.study_topic_expression_examples link
      left join public.memory_sentences s on s.id=link.sentence_id
      left join public.memories m on m.id=s.memory_id
      where link.expression_id=p_expression_id and
        (m.user_id is distinct from auth.uid() or not public.is_legacy_content_v1(m.target_language,m.translation_language,m.teaching_locale))
    );
end;
$$;
create function public.legacy_topic_cache_allowed_v1(p_topic_key text)
returns boolean language plpgsql stable security definer
set search_path = pg_catalog, public, pg_temp
as $$
begin
  return auth.uid() is not null and not exists (
    select 1 from public.study_topic_expressions e where e.user_id=auth.uid() and e.topic_key=p_topic_key
      and not public.legacy_topic_expression_allowed_v1(e.id)
  );
end;
$$;
do $$
begin
  if to_regclass('public.study_topic_expressions') is not null
    and to_regclass('public.study_topic_expression_examples') is not null
    and to_regclass('public.study_topic_expression_sets') is not null then
    execute 'alter table public.study_topic_expressions enable row level security';
    execute 'alter table public.study_topic_expression_sets enable row level security';
    execute 'create policy multilingual_legacy_guard on public.study_topic_expressions as restrictive for all to anon, authenticated using (user_id=auth.uid() and public.legacy_topic_expression_allowed_v1(id)) with check (false)';
    execute 'create policy multilingual_legacy_guard on public.study_topic_expression_sets as restrictive for all to anon, authenticated using (user_id=auth.uid() and public.legacy_topic_cache_allowed_v1(topic_key)) with check (false)';
    execute 'create policy multilingual_expression_owner_guard on public.study_topic_expression_examples as restrictive for all to anon, authenticated using (public.legacy_topic_expression_allowed_v1(expression_id)) with check (false)';
  end if;
end;
$$;

-- Separate from memory RLS: an old client must not overwrite a hidden image.
create function public.legacy_storage_mutation_allowed_v1(p_bucket text,p_name text)
returns boolean language sql stable security definer
set search_path = pg_catalog, public, pg_temp
as $$
  select p_bucket <> 'memories' or not exists (
    select 1 from public.memories m where m.image_url = p_name
      and not public.is_legacy_content_v1(m.target_language,m.translation_language,m.teaching_locale)
  )
$$;
do $$
begin
  if to_regclass('storage.objects') is not null then
    execute 'create policy multilingual_storage_delete_guard on storage.objects as restrictive for delete to anon, authenticated using (public.legacy_storage_mutation_allowed_v1(bucket_id,name))';
    execute 'create policy multilingual_storage_update_guard on storage.objects as restrictive for update to anon, authenticated using (public.legacy_storage_mutation_allowed_v1(bucket_id,name)) with check (public.legacy_storage_mutation_allowed_v1(bucket_id,name))';
    execute 'create policy multilingual_storage_insert_guard on storage.objects as restrictive for insert to anon, authenticated with check (public.legacy_storage_mutation_allowed_v1(bucket_id,name))';
  else
    raise warning 'Storage schema unavailable: multilingual Storage policy audit is a release blocker';
  end if;
end;
$$;

create function public.require_content_user_v1()
returns uuid language plpgsql stable
set search_path = pg_catalog, public, pg_temp
as $$
declare v_user uuid := auth.uid();
begin
  if v_user is null or coalesce((auth.jwt()->>'is_anonymous')::boolean,false) then
    raise exception 'Sign in required' using errcode = '42501';
  end if;
  return v_user;
end;
$$;

create function public.memory_content_dto_v2(p_memory_id uuid)
returns jsonb language sql stable
set search_path = pg_catalog, public, pg_temp
as $$
  select jsonb_build_object('schemaVersion',2,'id',m.id,'createdAt',m.created_at,'imagePath',coalesce(m.image_url,''),
    'tags',coalesce(to_jsonb(m.tags),'[]'::jsonb),
    'context',jsonb_build_object('schemaVersion',2,'targetLanguage',m.target_language,
      'translationLanguage',m.translation_language,'teachingLocale',m.teaching_locale),
    'sentences',coalesce((select jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
      'id',s.id,'targetText',s.target_text,'translationText',s.translation_text,'contentVersion',s.content_version,
      'learningTopicIDs',coalesce(to_jsonb(s.learning_topic_ids),'[]'::jsonb),
      'presentationGroup',s.presentation_group,'isFavorite',s.is_favorite,'learningMaterial',s.learning_material))
      order by s.sort_order,s.id) from public.memory_sentences s where s.memory_id=m.id),'[]'::jsonb))
  from public.memories m where m.id=p_memory_id
$$;

create function public.get_memory_v2(p_memory_id uuid)
returns jsonb language plpgsql stable security definer
set search_path = pg_catalog, public, pg_temp
as $$
declare v_user uuid := public.require_content_user_v1();
begin
  if not exists (select 1 from public.memories where id=p_memory_id and user_id=v_user) then return null; end if;
  return public.memory_content_dto_v2(p_memory_id);
end;
$$;

create function public.list_memories_v2(p_target_language text default null,
  p_cursor_created_at timestamptz default null,p_cursor_id uuid default null,p_limit integer default 50)
returns jsonb language plpgsql stable security definer
set search_path = pg_catalog, public, pg_temp
as $$
declare v_user uuid := public.require_content_user_v1(); v_result jsonb;
begin
  if p_limit is null or p_limit not between 1 and 100
    or (p_cursor_created_at is null) <> (p_cursor_id is null)
    or (p_cursor_created_at is not null and not isfinite(p_cursor_created_at))
    or (p_target_language is not null and p_target_language not in ('en','es','ja','fr')) then
    raise exception 'invalid_content_cursor' using errcode = '22023';
  end if;
  with candidates as materialized (
    select m.id,m.created_at from public.memories m where m.user_id=v_user
      and (p_target_language is null or m.target_language=p_target_language)
      and (p_cursor_created_at is null or (m.created_at,m.id)<(p_cursor_created_at,p_cursor_id))
    order by m.created_at desc,m.id desc limit p_limit+1
  ), page as (select * from candidates order by created_at desc,id desc limit p_limit)
  select jsonb_build_object('schemaVersion',2,'memories',coalesce(
    (select jsonb_agg(public.memory_content_dto_v2(id) order by created_at desc,id desc) from page),'[]'::jsonb),
    'nextCursor',case when (select count(*) from candidates)>p_limit then
      (select jsonb_build_object('createdAt',created_at,'id',id) from page order by created_at,id limit 1)
      else null end) into v_result;
  return v_result;
end;
$$;

create function public.set_sentence_favorite_v2(p_sentence_id uuid,p_is_favorite boolean)
returns jsonb language plpgsql security definer
set search_path = pg_catalog, public, pg_temp
as $$
declare v_user uuid := public.require_content_user_v1();
begin
  if p_is_favorite is null then raise exception 'invalid_favorite' using errcode='22023'; end if;
  update public.memory_sentences s set is_favorite=p_is_favorite
    from public.memories m where s.id=p_sentence_id and m.id=s.memory_id and m.user_id=v_user;
  if not found then raise exception 'sentence_not_found' using errcode='42501'; end if;
  return jsonb_build_object('sentenceID',p_sentence_id,'isFavorite',p_is_favorite);
end;
$$;

create table public.memory_deletion_receipts_v2 (
  user_id uuid not null references auth.users(id) on delete cascade,
  operation_id uuid not null, memory_id uuid not null, created_at timestamptz not null default now(),
  primary key(user_id,operation_id)
);
create table public.memory_image_cleanup_jobs_v2 (
  id uuid primary key default gen_random_uuid(),
  -- Cleanup must survive account deletion, including a failed Storage request.
  user_id uuid not null,
  memory_id uuid not null, bucket_id text not null default 'memories' check(bucket_id='memories'),
  image_path text not null, created_at timestamptz not null default now(),
  attempts integer not null default 0 check(attempts>=0), completed_at timestamptz,
  next_attempt_at timestamptz not null default now(),
  lease_id uuid, lease_until timestamptz, last_error text,
  unique(user_id,memory_id,image_path)
);
create index memory_image_cleanup_jobs_due_v2 on public.memory_image_cleanup_jobs_v2(next_attempt_at,created_at)
  where completed_at is null;
create index memory_image_cleanup_jobs_path_v2 on public.memory_image_cleanup_jobs_v2(image_path);
alter table public.memory_deletion_receipts_v2 enable row level security;
alter table public.memory_image_cleanup_jobs_v2 enable row level security;
revoke all on public.memory_deletion_receipts_v2,public.memory_image_cleanup_jobs_v2 from public,anon,authenticated;
grant select,update,delete on public.memory_image_cleanup_jobs_v2 to service_role;

-- Keep completed rows as retired-path tombstones. Both direct legacy deletes and
-- account cascades enqueue here, atomically with deletion of the memory itself.
create function public.guard_memory_image_lifecycle_v2()
returns trigger language plpgsql security definer
set search_path = pg_catalog, public, pg_temp as $$
declare v_path text := case when tg_op='DELETE' then old.image_url else new.image_url end;
begin
  if nullif(v_path,'') is not null then
    perform pg_advisory_xact_lock(hashtextextended('memory_image:'||v_path,0));
    if tg_op='INSERT' then
      if exists(select 1 from public.memory_image_cleanup_jobs_v2 where image_path=v_path) then
        raise exception 'retired_memory_image_path' using errcode='22023';
      end if;
    else
      insert into public.memory_image_cleanup_jobs_v2(user_id,memory_id,image_path)
        values(old.user_id,old.id,v_path) on conflict do nothing;
    end if;
  end if;
  if tg_op='DELETE' then return old; end if;
  return new;
end;
$$;
create trigger guard_memory_image_lifecycle_v2 before insert or delete on public.memories
  for each row execute function public.guard_memory_image_lifecycle_v2();

create or replace function public.legacy_storage_mutation_allowed_v1(p_bucket text,p_name text)
returns boolean language sql stable security definer
set search_path = pg_catalog, public, pg_temp as $$
  select p_bucket <> 'memories' or (
    not exists(select 1 from public.memory_image_cleanup_jobs_v2 where image_path=p_name)
    and not exists(select 1 from public.memories m where m.image_url=p_name
      and not public.is_legacy_content_v1(m.target_language,m.translation_language,m.teaching_locale))
  )
$$;

create function public.claim_memory_image_cleanup_v2(p_limit integer default 10)
returns setof public.memory_image_cleanup_jobs_v2 language plpgsql security definer
set search_path = pg_catalog, public, pg_temp as $$
begin
  if p_limit is null or p_limit<1 or p_limit>25 then raise exception 'invalid_cleanup_limit'; end if;
  return query with candidates as (
    select id from public.memory_image_cleanup_jobs_v2
    where completed_at is null and next_attempt_at<=now() and (lease_until is null or lease_until<=now())
    order by next_attempt_at,created_at,id for update skip locked limit p_limit
  ) update public.memory_image_cleanup_jobs_v2 j
    set attempts=j.attempts+1,lease_id=gen_random_uuid(),lease_until=now()+interval '5 minutes'
    from candidates c where j.id=c.id returning j.*;
end;
$$;

create function public.authorize_memory_image_cleanup_v2(p_job_id uuid,p_lease_id uuid)
returns boolean language sql stable security definer
set search_path = pg_catalog, public, pg_temp as $$
  select exists(select 1 from public.memory_image_cleanup_jobs_v2 j
    where j.id=p_job_id and j.lease_id=p_lease_id and j.lease_until>now() and j.completed_at is null
      and j.bucket_id='memories'
      and j.image_path ~ ('^'||j.user_id::text||'/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}[.]jpg$')
      and not exists(select 1 from public.memories m where m.image_url=j.image_path))
$$;

create function public.finish_memory_image_cleanup_v2(p_job_id uuid,p_lease_id uuid,p_success boolean,p_error text default null)
returns boolean language plpgsql security definer
set search_path = pg_catalog, public, pg_temp as $$
declare v_count integer;
begin
  if p_success is null then raise exception 'invalid_cleanup_result'; end if;
  update public.memory_image_cleanup_jobs_v2
    set completed_at=case when p_success then now() end,
      next_attempt_at=now()+make_interval(secs=>least(86400,60*power(2,least(attempts,10)))::integer),
      last_error=case when p_success then null else left(coalesce(p_error,'cleanup_failed'),100) end,
      lease_id=null,lease_until=null
    where id=p_job_id and lease_id=p_lease_id and lease_until>now() and completed_at is null;
  get diagnostics v_count=row_count;
  return v_count=1;
end;
$$;
revoke all on function public.guard_memory_image_lifecycle_v2(),public.claim_memory_image_cleanup_v2(integer),
  public.authorize_memory_image_cleanup_v2(uuid,uuid),public.finish_memory_image_cleanup_v2(uuid,uuid,boolean,text)
  from public,anon,authenticated;
grant execute on function public.claim_memory_image_cleanup_v2(integer),public.authorize_memory_image_cleanup_v2(uuid,uuid),
  public.finish_memory_image_cleanup_v2(uuid,uuid,boolean,text) to service_role;

create function public.delete_memory_v2(p_memory_id uuid,p_operation_id uuid)
returns jsonb language plpgsql security definer
set search_path = pg_catalog, public, pg_temp
as $$
declare v_user uuid := public.require_content_user_v1(); v_memory public.memories%rowtype; v_previous uuid;
begin
  if p_memory_id is null or p_operation_id is null then raise exception 'invalid_deletion' using errcode='22023'; end if;
  perform pg_advisory_xact_lock(hashtextextended('memory_delete:'||v_user::text||':'||p_operation_id::text,0));
  select memory_id into v_previous from public.memory_deletion_receipts_v2
    where user_id=v_user and operation_id=p_operation_id;
  if found then
    if v_previous<>p_memory_id then raise exception 'operation_context_mismatch' using errcode='22023'; end if;
  else
    select * into v_memory from public.memories where id=p_memory_id and user_id=v_user for update;
    if not found then
      -- Foreign and never-seen IDs are indistinguishable. A separate valid
      -- operation can acknowledge an already-deleted memory for this owner.
      if not exists(select 1 from public.memory_deletion_receipts_v2 where user_id=v_user and memory_id=p_memory_id) then
        raise exception 'memory_not_found' using errcode='42501';
      end if;
    else
      delete from public.memories where id=p_memory_id and user_id=v_user;
    end if;
    insert into public.memory_deletion_receipts_v2(user_id,operation_id,memory_id) values(v_user,p_operation_id,p_memory_id);
  end if;
  return jsonb_build_object('memoryID',p_memory_id,'operationID',p_operation_id,'deleted',true);
end;
$$;

create table public.user_learning_preferences (
  user_id uuid primary key references auth.users(id) on delete cascade,
  selection_mode text not null check(selection_mode in ('standard','legacyEnglish')),
  target_language text not null, translation_language text not null, explanation_language text not null,
  revision bigint not null check(revision>0), updated_at timestamptz not null default now(),
  foreign key(target_language,translation_language) references public.language_capabilities_v1(target_language,translation_language),
  check ((selection_mode='standard' and explanation_language=translation_language)
    or (selection_mode='legacyEnglish' and target_language='en' and translation_language='zh-Hans'
      and explanation_language in ('zh-Hans','en')))
);
create table public.user_language_preferences (
  user_id uuid not null references auth.users(id) on delete cascade,
  target_language text not null check(target_language in ('en','es','ja','fr')),
  level text check(level in ('starter','beginner','intermediate','advanced')),
  level_revision bigint not null default 0 check(level_revision>=0),
  speech_voice text,
  voice_revision bigint not null default 0 check(voice_revision>=0),
  updated_at timestamptz not null default now(), primary key(user_id,target_language),
  check(speech_voice is null or (target_language='en' and speech_voice in ('Mia','Chloe','Milo','Dean')))
);
alter table public.user_learning_preferences enable row level security;
alter table public.user_language_preferences enable row level security;
revoke all on public.user_learning_preferences,public.user_language_preferences from public,anon,authenticated;

create function public.legacy_level_to_id_v1(p_level text)
returns text language sql immutable
set search_path = pg_catalog, public, pg_temp
as $$ select case p_level when U&'\542F\8499' then 'starter' when U&'\7B80\5355' then 'beginner'
  when U&'\4E2D\7B49' then 'intermediate' when U&'\9AD8\7EA7' then 'advanced' end $$;
create function public.level_id_to_legacy_v1(p_level text)
returns text language sql immutable
set search_path = pg_catalog, public, pg_temp
as $$ select case p_level when 'starter' then U&'\542F\8499' when 'beginner' then U&'\7B80\5355'
  when 'intermediate' then U&'\4E2D\7B49' when 'advanced' then U&'\9AD8\7EA7' end $$;

insert into public.user_language_preferences(user_id,target_language,level,level_revision,speech_voice,voice_revision)
select id,'en',public.legacy_level_to_id_v1(english_level),
  case when english_level is null then 0 else 1 end,speech_voice,case when speech_voice is null then 0 else 1 end
from public.profiles;

-- Profile row is always the first lock. There is deliberately no reverse
-- preference-table trigger: new RPCs update the profile then their CAS row.
create function public.sync_legacy_english_preferences_v1()
returns trigger language plpgsql security definer
set search_path = pg_catalog, public, pg_temp
as $$
begin
  insert into public.user_language_preferences as p
    (user_id,target_language,level,level_revision,speech_voice,voice_revision)
  values(new.id,'en',public.legacy_level_to_id_v1(new.english_level),
    case when new.english_level is null then 0 else 1 end,new.speech_voice,case when new.speech_voice is null then 0 else 1 end)
  on conflict(user_id,target_language) do update set
    level=excluded.level,
    level_revision=p.level_revision + case when p.level is distinct from excluded.level then 1 else 0 end,
    speech_voice=excluded.speech_voice,
    voice_revision=p.voice_revision + case when p.speech_voice is distinct from excluded.speech_voice then 1 else 0 end,
    updated_at=now();
  return new;
end;
$$;
create trigger sync_legacy_english_preferences_v1 after insert or update of english_level,speech_voice on public.profiles
for each row execute function public.sync_legacy_english_preferences_v1();

create function public.get_learning_preferences_v1()
returns jsonb language plpgsql stable security definer
set search_path = pg_catalog, public, pg_temp
as $$
declare v_user uuid := public.require_content_user_v1();
begin
  return jsonb_build_object('schemaVersion',1,'selection',(
    select jsonb_build_object('mode',selection_mode,'targetLanguage',target_language,
      'translationLanguage',translation_language,'explanationLanguage',explanation_language,'revision',revision)
    from public.user_learning_preferences where user_id=v_user),
    'languages',coalesce((select jsonb_agg(jsonb_build_object('targetLanguage',target_language,'level',level,
      'levelRevision',level_revision,'speechVoice',speech_voice,'voiceRevision',voice_revision) order by target_language)
      from public.user_language_preferences where user_id=v_user),'[]'::jsonb));
end;
$$;

create function public.update_learning_preferences_v1(p_patch jsonb)
returns jsonb language plpgsql security definer
set search_path = pg_catalog, public, pg_temp
as $$
declare
  v_user uuid := public.require_content_user_v1(); v_selection jsonb := p_patch->'selection'; v_language jsonb := p_patch->'language';
  v_revision bigint; v_previous public.user_language_preferences%rowtype; v_target text;
begin
  if p_patch is null or jsonb_typeof(p_patch)<>'object' or p_patch='{}'::jsonb
    or exists(select 1 from jsonb_object_keys(p_patch) k where k not in ('selection','language')) then
    raise exception 'invalid_preferences_patch' using errcode='22023';
  end if;
  perform 1 from public.profiles where id=v_user for update;
  if not found then raise exception 'profile_not_found' using errcode='42501'; end if;
  if p_patch ? 'selection' then
    if jsonb_typeof(v_selection) is distinct from 'object'
      or not (v_selection ?& array['mode','targetLanguage','translationLanguage','explanationLanguage','expectedRevision'])
      or exists(select 1 from jsonb_object_keys(v_selection) k where k not in
        ('mode','targetLanguage','translationLanguage','explanationLanguage','expectedRevision'))
      or jsonb_typeof(v_selection->'expectedRevision') is distinct from 'number'
      or (v_selection->>'expectedRevision') !~ '^(0|[1-9][0-9]*)$' then
      raise exception 'invalid_selection' using errcode='22023';
    end if;
    select revision into v_revision from public.user_learning_preferences where user_id=v_user for update;
    if coalesce(v_revision,0)<>(v_selection->>'expectedRevision')::bigint then
      raise exception 'preference_revision_conflict' using errcode='40001';
    end if;
    insert into public.user_learning_preferences(user_id,selection_mode,target_language,translation_language,explanation_language,revision)
    values(v_user,v_selection->>'mode',v_selection->>'targetLanguage',v_selection->>'translationLanguage',
      v_selection->>'explanationLanguage',coalesce(v_revision,0)+1)
    on conflict(user_id) do update set selection_mode=excluded.selection_mode,target_language=excluded.target_language,
      translation_language=excluded.translation_language,explanation_language=excluded.explanation_language,
      revision=excluded.revision,updated_at=now();
  end if;
  if p_patch ? 'language' then
    if jsonb_typeof(v_language) is distinct from 'object'
      or not coalesce(v_language->>'targetLanguage' in ('en','es','ja','fr'),false)
      or not (v_language ? 'level' or v_language ? 'speechVoice')
      or exists(select 1 from jsonb_object_keys(v_language) k where k not in
        ('targetLanguage','level','expectedLevelRevision','speechVoice','expectedVoiceRevision'))
      or (v_language ? 'level') <> (v_language ? 'expectedLevelRevision')
      or (v_language ? 'speechVoice') <> (v_language ? 'expectedVoiceRevision') then
      raise exception 'invalid_language_preferences' using errcode='22023';
    end if;
    if v_language ? 'level' and (not coalesce(v_language->>'level' in ('starter','beginner','intermediate','advanced'),false)
      or jsonb_typeof(v_language->'expectedLevelRevision') is distinct from 'number'
      or (v_language->>'expectedLevelRevision') !~ '^(0|[1-9][0-9]*)$') then
      raise exception 'invalid_level' using errcode='22023';
    end if;
    if v_language ? 'speechVoice' and (jsonb_typeof(v_language->'expectedVoiceRevision') is distinct from 'number'
      or (v_language->>'expectedVoiceRevision') !~ '^(0|[1-9][0-9]*)$'
      or not (v_language->'speechVoice'='null'::jsonb or
        (v_language->>'targetLanguage'='en' and v_language->>'speechVoice' in ('Mia','Chloe','Milo','Dean')))) then
      raise exception 'invalid_voice' using errcode='22023';
    end if;
    v_target := v_language->>'targetLanguage';
    insert into public.user_language_preferences(user_id,target_language) values(v_user,v_target) on conflict do nothing;
    select * into v_previous from public.user_language_preferences where user_id=v_user and target_language=v_target for update;
    if (v_language ? 'level' and v_previous.level_revision<>(v_language->>'expectedLevelRevision')::bigint)
      or (v_language ? 'speechVoice' and v_previous.voice_revision<>(v_language->>'expectedVoiceRevision')::bigint) then
      raise exception 'preference_revision_conflict' using errcode='40001';
    end if;
    if v_target='en' then
      update public.profiles set
        english_level=case when v_language ? 'level' then public.level_id_to_legacy_v1(v_language->>'level') else english_level end,
        speech_voice=case when v_language ? 'speechVoice' then v_language->>'speechVoice' else speech_voice end
      where id=v_user;
    end if;
    update public.user_language_preferences set
      level=case when v_language ? 'level' then v_language->>'level' else level end,
      level_revision=v_previous.level_revision+case when v_language ? 'level' then 1 else 0 end,
      speech_voice=case when v_language ? 'speechVoice' then v_language->>'speechVoice' else speech_voice end,
      voice_revision=v_previous.voice_revision+case when v_language ? 'speechVoice' then 1 else 0 end,
      updated_at=now() where user_id=v_user and target_language=v_target;
  end if;
  return public.get_learning_preferences_v1();
end;
$$;

create function public.get_language_capabilities_v1(p_catalog_version integer default 1)
returns jsonb language plpgsql stable security definer
set search_path = pg_catalog, public, pg_temp
as $$
begin
  -- Anonymous-auth guests need the same rollout flags before generating.
  -- This endpoint exposes no account content, but still requires a valid JWT.
  if auth.uid() is null then raise exception 'authentication_required' using errcode='42501'; end if;
  if p_catalog_version is distinct from 1 then raise exception 'unsupported_catalog_version' using errcode='22023'; end if;
  return jsonb_build_object('schemaVersion',1,'catalogVersion',1,'voiceCatalogVersion',1,
    'combinations',(select jsonb_agg(jsonb_build_object('targetLanguage',target_language,
      'translationLanguage',translation_language,'teachingLocale',teaching_locale,'canRead',true,
      'canGenerate',can_generate) order by target_language,translation_language) from public.language_capabilities_v1));
end;
$$;

create function public.get_album_flip_progress_v2(p_target_language text default null)
returns setof public.album_flip_progress language plpgsql stable security definer
set search_path = pg_catalog, public, pg_temp
as $$
declare v_user uuid := public.require_content_user_v1();
begin
  if p_target_language is not null and p_target_language not in ('en','es','ja','fr') then
    raise exception 'invalid_target_language' using errcode='22023';
  end if;
  return query select p.* from public.album_flip_progress p
    join public.memory_sentences s on s.id=p.sentence_id and s.memory_id=p.memory_id
    join public.memories m on m.id=s.memory_id
    where p.user_id=v_user and m.user_id=v_user and (p_target_language is null or m.target_language=p_target_language)
    order by p.last_feedback_at,p.sentence_id;
end;
$$;

-- Preserve the proven feedback algorithm, but place it behind private access.
-- The old wrapper explicitly filters; RLS cannot constrain SECURITY DEFINER.
alter function public.sync_album_flip_feedback(jsonb) rename to sync_album_flip_feedback_internal_v1;
revoke all on function public.sync_album_flip_feedback_internal_v1(jsonb) from public,anon,authenticated,service_role;
create function public.sync_album_flip_feedback_v2(p_events jsonb)
returns setof public.album_flip_progress language plpgsql security definer
set search_path = pg_catalog, public, pg_temp
as $$
begin
  perform public.require_content_user_v1();
  return query select * from public.sync_album_flip_feedback_internal_v1(p_events);
end;
$$;
create function public.sync_album_flip_feedback(p_events jsonb)
returns setof public.album_flip_progress language plpgsql security definer
set search_path = pg_catalog, public, pg_temp
as $$
declare v_user uuid := public.require_content_user_v1(); v_events jsonb;
begin
  if p_events is null or jsonb_typeof(p_events)<>'array' then raise exception 'Expected feedback array' using errcode='22023'; end if;
  if jsonb_array_length(p_events) not between 1 and 100 then raise exception 'Expected 1 to 100 feedback events' using errcode='22023'; end if;
  select jsonb_agg(e.value order by e.ordinality) into v_events
    from jsonb_array_elements(p_events) with ordinality e(value,ordinality)
    where exists (select 1 from public.memory_sentences s join public.memories m on m.id=s.memory_id
      where s.id=(e.value->>'sentence_id')::uuid and m.id=(e.value->>'memory_id')::uuid and m.user_id=v_user
        and public.is_legacy_content_v1(m.target_language,m.translation_language,m.teaching_locale));
  if v_events is null then return; end if;
  return query select * from public.sync_album_flip_feedback_internal_v1(v_events);
end;
$$;

-- Explicit ACLs also override environments with permissive default privileges.
revoke all on function public.is_legacy_content_v1(text,text,text),public.valid_learning_material_v1(jsonb,text),
  public.protect_memory_content_v2(),public.project_sentence_content_v2(),public.require_content_user_v1(),
  public.memory_content_dto_v2(uuid),public.legacy_storage_mutation_allowed_v1(text,text),
  public.legacy_topic_expression_allowed_v1(uuid),public.legacy_topic_cache_allowed_v1(text),
  public.legacy_level_to_id_v1(text),public.level_id_to_legacy_v1(text),public.sync_legacy_english_preferences_v1(),
  public.get_memory_v2(uuid),public.list_memories_v2(text,timestamptz,uuid,integer),
  public.set_sentence_favorite_v2(uuid,boolean),public.delete_memory_v2(uuid,uuid),
  public.get_learning_preferences_v1(),public.update_learning_preferences_v1(jsonb),
  public.get_language_capabilities_v1(integer),public.get_album_flip_progress_v2(text),
  public.sync_album_flip_feedback_v2(jsonb),public.sync_album_flip_feedback(jsonb)
from public,anon,authenticated,service_role;
grant execute on function public.is_legacy_content_v1(text,text,text),public.valid_learning_material_v1(jsonb,text),
  public.legacy_storage_mutation_allowed_v1(text,text) to anon,authenticated,service_role;
grant execute on function public.legacy_topic_expression_allowed_v1(uuid),public.legacy_topic_cache_allowed_v1(text)
  to anon,authenticated;
grant execute on function public.get_memory_v2(uuid),public.list_memories_v2(text,timestamptz,uuid,integer),
  public.set_sentence_favorite_v2(uuid,boolean),public.delete_memory_v2(uuid,uuid),
  public.get_learning_preferences_v1(),public.update_learning_preferences_v1(jsonb),
  public.get_language_capabilities_v1(integer),public.get_album_flip_progress_v2(text),
  public.sync_album_flip_feedback_v2(jsonb),public.sync_album_flip_feedback(jsonb) to authenticated;

notify pgrst,'reload schema';
commit;
