-- Requires multilingual_content; preserves all v1/v2 rows and the existing shared quota/lease semantics.
begin;
create function public.valid_sentence_explanation_v3(p_content jsonb)
returns boolean language plpgsql immutable set search_path = public, pg_temp as $$
declare p jsonb; titles text[] := '{}'; examples text[] := '{}';
begin
  if p_content is null or jsonb_typeof(p_content) <> 'object'
    or p_content->'version' is distinct from '3'::jsonb
    or coalesce(p_content->>'targetLanguage','') not in ('en','es','ja','fr')
    or coalesce(p_content->>'explanationLanguage','') not in ('zh-Hans','en','es','ja','fr')
    or coalesce(p_content->>'exampleTranslationLanguage','') not in ('zh-Hans','en','es','ja','fr')
    or jsonb_typeof(p_content->'points') is distinct from 'array' then return false; end if;
  if p_content->>'targetLanguage' <> 'en' and p_content->>'explanationLanguage' not in ('zh-Hans','en') then return false; end if;
  if p_content->>'exampleTranslationLanguage' <> p_content->>'explanationLanguage'
    and not (p_content->>'targetLanguage' = 'en' and p_content->>'explanationLanguage' = 'en'
      and p_content->>'exampleTranslationLanguage' = 'zh-Hans') then return false; end if;
  if jsonb_array_length(p_content->'points') not between 1 and 4 then return false; end if;
  for p in select value from jsonb_array_elements(p_content->'points') loop
    if jsonb_typeof(p) is distinct from 'object'
      or jsonb_typeof(p->'title') is distinct from 'string'
      or jsonb_typeof(p->'explanation') is distinct from 'string'
      or jsonb_typeof(p->'example'->'targetText') is distinct from 'string'
      or jsonb_typeof(p->'example'->'translationText') is distinct from 'string'
      or length(btrim(p->>'title')) not between 1 and 120
      or length(btrim(p->>'explanation')) not between 1 and 800
      or length(btrim(p->'example'->>'targetText')) not between 1 and 300
      or length(btrim(p->'example'->>'translationText')) not between 1 and 400 then return false; end if;
    if lower(btrim(p->>'title')) = any(titles) or lower(btrim(p->'example'->>'targetText')) = any(examples) then return false; end if;
    titles := array_append(titles,lower(btrim(p->>'title')));
    examples := array_append(examples,lower(btrim(p->'example'->>'targetText')));
  end loop;
  return true;
end;
$$;

alter table public.sentence_explanations
  drop constraint sentence_explanations_content_check,
  add constraint sentence_explanations_content_check check (
    content is null or coalesce(
      (jsonb_typeof(content) = 'object' and content->>'version' in ('1','2'))
      or public.valid_sentence_explanation_v3(content), false)
  );

-- Separate finish entrypoint: old finish continues to accept only legacy versions.
create function public.finish_sentence_explanation_v2(p_user_id uuid, p_fingerprint text, p_claim_id uuid, p_content jsonb)
returns boolean language plpgsql security definer set search_path = public, pg_temp as $$
declare completed uuid;
begin
  if not public.valid_sentence_explanation_v3(p_content) then raise exception 'Invalid explanation'; end if;
  update public.sentence_explanations set content = p_content, claim_id = null, lease_until = null
    where user_id = p_user_id and fingerprint = p_fingerprint and claim_id = p_claim_id
      and content is null and lease_until > now()
    returning user_id into completed;
  return completed is not null;
end;
$$;

-- A service-role-only lookup bypasses legacy RLS projections but never the explicit owner predicate.
create function public.sentence_explanation_source_v2(p_user_id uuid, p_sentence_id uuid)
returns jsonb language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_build_object(
    'targetText', s.target_text, 'translationText', s.translation_text,
    'contentVersion', s.content_version, 'contentSchemaVersion', m.content_schema_version,
    'targetLanguage', m.target_language, 'translationLanguage', m.translation_language,
    'teachingLocale', m.teaching_locale)
  from public.memory_sentences s join public.memories m on m.id = s.memory_id
  where s.id = p_sentence_id and m.user_id = p_user_id;
$$;

revoke all on function public.valid_sentence_explanation_v3(jsonb) from public, anon, authenticated;
revoke all on function public.finish_sentence_explanation_v2(uuid,text,uuid,jsonb) from public, anon, authenticated;
revoke all on function public.sentence_explanation_source_v2(uuid,uuid) from public, anon, authenticated;
grant execute on function public.valid_sentence_explanation_v3(jsonb) to service_role;
grant execute on function public.finish_sentence_explanation_v2(uuid,text,uuid,jsonb) to service_role;
grant execute on function public.sentence_explanation_source_v2(uuid,uuid) to service_role;
notify pgrst, 'reload schema';
commit;
