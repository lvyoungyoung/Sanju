--
-- PostgreSQL database dump
--


-- Dumped from database version 15.8
-- Dumped by pg_dump version 18.6

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: public; Type: SCHEMA; Schema: -; Owner: -
--



--
-- Name: SCHEMA public; Type: COMMENT; Schema: -; Owner: -
--



--
-- Name: _begin_study_session_v2(uuid, text, text, integer, text, text, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._begin_study_session_v2(p_session_id uuid, p_target_language text, p_scope text, p_limit integer, p_mode text, p_time_zone text, p_legacy boolean) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare
  v_zone text := public._study_zone_v2(p_time_zone);
  v_session public.study_sessions%rowtype;
  v_candidate record;
  v_ids uuid[] := '{}';
  v_remaining integer;
  v_items jsonb;
begin
  perform public._study_lock_v2();
  if p_session_id is null or p_limit is null or p_limit < 1 or p_limit > 1000 then raise exception 'invalid_study_session'; end if;
  select * into v_session from public.study_sessions where user_id = auth.uid() and session_id = p_session_id;
  if found then
    if v_session.target_language is distinct from p_target_language or v_session.study_scope is distinct from p_scope
      or v_session.mode is distinct from p_mode or v_session.time_zone is distinct from v_zone
      or v_session.requested_limit <> p_limit or v_session.legacy_only <> p_legacy then
      raise exception 'study_session_conflict';
    end if;
    v_ids := v_session.sentence_ids;
  else
    v_remaining := public._study_remaining_v2(v_zone);
    for v_candidate in select * from public._study_candidates_v2(p_target_language,p_scope,p_mode,v_zone,p_legacy)
    loop
      if not v_candidate.activated then
        if v_remaining <= 0 then continue; end if;
        insert into public.sentence_study_activations(user_id,sentence_id,source,session_id)
        values(auth.uid(),v_candidate.sentence_id,case when p_legacy then 'legacy' else 'session' end,p_session_id);
        v_remaining := v_remaining - 1;
      end if;
      v_ids := array_append(v_ids,v_candidate.sentence_id);
      exit when cardinality(v_ids) >= p_limit;
    end loop;
    insert into public.study_sessions(user_id,session_id,target_language,study_scope,mode,time_zone,requested_limit,legacy_only,sentence_ids)
    values(auth.uid(),p_session_id,p_target_language,p_scope,p_mode,v_zone,p_limit,p_legacy,v_ids);
  end if;
  -- Re-read by immutable session order, NOT the due queue. Retries survive progress changes,
  -- but neither a stale session nor an event receipt can resurrect deleted content.
  select coalesce(jsonb_agg(jsonb_build_object(
      'sentence_id',ms.id,'memory_id',m.id,'target_text',ms.target_text,'translation_text',ms.translation_text,
      'learning_material',ms.learning_material,'target_language',m.target_language,'translation_language',m.translation_language,
      'teaching_locale',m.teaching_locale,'image_path',m.image_url,'memory_created_at',m.created_at,
      'learning_step',coalesce(sp.learning_step,0),'mastered_review_count',coalesce(sp.mastered_review_count,0),
      'correct_count',coalesce(sp.correct_count,0),'wrong_count',coalesce(sp.wrong_count,0),
      'last_result',sp.last_result,'next_review_at',sp.next_review_at) order by ids.ordinality),'[]'::jsonb)
  into v_items
  from unnest(v_ids) with ordinality ids(id,ordinality)
  join public.memory_sentences ms on ms.id = ids.id join public.memories m on m.id = ms.memory_id and m.user_id = auth.uid()
  left join public.sentence_study_progress sp on sp.user_id = auth.uid() and sp.sentence_id = ms.id and sp.study_scope = p_scope;
  return jsonb_build_object('session_id',p_session_id,'sentence_ids',v_ids,'items',v_items,
    'remaining_new',public._study_remaining_v2(v_zone));
end;
$$;


--
-- Name: _merge_local_study_progress_v1(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._merge_local_study_progress_v1(p_items jsonb) RETURNS TABLE(sentence_id uuid, study_scope text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare
  v_time_zone text := public.sentence_study_time_zone();
  v_item jsonb;
  v_sentence_id uuid;
  v_learning_step integer;
  v_mastered_review_count integer;
  v_correct_count integer;
  v_wrong_count integer;
  v_last_result text;
  v_last_studied_at timestamptz;
  v_last_studied_on date;
  v_next_review_on date;
  v_next_review_at timestamptz;
begin
  if auth.uid() is null or p_items is null or jsonb_typeof(p_items) <> 'array' then
    return;
  end if;

  for v_item in select value from jsonb_array_elements(p_items)
  loop
    begin
      v_sentence_id := nullif(v_item ->> 'sentence_id', '')::uuid;
      v_learning_step := least(greatest(coalesce(nullif(v_item ->> 'learning_step', '')::integer, 0), 0), 5);
      v_mastered_review_count := greatest(coalesce(nullif(v_item ->> 'mastered_review_count', '')::integer, 0), 0);
      v_correct_count := greatest(coalesce(nullif(v_item ->> 'correct_count', '')::integer, 0), 0);
      v_wrong_count := greatest(coalesce(nullif(v_item ->> 'wrong_count', '')::integer, 0), 0);
      v_last_result := case when v_item ->> 'last_result' in ('correct', 'incorrect') then v_item ->> 'last_result' else null end;
      v_last_studied_at := nullif(v_item ->> 'last_studied_at', '')::timestamptz;
      v_last_studied_on := nullif(v_item ->> 'last_studied_on', '')::date;
      v_next_review_on := nullif(v_item ->> 'next_review_on', '')::date;
    exception when others then
      continue;
    end;

    if v_sentence_id is null then
      continue;
    end if;

    if v_last_studied_at is not null then
      v_last_studied_on := (v_last_studied_at at time zone v_time_zone)::date;
    end if;
    v_next_review_on := coalesce(v_next_review_on, v_last_studied_on, (now() at time zone v_time_zone)::date);
    v_next_review_at := v_next_review_on::timestamp at time zone v_time_zone;

    if not exists (
      select 1
      from public.memory_sentences as sentence
      join public.memories as memory on memory.id = sentence.memory_id
      where sentence.id = v_sentence_id
        and memory.user_id = auth.uid()
        and sentence.is_favorite = true
    ) then
      continue;
    end if;

    insert into public.sentence_study_progress as progress (
      user_id, sentence_id, study_scope, learning_step, mastered_review_count,
      correct_count, wrong_count, last_result, last_studied_at, last_studied_on, next_review_at
    ) values (
      auth.uid(), v_sentence_id, 'favorites', v_learning_step, v_mastered_review_count,
      v_correct_count, v_wrong_count, v_last_result, v_last_studied_at, v_last_studied_on, v_next_review_at
    )
    on conflict on constraint sentence_study_progress_user_id_sentence_id_scope_key do update
      set learning_step = greatest(progress.learning_step, excluded.learning_step),
          mastered_review_count = greatest(progress.mastered_review_count, excluded.mastered_review_count),
          correct_count = greatest(progress.correct_count, excluded.correct_count),
          wrong_count = greatest(progress.wrong_count, excluded.wrong_count),
          last_result = case
            when coalesce(excluded.last_studied_at, excluded.last_studied_on::timestamp at time zone v_time_zone) is not null
              and (coalesce(progress.last_studied_at, progress.last_studied_on::timestamp at time zone v_time_zone) is null
                or coalesce(excluded.last_studied_at, excluded.last_studied_on::timestamp at time zone v_time_zone)
                  >= coalesce(progress.last_studied_at, progress.last_studied_on::timestamp at time zone v_time_zone))
              then coalesce(excluded.last_result, progress.last_result)
            else progress.last_result
          end,
          last_studied_at = case
            when excluded.last_studied_at is null then progress.last_studied_at
            when progress.last_studied_at is null then excluded.last_studied_at
            else greatest(progress.last_studied_at, excluded.last_studied_at)
          end,
          last_studied_on = coalesce(
            (greatest(progress.last_studied_at, excluded.last_studied_at) at time zone v_time_zone)::date,
            greatest(progress.last_studied_on, excluded.last_studied_on)
          ),
          next_review_at = greatest(progress.next_review_at, excluded.next_review_at),
          updated_at = timezone('utc'::text, now());

    return query select v_sentence_id, 'favorites'::text;
  end loop;
end;
$$;


--
-- Name: _merge_study_progress_v2(jsonb, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._merge_study_progress_v2(p_items jsonb, p_legacy boolean) RETURNS TABLE(sentence_id uuid, study_scope text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare
  v_item jsonb; v_id uuid; v_first timestamptz; v_accepted record;
  v_owner uuid; v_language text; v_translation text; v_locale text;
  v_zone text := public.sentence_study_time_zone();
  v_step integer; v_reviews integer; v_correct integer; v_wrong integer; v_result text;
  v_last_at timestamptz; v_last_on date; v_next_on date; v_next_at timestamptz;
  v_has_progress boolean;
begin
  perform public._study_lock_v2();
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) > 1000 then
    raise exception 'invalid_study_import';
  end if;
  for v_item in select value from jsonb_array_elements(p_items) loop
    begin
      if jsonb_typeof(v_item) is distinct from 'object' then continue; end if;
      v_id := (v_item->>'sentence_id')::uuid;
      v_first := coalesce((v_item->>'first_activated_at')::timestamptz,now());
      if v_id is null or not isfinite(v_first) or v_first > now() + interval '5 minutes'
        or (v_item->>'last_studied_at')::timestamptz > now() + interval '5 minutes' then continue; end if;
    exception when invalid_text_representation or invalid_datetime_format or datetime_field_overflow then continue;
    end;
    select m.user_id,m.target_language,m.translation_language,m.teaching_locale
      into v_owner,v_language,v_translation,v_locale
      from public.memory_sentences s join public.memories m on m.id=s.memory_id
      where s.id=v_id for key share of s,m;
    if v_owner is not null and v_owner<>auth.uid() then continue; end if;
    if p_legacy then
      if v_owner is null or (v_language,v_translation,v_locale) is distinct from ('en'::text,'zh-Hans'::text,'en-US'::text) then continue; end if;
      for v_accepted in select * from public._merge_local_study_progress_v1(jsonb_build_array(v_item)) loop
        insert into public.sentence_study_activations(user_id,sentence_id,first_activated_at,source)
        values(auth.uid(),v_accepted.sentence_id,v_first,'import') on conflict on constraint sentence_study_activations_pkey do nothing;
        return query select v_accepted.sentence_id,v_accepted.study_scope;
      end loop;
      continue;
    end if;
    -- Guest sync has one progress scope. Missing/deleted local content supplies
    -- only a self-reported quota debit, never ownership evidence or SRS progress.
    if coalesce(v_item->>'study_scope','favorites')<>'favorites'
      or (v_owner is null and nullif(v_item->>'first_activated_at','') is null) then continue; end if;
    begin
      v_step := coalesce((v_item->>'learning_step')::integer,0);
      v_reviews := coalesce((v_item->>'mastered_review_count')::integer,0);
      v_correct := coalesce((v_item->>'correct_count')::integer,0);
      v_wrong := coalesce((v_item->>'wrong_count')::integer,0);
      v_result := v_item->>'last_result';
      v_last_at := nullif(v_item->>'last_studied_at','')::timestamptz;
      v_last_on := nullif(v_item->>'last_studied_on','')::date;
      v_next_on := nullif(v_item->>'next_review_on','')::date;
      if v_step not between 0 and 5 or least(v_reviews,v_correct,v_wrong)<0
        or (v_result is not null and v_result not in ('correct','incorrect'))
        or (v_last_at is not null and not isfinite(v_last_at))
        or (v_last_on is not null and (not isfinite(v_last_on) or v_last_on>(now() at time zone v_zone)::date))
        or (v_next_on is not null and not isfinite(v_next_on)) then continue; end if;
      if v_last_at is not null then v_last_on := (v_last_at at time zone v_zone)::date; end if;
      v_next_at := coalesce(v_next_on,v_last_on,(now() at time zone v_zone)::date)::timestamp at time zone v_zone;
    exception when invalid_text_representation or invalid_datetime_format or datetime_field_overflow or numeric_value_out_of_range then continue;
    end;
    v_has_progress := v_last_at is not null or v_last_on is not null
      or v_step>0 or v_reviews>0 or v_correct>0 or v_wrong>0 or v_result is not null;
    if not v_has_progress and nullif(v_item->>'first_activated_at','') is null then continue; end if;
    -- Activation-only imports must not manufacture a completed review. Preserve
    -- the old max/most-recent merge rules for actual owned progress, even unfavorited.
    if v_owner is not null and v_has_progress then
      insert into public.sentence_study_progress as progress(user_id,sentence_id,study_scope,learning_step,
        mastered_review_count,correct_count,wrong_count,last_result,last_studied_at,last_studied_on,next_review_at)
      values(auth.uid(),v_id,'favorites',v_step,v_reviews,v_correct,v_wrong,v_result,v_last_at,v_last_on,v_next_at)
      on conflict on constraint sentence_study_progress_user_id_sentence_id_scope_key do update set
        learning_step=greatest(progress.learning_step,excluded.learning_step),
        mastered_review_count=greatest(progress.mastered_review_count,excluded.mastered_review_count),
        correct_count=greatest(progress.correct_count,excluded.correct_count),
        wrong_count=greatest(progress.wrong_count,excluded.wrong_count),
        last_result=case when coalesce(excluded.last_studied_at,excluded.last_studied_on::timestamp at time zone v_zone) is not null
          and (coalesce(progress.last_studied_at,progress.last_studied_on::timestamp at time zone v_zone) is null
            or coalesce(excluded.last_studied_at,excluded.last_studied_on::timestamp at time zone v_zone)
              >=coalesce(progress.last_studied_at,progress.last_studied_on::timestamp at time zone v_zone))
          then coalesce(excluded.last_result,progress.last_result) else progress.last_result end,
        last_studied_at=greatest(progress.last_studied_at,excluded.last_studied_at),
        last_studied_on=coalesce((greatest(progress.last_studied_at,excluded.last_studied_at) at time zone v_zone)::date,
          greatest(progress.last_studied_on,excluded.last_studied_on)),
        next_review_at=greatest(progress.next_review_at,excluded.next_review_at),updated_at=now();
    end if;
    insert into public.sentence_study_activations(user_id,sentence_id,first_activated_at,source)
      values(auth.uid(),v_id,v_first,'import') on conflict on constraint sentence_study_activations_pkey do nothing;
    -- Do not acknowledge unstored progress when content upload is still pending.
    -- Quota is already durable; a later retry can merge progress without charging again.
    if v_owner is not null or not v_has_progress then
      return query select v_id,'favorites'::text;
    end if;
  end loop;
end;
$$;


--
-- Name: _study_candidates_v2(text, text, text, text, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._study_candidates_v2(p_language text, p_scope text, p_mode text, p_zone text, p_legacy boolean DEFAULT false) RETURNS TABLE(sentence_id uuid, priority integer, item jsonb, activated boolean)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
begin
  if auth.uid() is null then raise exception 'authentication_required'; end if;
  if p_language is null or p_language not in ('en','es','ja','fr') or p_mode is null or p_mode not in ('due','today') then
    raise exception 'invalid_study_filter';
  end if;
  if p_scope is null or (p_scope <> 'favorites' and not exists (
    select 1 from public.study_scenes where user_id = auth.uid() and 'scene:' || id::text = p_scope
  )) then raise exception 'invalid_study_scope'; end if;
  return query
  select ms.id,
    case when sp.id is not null and sp.learning_step < 5 then 1
         when a.sentence_id is not null and sp.id is null then 2
         when sp.id is null then 3 else 4 end,
    jsonb_build_object('sentence_id',ms.id,'memory_id',m.id,'target_text',ms.target_text,
      'translation_text',ms.translation_text,'learning_material',ms.learning_material,
      'target_language',m.target_language,'translation_language',m.translation_language,
      'teaching_locale',m.teaching_locale,'image_path',m.image_url,'memory_created_at',m.created_at,
      'learning_step',coalesce(sp.learning_step,0),'mastered_review_count',coalesce(sp.mastered_review_count,0),
      'correct_count',coalesce(sp.correct_count,0),'wrong_count',coalesce(sp.wrong_count,0),
      'last_result',sp.last_result,'next_review_at',sp.next_review_at),
    a.sentence_id is not null
  from public.memory_sentences ms join public.memories m on m.id = ms.memory_id
  left join public.sentence_study_progress sp on sp.sentence_id = ms.id and sp.user_id = auth.uid() and sp.study_scope = p_scope
  left join public.sentence_study_activations a on a.sentence_id = ms.id and a.user_id = auth.uid()
  where m.user_id = auth.uid() and m.target_language = p_language
    and (not p_legacy or (m.target_language = 'en' and m.translation_language = 'zh-Hans' and m.teaching_locale = 'en-US'))
    and ((p_scope = 'favorites' and ms.is_favorite) or exists (
      select 1 from public.study_scene_sentences link join public.study_scenes scene on scene.id = link.scene_id
      where link.sentence_id = ms.id and 'scene:' || scene.id::text = p_scope and scene.user_id = auth.uid()
    ))
    and (case when p_mode = 'today' then
      coalesce((sp.last_studied_at at time zone p_zone)::date,sp.last_studied_on) = (now() at time zone p_zone)::date
    else
      (coalesce((sp.last_studied_at at time zone p_zone)::date,sp.last_studied_on) is null
       or coalesce((sp.last_studied_at at time zone p_zone)::date,sp.last_studied_on) < (now() at time zone p_zone)::date)
      and (sp.id is null or sp.next_review_at is null or (sp.next_review_at at time zone p_zone)::date <= (now() at time zone p_zone)::date)
    end)
  order by 2, sp.next_review_at nulls first, m.created_at desc, ms.sort_order, ms.id;
end;
$$;


--
-- Name: _study_lock_v2(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._study_lock_v2() RETURNS void
    LANGUAGE plpgsql
    SET search_path TO 'public', 'pg_temp'
    AS $$
begin
  if auth.uid() is null then raise exception 'authentication_required'; end if;
  -- One account lock across every language, scope, legacy API and event write.
  perform pg_advisory_xact_lock(hashtextextended('study:' || auth.uid()::text, 0));
end;
$$;


--
-- Name: _study_remaining_v2(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._study_remaining_v2(p_zone text) RETURNS integer
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
  select greatest(0, 30 - count(*)::integer)
  from public.sentence_study_activations
  where user_id = auth.uid() and source <> 'baseline'
    and first_activated_at >= ((now() at time zone p_zone)::date::timestamp at time zone p_zone)
    and first_activated_at < (((now() at time zone p_zone)::date + 1)::timestamp at time zone p_zone);
$$;


--
-- Name: _study_zone_v2(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._study_zone_v2(p_zone text) RETURNS text
    LANGUAGE plpgsql STABLE
    SET search_path TO 'public', 'pg_temp'
    AS $$
begin
  if p_zone is null then return public.sentence_study_time_zone(); end if;
  if char_length(p_zone) > 100 or not exists (select 1 from pg_timezone_names where name = p_zone) then
    raise exception 'invalid_study_time_zone';
  end if;
  return p_zone;
end;
$$;


--
-- Name: authorize_memory_image_cleanup_v2(uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.authorize_memory_image_cleanup_v2(p_job_id uuid, p_lease_id uuid) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    AS $_$
  select exists(select 1 from public.memory_image_cleanup_jobs_v2 j
    where j.id=p_job_id and j.lease_id=p_lease_id and j.lease_until>now() and j.completed_at is null
      and j.bucket_id='memories'
      and j.image_path ~ ('^'||j.user_id::text||'/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}[.]jpg$')
      and not exists(select 1 from public.memories m where m.image_url=j.image_path))
$_$;


--
-- Name: begin_direct_study_session_v2(uuid, uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.begin_direct_study_session_v2(p_session_id uuid, p_sentence_id uuid, p_time_zone text DEFAULT NULL::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare
  v_zone text := public._study_zone_v2(p_time_zone);
  v_session public.study_sessions%rowtype;
  v_language text;
begin
  perform public._study_lock_v2();
  if p_session_id is null or p_sentence_id is null then raise exception 'invalid_study_session'; end if;
  select * into v_session from public.study_sessions where user_id=auth.uid() and session_id=p_session_id;
  if found then
    if v_session.mode <> 'direct' or v_session.sentence_ids is distinct from array[p_sentence_id]
      or v_session.time_zone <> v_zone then raise exception 'study_session_conflict'; end if;
    v_language := v_session.target_language;
  else
    select m.target_language into v_language from public.memory_sentences s
      join public.memories m on m.id=s.memory_id where s.id=p_sentence_id and m.user_id=auth.uid();
    if not found then raise exception 'study_sentence_unavailable'; end if;
    if not exists(select 1 from public.sentence_study_activations where user_id=auth.uid() and sentence_id=p_sentence_id) then
      if public._study_remaining_v2(v_zone)<=0 then raise exception 'study_daily_new_limit'; end if;
      insert into public.sentence_study_activations(user_id,sentence_id,source,session_id)
        values(auth.uid(),p_sentence_id,'session',p_session_id);
    end if;
    insert into public.study_sessions(user_id,session_id,target_language,study_scope,mode,time_zone,requested_limit,sentence_ids)
      values(auth.uid(),p_session_id,v_language,'favorites','direct',v_zone,1,array[p_sentence_id]);
  end if;
  return public._begin_study_session_v2(p_session_id,v_language,'favorites',1,'direct',v_zone,false);
end;
$$;


--
-- Name: begin_study_session_v2(uuid, text, text, integer, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.begin_study_session_v2(p_session_id uuid, p_target_language text, p_scope text DEFAULT 'favorites'::text, p_limit integer DEFAULT 5, p_mode text DEFAULT 'due'::text, p_time_zone text DEFAULT NULL::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
begin
  if p_mode is null or p_mode not in ('due','today') then raise exception 'invalid_study_filter'; end if;
  return public._begin_study_session_v2(p_session_id,p_target_language,p_scope,p_limit,p_mode,p_time_zone,false);
end;
$$;


--
-- Name: claim_generation_job(uuid, uuid, boolean, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.claim_generation_job(p_user_id uuid, p_request_id uuid, p_is_anonymous boolean, p_image_path text DEFAULT NULL::text) RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
declare version integer;
begin
  perform pg_advisory_xact_lock(hashtextextended('generation-request:'||p_request_id::text,0));
  if p_is_anonymous then select request_schema_version into version from public.guest_generation_jobs where id=p_request_id;
  else select request_schema_version into version from public.generation_jobs where client_request_id=p_request_id; end if;
  if coalesce(version,1)<>1 then raise exception 'request_context_mismatch'; end if;
  return public.claim_generation_job_legacy_internal(p_user_id,p_request_id,p_is_anonymous,p_image_path);
end;
$$;


--
-- Name: claim_generation_job_legacy_internal(uuid, uuid, boolean, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.claim_generation_job_legacy_internal(p_user_id uuid, p_request_id uuid, p_is_anonymous boolean, p_image_path text DEFAULT NULL::text) RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare
  inserted_id uuid;
  job_owner uuid;
  job_status text;
begin
  if p_user_id is null or p_request_id is null or p_is_anonymous is null then
    raise exception 'invalid generation claim';
  end if;

  if p_is_anonymous then
    insert into public.guest_generation_jobs(id, user_id, status, image_path)
    values (p_request_id, p_user_id, 'pending', p_image_path)
    on conflict (id) do nothing
    returning id into inserted_id;
    if inserted_id is not null then return 'acquired'; end if;

    select user_id, status into job_owner, job_status
    from public.guest_generation_jobs where id = p_request_id for update;
  else
    insert into public.generation_jobs(client_request_id, user_id, status)
    values (p_request_id, p_user_id, 'pending')
    on conflict (client_request_id) do nothing
    returning id into inserted_id;
    if inserted_id is not null then return 'acquired'; end if;

    select user_id, status into job_owner, job_status
    from public.generation_jobs where client_request_id = p_request_id for update;
  end if;

  if job_owner is distinct from p_user_id then
    raise exception 'generation job not found';
  end if;
  return job_status;
end;
$$;


--
-- Name: claim_generation_job_v3(uuid, uuid, boolean, text, jsonb, text, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.claim_generation_job_v3(p_user_id uuid, p_request_id uuid, p_is_anonymous boolean, p_image_path text, p_generation_spec jsonb, p_request_fingerprint text, p_generation_policy jsonb) RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    AS $_$
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
$_$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: memory_image_cleanup_jobs_v2; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.memory_image_cleanup_jobs_v2 (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    memory_id uuid NOT NULL,
    bucket_id text DEFAULT 'memories'::text NOT NULL,
    image_path text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    attempts integer DEFAULT 0 NOT NULL,
    completed_at timestamp with time zone,
    next_attempt_at timestamp with time zone DEFAULT now() NOT NULL,
    lease_id uuid,
    lease_until timestamp with time zone,
    last_error text,
    CONSTRAINT memory_image_cleanup_jobs_v2_attempts_check CHECK ((attempts >= 0)),
    CONSTRAINT memory_image_cleanup_jobs_v2_bucket_id_check CHECK ((bucket_id = 'memories'::text))
);


--
-- Name: claim_memory_image_cleanup_v2(integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.claim_memory_image_cleanup_v2(p_limit integer DEFAULT 10) RETURNS SETOF public.memory_image_cleanup_jobs_v2
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
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


--
-- Name: claim_sentence_explanation(uuid, text, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.claim_sentence_explanation(p_user_id uuid, p_fingerprint text, p_generate boolean) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare
  cached public.sentence_explanations%rowtype;
  token uuid;
  allowed uuid;
  today date := (now() at time zone 'UTC')::date;
begin
  if p_generate then
    insert into public.sentence_explanations(user_id, fingerprint)
      values (p_user_id, p_fingerprint) on conflict do nothing;
  end if;
  select * into cached from public.sentence_explanations
    where user_id = p_user_id and fingerprint = p_fingerprint for update;
  if cached.content is not null then
    return jsonb_build_object('state', 'ready', 'content', cached.content);
  end if;
  if not p_generate then return jsonb_build_object('state', 'missing'); end if;
  if cached.lease_until > now() then return jsonb_build_object('state', 'busy'); end if;

  insert into public.sentence_explanation_limits as limits
    (user_id, minute_started_at, minute_count, request_day, day_count)
    values (p_user_id, now(), 1, today, 1)
  on conflict (user_id) do update set
    minute_started_at = case when limits.minute_started_at <= now() - interval '1 minute' then now() else limits.minute_started_at end,
    minute_count = case when limits.minute_started_at <= now() - interval '1 minute' then 1 else limits.minute_count + 1 end,
    request_day = today,
    day_count = case when limits.request_day <> today then 1 else limits.day_count + 1 end
  where (limits.minute_started_at <= now() - interval '1 minute' or limits.minute_count < 8)
    and (limits.request_day <> today or limits.day_count < 50)
  returning user_id into allowed;
  if allowed is null then
    delete from public.sentence_explanations
      where user_id = p_user_id and fingerprint = p_fingerprint and content is null;
    return jsonb_build_object('state', 'limited');
  end if;
  token := gen_random_uuid();
  update public.sentence_explanations set claim_id = token, lease_until = now() + interval '90 seconds'
    where user_id = p_user_id and fingerprint = p_fingerprint;
  return jsonb_build_object('state', 'claimed', 'claimID', token);
end;
$$;


--
-- Name: confirm_purchase_atomically(uuid, text, text, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.confirm_purchase_atomically(p_user_id uuid, p_transaction_id text, p_product_id text, p_credits integer) RETURNS TABLE(remaining_credits integer, already_processed boolean)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
    current_balance integer;
begin
    if p_transaction_id is null or btrim(p_transaction_id) = '' then
        raise exception 'transaction id is required';
    end if;

    if p_product_id is null or btrim(p_product_id) = '' then
        raise exception 'product id is required';
    end if;

    if p_credits is null or p_credits <= 0 then
        raise exception 'credits must be positive';
    end if;

    if exists(
        select 1
          from public.purchase_ledger
         where transaction_id = p_transaction_id
    ) then
        select profiles.available_generations
          into current_balance
          from public.profiles
         where profiles.id = p_user_id;

        if not found then
            raise exception 'profile not found';
        end if;

        return query
        select current_balance, true;
        return;
    end if;

    select profiles.available_generations
      into current_balance
      from public.profiles
     where profiles.id = p_user_id
     for update;

    if not found then
        raise exception 'profile not found';
    end if;

    begin
        insert into public.purchase_ledger (
            user_id,
            transaction_id,
            product_id,
            credits
        ) values (
            p_user_id,
            p_transaction_id,
            p_product_id,
            p_credits
        );
    exception
        when unique_violation then
            select profiles.available_generations
              into current_balance
              from public.profiles
             where profiles.id = p_user_id;

            if not found then
                raise exception 'profile not found';
            end if;

            return query
            select current_balance, true;
            return;
    end;

    current_balance := current_balance + p_credits;

    update public.profiles
       set available_generations = current_balance
     where id = p_user_id;

    insert into public.generation_transactions (
        user_id,
        delta,
        balance_after,
        reason,
        note,
        transaction_id
    ) values (
        p_user_id,
        p_credits,
        current_balance,
        'purchase',
        p_product_id,
        p_transaction_id
    );

    return query
    select current_balance, false;
end;
$$;


--
-- Name: consume_speech_request(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.consume_speech_request(p_user_id uuid) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare
  current_minute timestamptz := date_trunc('minute', now());
  current_day_utc date := (now() at time zone 'UTC')::date;
  accepted_user uuid;
begin
  insert into public.speech_request_limits as limits
    (user_id, minute_started_at, minute_count, request_day, day_count)
  values (p_user_id, current_minute, 1, current_day_utc, 1)
  on conflict (user_id) do update set
    minute_started_at = current_minute,
    minute_count = case when limits.minute_started_at = current_minute
      then limits.minute_count + 1 else 1 end,
    request_day = current_day_utc,
    day_count = case when limits.request_day = current_day_utc
      then limits.day_count + 1 else 1 end
  where (limits.minute_started_at <> current_minute or limits.minute_count < 20)
    and (limits.request_day <> current_day_utc or limits.day_count < 300)
  returning user_id into accepted_user;
  return accepted_user is not null;
end;
$$;


--
-- Name: cosine_similarity_real_arrays(real[], real[]); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.cosine_similarity_real_arrays(p_left real[], p_right real[]) RETURNS double precision
    LANGUAGE sql IMMUTABLE STRICT
    SET search_path TO 'public', 'pg_temp'
    AS $$
  with components as (
    select left_value::double precision, right_value::double precision
    from unnest(p_left, p_right) as pairs(left_value, right_value)
  )
  select case
    when cardinality(p_left) <> cardinality(p_right)
      or cardinality(p_left) = 0 then null
    when sqrt(sum(left_value * left_value)) = 0
      or sqrt(sum(right_value * right_value)) = 0 then null
    else sum(left_value * right_value)
      / (sqrt(sum(left_value * left_value)) * sqrt(sum(right_value * right_value)))
  end
  from components;
$$;


--
-- Name: count_mastered_sentences(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.count_mastered_sentences() RETURNS integer
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
  select count(distinct progress.sentence_id)::integer
  from public.sentence_study_progress as progress
  join public.memory_sentences as sentence on sentence.id = progress.sentence_id
  join public.memories as memory on memory.id = sentence.memory_id
  where auth.uid() is not null
    and progress.user_id = auth.uid()
    and memory.user_id = auth.uid()
    and progress.correct_count >= 5;
$$;


--
-- Name: count_sentence_studied_today(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.count_sentence_studied_today() RETURNS integer
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
  select count(*)::integer from public.sentence_study_progress sp
  join (select legacy_sentence.* from public.memory_sentences legacy_sentence join public.memories legacy_memory
        on legacy_memory.id=legacy_sentence.memory_id where legacy_memory.target_language='en'
        and legacy_memory.translation_language='zh-Hans' and legacy_memory.teaching_locale='en-US') ms on ms.id=sp.sentence_id
  join public.memories m on m.id=ms.memory_id
  where sp.user_id=auth.uid() and m.user_id=auth.uid() and m.target_language='en'
    and m.translation_language='zh-Hans' and m.teaching_locale='en-US'
    and coalesce((sp.last_studied_at at time zone public.sentence_study_time_zone())::date,sp.last_studied_on)
      = (now() at time zone public.sentence_study_time_zone())::date;
$$;


--
-- Name: count_sentence_studied_today_reviewable(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.count_sentence_studied_today_reviewable() RETURNS integer
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
  select count(*)::integer
  from public.sentence_study_progress sp
  join (select legacy_sentence.* from public.memory_sentences legacy_sentence join public.memories legacy_memory
        on legacy_memory.id=legacy_sentence.memory_id where legacy_memory.target_language='en'
        and legacy_memory.translation_language='zh-Hans' and legacy_memory.teaching_locale='en-US') ms on ms.id = sp.sentence_id
  join public.memories m on m.id = ms.memory_id
  where auth.uid() is not null
    and sp.user_id = auth.uid()
    and sp.study_scope = 'favorites'
    and m.user_id = auth.uid()
    and ms.is_favorite = true
    and coalesce((sp.last_studied_at at time zone (select public.sentence_study_time_zone()))::date, sp.last_studied_on) = (now() at time zone (select public.sentence_study_time_zone()))::date;
$$;


--
-- Name: count_sentence_study_queue(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.count_sentence_study_queue() RETURNS integer
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
  select (count(*) filter(where activated))::integer + least((count(*) filter(where not activated))::integer,
    public._study_remaining_v2(public.sentence_study_time_zone()))
  from public._study_candidates_v2('en','favorites','due',public.sentence_study_time_zone(),true);
$$;


--
-- Name: delete_memory_v2(uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.delete_memory_v2(p_memory_id uuid, p_operation_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
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


--
-- Name: finalize_authenticated_generation(uuid, uuid, text, timestamp with time zone, text, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.finalize_authenticated_generation(p_user_id uuid, p_memory_id uuid, p_image_path text, p_created_at timestamp with time zone, p_provider text, p_sentences jsonb) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
    current_balance integer := 0;
    remaining_balance integer := 0;
    sentence_item record;
begin
    if p_sentences is null
       or jsonb_typeof(p_sentences) <> 'array'
       or jsonb_array_length(p_sentences) <> 3 then
        raise exception 'invalid sentences';
    end if;

    select profiles.available_generations
      into current_balance
      from public.profiles
     where profiles.id = p_user_id
     for update;

    if not found then
        raise exception 'profile not found';
    end if;

    if exists (
        select 1
          from public.memories
         where memories.id = p_memory_id
           and memories.user_id = p_user_id
    ) then
        return current_balance;
    end if;

    if coalesce(current_balance, 0) <= 0 then
        raise exception 'No credits left';
    end if;

    remaining_balance := current_balance - 1;

    insert into public.memories (
        id,
        user_id,
        image_url,
        created_at,
        provider
    )
    values (
        p_memory_id,
        p_user_id,
        p_image_path,
        coalesce(p_created_at, timezone('utc', now())),
        p_provider
    );

    for sentence_item in
        select value, ordinality
          from jsonb_array_elements(p_sentences) with ordinality
    loop
        insert into public.memory_sentences (
            id,
            memory_id,
            sort_order,
            english,
            chinese,
            is_favorite
        )
        values (
            case
                when nullif(sentence_item.value ->> 'id', '') is null then gen_random_uuid()
                else (sentence_item.value ->> 'id')::uuid
            end,
            p_memory_id,
            sentence_item.ordinality,
            trim(sentence_item.value ->> 'english'),
            trim(sentence_item.value ->> 'chinese'),
            coalesce((sentence_item.value ->> 'is_favorite')::boolean, false)
        );
    end loop;

    update public.profiles
       set available_generations = remaining_balance
     where profiles.id = p_user_id;

    if to_regclass('public.generation_transactions') is not null then
        insert into public.generation_transactions (
            user_id,
            delta,
            balance_after,
            reason,
            note
        )
        values (
            p_user_id,
            -1,
            remaining_balance,
            'generate',
            'memory_id:' || p_memory_id::text
        );
    end if;

    return remaining_balance;
end;
$$;


--
-- Name: finalize_authenticated_generation(uuid, uuid, uuid, text, timestamp with time zone, text, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.finalize_authenticated_generation(p_user_id uuid, p_memory_id uuid, p_client_request_id uuid, p_image_path text, p_created_at timestamp with time zone, p_provider text, p_sentences jsonb) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
    remaining_balance integer := 0;
    generation_job record;
begin
    if p_client_request_id is null then
        return public.finalize_authenticated_generation(
            p_user_id,
            p_memory_id,
            p_image_path,
            p_created_at,
            p_provider,
            p_sentences
        );
    end if;

    insert into public.generation_jobs (
        client_request_id,
        user_id,
        status,
        updated_at
    )
    values (
        p_client_request_id,
        p_user_id,
        'pending',
        timezone('utc', now())
    )
    on conflict (client_request_id) do nothing;

    select *
      into generation_job
      from public.generation_jobs
     where generation_jobs.client_request_id = p_client_request_id
       and generation_jobs.user_id = p_user_id
     for update;

    if not found then
        raise exception 'generation job not found';
    end if;

    if generation_job.status = 'completed' then
        return coalesce(
            generation_job.remaining_credits,
            (
                select profiles.available_generations
                  from public.profiles
                 where profiles.id = p_user_id
            )
        );
    end if;

    if generation_job.status = 'failed' then
        raise exception 'generation job already failed';
    end if;

    remaining_balance := public.finalize_authenticated_generation(
        p_user_id,
        p_memory_id,
        p_image_path,
        p_created_at,
        p_provider,
        p_sentences
    );

    update public.generation_jobs
       set status = 'completed',
           memory_id = p_memory_id,
           image_path = p_image_path,
           provider = p_provider,
           remaining_credits = remaining_balance,
           error_message = null,
           updated_at = timezone('utc', now()),
           completed_at = coalesce(generation_jobs.completed_at, timezone('utc', now())),
           failed_at = null
     where generation_jobs.client_request_id = p_client_request_id
       and generation_jobs.user_id = p_user_id;

    return remaining_balance;
end;
$$;


--
-- Name: finalize_authenticated_generation(uuid, uuid, uuid, text, timestamp with time zone, text, jsonb, text[]); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.finalize_authenticated_generation(p_user_id uuid, p_memory_id uuid, p_client_request_id uuid, p_image_path text, p_created_at timestamp with time zone, p_provider text, p_sentences jsonb, p_tags text[]) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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


--
-- Name: finalize_generation_job_v3(uuid, uuid, boolean, text, jsonb, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.finalize_generation_job_v3(p_user_id uuid, p_request_id uuid, p_is_anonymous boolean, p_request_fingerprint text, p_memory jsonb, p_provider text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
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


--
-- Name: finalize_guest_generation(uuid, uuid, timestamp with time zone, text, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.finalize_guest_generation(p_user_id uuid, p_guest_job_id uuid, p_completed_at timestamp with time zone, p_provider text, p_sentences jsonb) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
    current_balance integer := 0;
    remaining_balance integer := 0;
    guest_job record;
begin
    if p_sentences is null
       or jsonb_typeof(p_sentences) <> 'array'
       or jsonb_array_length(p_sentences) <> 3 then
        raise exception 'invalid sentences';
    end if;

    select *
      into guest_job
      from public.guest_generation_jobs
     where guest_generation_jobs.id = p_guest_job_id
       and guest_generation_jobs.user_id = p_user_id
     for update;

    if not found then
        raise exception 'guest generation job not found';
    end if;

    if guest_job.status in ('completed', 'acknowledged') then
        return coalesce(
            guest_job.remaining_credits,
            (
                select profiles.available_generations
                  from public.profiles
                 where profiles.id = p_user_id
            )
        );
    end if;

    if guest_job.status = 'failed' then
        raise exception 'guest generation job already failed';
    end if;

    select profiles.available_generations
      into current_balance
      from public.profiles
     where profiles.id = p_user_id
     for update;

    if not found then
        raise exception 'profile not found';
    end if;

    if coalesce(current_balance, 0) <= 0 then
        raise exception 'No credits left';
    end if;

    remaining_balance := current_balance - 1;

    update public.profiles
       set available_generations = remaining_balance
     where profiles.id = p_user_id;

    update public.guest_generation_jobs
       set status = 'completed',
           completed_at = coalesce(p_completed_at, timezone('utc', now())),
           provider = p_provider,
           sentences = p_sentences,
           remaining_credits = remaining_balance,
           error_message = null
     where guest_generation_jobs.id = p_guest_job_id
       and guest_generation_jobs.user_id = p_user_id;

    if to_regclass('public.generation_transactions') is not null then
        insert into public.generation_transactions (
            user_id,
            delta,
            balance_after,
            reason,
            note
        )
        values (
            p_user_id,
            -1,
            remaining_balance,
            'generate',
            'guest_job_id:' || p_guest_job_id::text
        );
    end if;

    return remaining_balance;
end;
$$;


--
-- Name: finalize_guest_generation(uuid, uuid, timestamp with time zone, text, jsonb, text[]); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.finalize_guest_generation(p_user_id uuid, p_guest_job_id uuid, p_completed_at timestamp with time zone, p_provider text, p_sentences jsonb, p_tags text[]) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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


--
-- Name: finalize_guest_generation(uuid, uuid, uuid, timestamp with time zone, text, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.finalize_guest_generation(p_user_id uuid, p_guest_job_id uuid, p_client_request_id uuid, p_completed_at timestamp with time zone, p_provider text, p_sentences jsonb) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
begin
    return public.finalize_guest_generation(
        p_user_id,
        p_guest_job_id,
        p_completed_at,
        p_provider,
        p_sentences
    );
end;
$$;


--
-- Name: finish_memory_image_cleanup_v2(uuid, uuid, boolean, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.finish_memory_image_cleanup_v2(p_job_id uuid, p_lease_id uuid, p_success boolean, p_error text DEFAULT NULL::text) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
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


--
-- Name: finish_sentence_explanation(uuid, text, uuid, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.finish_sentence_explanation(p_user_id uuid, p_fingerprint text, p_claim_id uuid, p_content jsonb) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare completed uuid;
begin
  if p_content is null or jsonb_typeof(p_content) <> 'object'
    or coalesce(p_content->>'version', '') not in ('1', '2') then
    raise exception 'Invalid explanation';
  end if;
  update public.sentence_explanations set content = p_content, claim_id = null, lease_until = null
    where user_id = p_user_id and fingerprint = p_fingerprint and claim_id = p_claim_id
      and content is null and lease_until > now()
    returning user_id into completed;
  return completed is not null;
end;
$$;


--
-- Name: finish_sentence_explanation_v2(uuid, text, uuid, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.finish_sentence_explanation_v2(p_user_id uuid, p_fingerprint text, p_claim_id uuid, p_content jsonb) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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


--
-- Name: album_flip_progress; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.album_flip_progress (
    user_id uuid NOT NULL,
    sentence_id uuid NOT NULL,
    memory_id uuid NOT NULL,
    last_event_id uuid NOT NULL,
    last_feedback text NOT NULL,
    last_feedback_at timestamp with time zone NOT NULL,
    familiarity_level integer NOT NULL,
    last_familiar_at timestamp with time zone,
    CONSTRAINT album_flip_progress_familiarity_level_check CHECK (((familiarity_level >= 0) AND (familiarity_level <= 4))),
    CONSTRAINT album_flip_progress_last_feedback_check CHECK ((last_feedback = ANY (ARRAY['again'::text, 'familiar'::text])))
);


--
-- Name: TABLE album_flip_progress; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.album_flip_progress IS 'Latest per-sentence album browsing feedback. Does not change study counts, mastery, favorites or credits.';


--
-- Name: get_album_flip_progress_v2(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_album_flip_progress_v2(p_target_language text DEFAULT NULL::text) RETURNS SETOF public.album_flip_progress
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
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


--
-- Name: get_language_capabilities_v1(integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_language_capabilities_v1(p_catalog_version integer DEFAULT 1) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
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


--
-- Name: get_learning_preferences_v1(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_learning_preferences_v1() RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
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


--
-- Name: get_memory_v2(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_memory_v2(p_memory_id uuid) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
declare v_user uuid := public.require_content_user_v1();
begin
  if not exists (select 1 from public.memories where id=p_memory_id and user_id=v_user) then return null; end if;
  return public.memory_content_dto_v2(p_memory_id);
end;
$$;


--
-- Name: get_sentence_studied_today_queue(integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_sentence_studied_today_queue(p_limit integer DEFAULT 30) RETURNS TABLE(sentence_id uuid, memory_id uuid, english text, chinese text, image_path text, memory_created_at timestamp with time zone, learning_step integer, mastered_review_count integer, correct_count integer, wrong_count integer, last_result text, next_review_at timestamp with time zone)
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
  select
    ms.id, ms.memory_id, ms.english, ms.chinese, m.image_url, m.created_at,
    coalesce(sp.learning_step, 0), coalesce(sp.mastered_review_count, 0),
    coalesce(sp.correct_count, 0), coalesce(sp.wrong_count, 0),
    sp.last_result, sp.next_review_at
  from public.sentence_study_progress sp
  join (select legacy_sentence.* from public.memory_sentences legacy_sentence join public.memories legacy_memory
        on legacy_memory.id=legacy_sentence.memory_id where legacy_memory.target_language='en'
        and legacy_memory.translation_language='zh-Hans' and legacy_memory.teaching_locale='en-US') ms on ms.id = sp.sentence_id
  join public.memories m on m.id = ms.memory_id
  where auth.uid() is not null
    and sp.user_id = auth.uid()
    and sp.study_scope = 'favorites'
    and m.user_id = auth.uid()
    and ms.is_favorite = true
    and coalesce((sp.last_studied_at at time zone (select public.sentence_study_time_zone()))::date, sp.last_studied_on) = (now() at time zone (select public.sentence_study_time_zone()))::date
  order by sp.last_studied_at asc nulls last, m.created_at desc
  limit least(greatest(coalesce(p_limit, 30), 1), 1000);
$$;


--
-- Name: sentence_study_progress; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.sentence_study_progress (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    sentence_id uuid NOT NULL,
    learning_step integer DEFAULT 0 NOT NULL,
    mastered_review_count integer DEFAULT 0 NOT NULL,
    correct_count integer DEFAULT 0 NOT NULL,
    wrong_count integer DEFAULT 0 NOT NULL,
    last_result text,
    last_studied_at timestamp with time zone,
    last_studied_on date,
    next_review_at timestamp with time zone DEFAULT timezone('utc'::text, now()) NOT NULL,
    created_at timestamp with time zone DEFAULT timezone('utc'::text, now()) NOT NULL,
    updated_at timestamp with time zone DEFAULT timezone('utc'::text, now()) NOT NULL,
    study_scope text DEFAULT 'favorites'::text NOT NULL,
    CONSTRAINT sentence_study_progress_correct_count_check CHECK ((correct_count >= 0)),
    CONSTRAINT sentence_study_progress_last_result_check CHECK ((last_result = ANY (ARRAY['correct'::text, 'incorrect'::text]))),
    CONSTRAINT sentence_study_progress_learning_step_check CHECK (((learning_step >= 0) AND (learning_step <= 5))),
    CONSTRAINT sentence_study_progress_mastered_review_count_check CHECK ((mastered_review_count >= 0)),
    CONSTRAINT sentence_study_progress_study_scope_check CHECK (((char_length(btrim(study_scope)) >= 2) AND (char_length(btrim(study_scope)) <= 64))),
    CONSTRAINT sentence_study_progress_wrong_count_check CHECK ((wrong_count >= 0))
);


--
-- Name: get_sentence_study_progress_v2(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_sentence_study_progress_v2(p_target_language text DEFAULT NULL::text) RETURNS SETOF public.sentence_study_progress
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
begin
  if auth.uid() is null then raise exception 'authentication_required'; end if;
  if p_target_language is not null and p_target_language not in ('en','es','ja','fr') then
    raise exception 'invalid_study_filter';
  end if;
  return query select sp.* from public.sentence_study_progress sp
    join public.memory_sentences s on s.id=sp.sentence_id
    join public.memories m on m.id=s.memory_id
    where sp.user_id=auth.uid() and m.user_id=auth.uid()
      and (p_target_language is null or m.target_language=p_target_language)
    order by sp.sentence_id,sp.study_scope;
end;
$$;


--
-- Name: get_sentence_study_queue(integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_sentence_study_queue(p_limit integer DEFAULT 5) RETURNS TABLE(sentence_id uuid, memory_id uuid, english text, chinese text, image_path text, memory_created_at timestamp with time zone, learning_step integer, mastered_review_count integer, correct_count integer, wrong_count integer, last_result text, next_review_at timestamp with time zone)
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
  select (i->>'sentence_id')::uuid,(i->>'memory_id')::uuid,i->>'target_text',i->>'translation_text',i->>'image_path',
    (i->>'memory_created_at')::timestamptz,(i->>'learning_step')::integer,(i->>'mastered_review_count')::integer,
    (i->>'correct_count')::integer,(i->>'wrong_count')::integer,i->>'last_result',(i->>'next_review_at')::timestamptz
  from jsonb_array_elements(public._begin_study_session_v2(gen_random_uuid(),'en','favorites',
    least(greatest(coalesce(p_limit,5),1),1000),'due',null,true)->'items') i;
$$;


--
-- Name: get_studied_today_scene_queue(uuid, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_studied_today_scene_queue(p_scene_id uuid, p_limit integer DEFAULT 1000) RETURNS TABLE(sentence_id uuid, memory_id uuid, english text, chinese text, image_path text, memory_created_at timestamp with time zone, learning_step integer, mastered_review_count integer, correct_count integer, wrong_count integer, last_result text, next_review_at timestamp with time zone)
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
  select
    ms.id, ms.memory_id, ms.english, ms.chinese, m.image_url, m.created_at,
    coalesce(sp.learning_step, 0), coalesce(sp.mastered_review_count, 0),
    coalesce(sp.correct_count, 0), coalesce(sp.wrong_count, 0),
    sp.last_result, sp.next_review_at
  from public.study_scenes scene
  join public.study_scene_sentences link on link.scene_id = scene.id
  join (select legacy_sentence.* from public.memory_sentences legacy_sentence join public.memories legacy_memory
        on legacy_memory.id=legacy_sentence.memory_id where legacy_memory.target_language='en'
        and legacy_memory.translation_language='zh-Hans' and legacy_memory.teaching_locale='en-US') ms on ms.id = link.sentence_id
  join public.memories m on m.id = ms.memory_id
  join public.sentence_study_progress sp
    on sp.sentence_id = ms.id
   and sp.user_id = auth.uid()
   and sp.study_scope = 'scene:' || scene.id::text
  where scene.id = p_scene_id
    and scene.user_id = auth.uid()
    and m.user_id = auth.uid()
    and coalesce((sp.last_studied_at at time zone (select public.sentence_study_time_zone()))::date, sp.last_studied_on) = (now() at time zone (select public.sentence_study_time_zone()))::date
  order by sp.last_studied_at asc nulls last, m.created_at desc
  limit least(greatest(coalesce(p_limit, 1000), 1), 1000);
$$;


--
-- Name: get_study_overview_v2(text, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_study_overview_v2(p_target_language text, p_scope text DEFAULT 'favorites'::text, p_time_zone text DEFAULT NULL::text) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare v_zone text := public._study_zone_v2(p_time_zone); v_due integer; v_new integer; v_today integer; v_remaining integer;
begin
  v_remaining := public._study_remaining_v2(v_zone);
  select count(*) filter(where activated),count(*) filter(where not activated) into v_due,v_new
    from public._study_candidates_v2(p_target_language,p_scope,'due',v_zone);
  select count(*) into v_today from public._study_candidates_v2(p_target_language,p_scope,'today',v_zone);
  return jsonb_build_object('due_count',v_due + least(v_new,v_remaining),'review_count',v_due,
    'new_count',least(v_new,v_remaining),'studied_today_count',v_today,'remaining_new',v_remaining);
end;
$$;


--
-- Name: get_study_topic_expressions(text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_study_topic_expressions(p_topic_key text, p_source_fingerprint text) RETURNS TABLE(id uuid, kind text, english text, chinese text, part_of_speech text, occurrence_count integer, examples jsonb)
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
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
  left join (select legacy_sentence.* from public.memory_sentences legacy_sentence join public.memories legacy_memory
        on legacy_memory.id=legacy_sentence.memory_id where legacy_memory.target_language='en'
        and legacy_memory.translation_language='zh-Hans' and legacy_memory.teaching_locale='en-US') sentence
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
  having count(sentence.id)>0 and count(*) filter(where example.sentence_id is not null and sentence.id is null)=0 order by expression.kind, expression.sort_order, expression.english;
$$;


--
-- Name: get_study_topic_source_sentences(text, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_study_topic_source_sentences(p_topic_key text, p_limit integer DEFAULT 120) RETURNS TABLE(id uuid, english text, chinese text)
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $_$
  select sentence.id, sentence.english, sentence.chinese
  from (select legacy_sentence.* from public.memory_sentences legacy_sentence join public.memories legacy_memory
        on legacy_memory.id=legacy_sentence.memory_id where legacy_memory.target_language='en'
        and legacy_memory.translation_language='zh-Hans' and legacy_memory.teaching_locale='en-US') sentence
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
$_$;


--
-- Name: guard_memory_image_lifecycle_v2(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.guard_memory_image_lifecycle_v2() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
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


--
-- Name: immutable_memory_identity_v1(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.immutable_memory_identity_v1(p_memory jsonb) RETURNS jsonb
    LANGUAGE sql IMMUTABLE
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
  select jsonb_build_object('id',p_memory->'id','context',p_memory->'context','createdAt',
    to_jsonb((p_memory->>'createdAt')::timestamptz),'sentences',(select jsonb_agg(jsonb_build_object(
      'id',s->'id','targetText',s->'targetText','translationText',s->'translationText','contentVersion',s->'contentVersion',
      'presentationGroup',s->'presentationGroup') ||
      case when nullif(s->'dialogue','null'::jsonb) is null then '{}'::jsonb
        else jsonb_build_object('dialogue',s->'dialogue') end order by s->>'id') from jsonb_array_elements(p_memory->'sentences') s))
$$;


--
-- Name: import_guest_memory_v1(uuid, uuid, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.import_guest_memory_v1(p_user_id uuid, p_guest_user_id uuid, p_memory jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
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


--
-- Name: insert_memory_content_v2(uuid, jsonb, jsonb, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.insert_memory_content_v2(p_user_id uuid, p_memory jsonb, p_spec jsonb DEFAULT NULL::jsonb, p_provider text DEFAULT NULL::text) RETURNS void
    LANGUAGE plpgsql
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
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


--
-- Name: is_legacy_content_v1(text, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.is_legacy_content_v1(p_target text, p_translation text, p_locale text) RETURNS boolean
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    AS $$ select coalesce(p_target = 'en' and p_translation = 'zh-Hans' and p_locale = 'en-US', false) $$;


--
-- Name: jsonb_to_embedding_real_array(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.jsonb_to_embedding_real_array(p_embedding jsonb) RETURNS real[]
    LANGUAGE sql IMMUTABLE STRICT
    SET search_path TO 'public', 'pg_temp'
    AS $$
  select array_agg(value::real order by ordinality)
  from jsonb_array_elements_text(p_embedding) with ordinality as items(value, ordinality);
$$;


--
-- Name: legacy_level_to_id_v1(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.legacy_level_to_id_v1(p_level text) RETURNS text
    LANGUAGE sql IMMUTABLE
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    AS $$ select case p_level when U&'\542F\8499' then 'starter' when U&'\7B80\5355' then 'beginner'
  when U&'\4E2D\7B49' then 'intermediate' when U&'\9AD8\7EA7' then 'advanced' end $$;


--
-- Name: legacy_storage_mutation_allowed_v1(text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.legacy_storage_mutation_allowed_v1(p_bucket text, p_name text) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
  select p_bucket <> 'memories' or (
    not exists(select 1 from public.memory_image_cleanup_jobs_v2 where image_path=p_name)
    and not exists(select 1 from public.memories m where m.image_url=p_name
      and not public.is_legacy_content_v1(m.target_language,m.translation_language,m.teaching_locale))
  )
$$;


--
-- Name: legacy_topic_cache_allowed_v1(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.legacy_topic_cache_allowed_v1(p_topic_key text) RETURNS boolean
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
begin
  return auth.uid() is not null and not exists (
    select 1 from public.study_topic_expressions e where e.user_id=auth.uid() and e.topic_key=p_topic_key
      and not public.legacy_topic_expression_allowed_v1(e.id)
  );
end;
$$;


--
-- Name: legacy_topic_expression_allowed_v1(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.legacy_topic_expression_allowed_v1(p_expression_id uuid) RETURNS boolean
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
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


--
-- Name: level_id_to_legacy_v1(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.level_id_to_legacy_v1(p_level text) RETURNS text
    LANGUAGE sql IMMUTABLE
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    AS $$ select case p_level when 'starter' then U&'\542F\8499' when 'beginner' then U&'\7B80\5355'
  when 'intermediate' then U&'\4E2D\7B49' when 'advanced' then U&'\9AD8\7EA7' end $$;


--
-- Name: list_memories_v2(text, timestamp with time zone, uuid, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.list_memories_v2(p_target_language text DEFAULT NULL::text, p_cursor_created_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_cursor_id uuid DEFAULT NULL::uuid, p_limit integer DEFAULT 50) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
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


--
-- Name: memory_content_dto_v2(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.memory_content_dto_v2(p_memory_id uuid) RETURNS jsonb
    LANGUAGE sql STABLE
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
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


--
-- Name: merge_local_sentence_study_progress(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.merge_local_sentence_study_progress(p_items jsonb) RETURNS TABLE(sentence_id uuid, study_scope text)
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
  select * from public._merge_study_progress_v2(p_items,true);
$$;


--
-- Name: merge_local_sentence_study_progress_v2(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.merge_local_sentence_study_progress_v2(p_items jsonb) RETURNS TABLE(sentence_id uuid, study_scope text)
    LANGUAGE sql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
  select * from public._merge_study_progress_v2(p_items,false);
$$;


--
-- Name: normalize_memory_photo_categories(text[]); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.normalize_memory_photo_categories(p_tags text[]) RETURNS text[]
    LANGUAGE sql IMMUTABLE
    SET search_path TO 'public', 'pg_temp'
    AS $$
  select public.normalize_scene_category_ids(p_tags, 3);
$$;


--
-- Name: normalize_scene_category_ids(text[], integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.normalize_scene_category_ids(p_ids text[], p_limit integer) RETURNS text[]
    LANGUAGE sql IMMUTABLE
    SET search_path TO 'public', 'pg_temp'
    AS $$
  select array(
    select category_id from (
      select btrim(category_id) as category_id, min(position) as position
      from unnest(coalesce(p_ids, '{}'::text[])) with ordinality as input(category_id, position)
      where btrim(category_id) = any(public.scene_category_ids())
      group by btrim(category_id)
    ) unique_categories order by position limit least(3, greatest(0, coalesce(p_limit, 0)))
  );
$$;


--
-- Name: project_sentence_content_v2(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.project_sentence_content_v2() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
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


--
-- Name: protect_dialogue_collection_v1(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.protect_dialogue_collection_v1() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
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


--
-- Name: protect_generation_context_v3(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.protect_generation_context_v3() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
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


--
-- Name: protect_generation_job_result(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.protect_generation_job_result() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public', 'pg_temp'
    AS $$
begin
  if new.user_id is distinct from old.user_id or new.id is distinct from old.id then
    raise exception 'generation job identity is immutable';
  end if;
  if tg_table_name = 'generation_jobs' then
    if new.client_request_id is distinct from old.client_request_id then
      raise exception 'generation job identity is immutable';
    end if;
  end if;

  if old.status in ('completed', 'acknowledged', 'failed') then
    if new.status is distinct from old.status and not (
      tg_table_name = 'guest_generation_jobs' and old.status = 'completed' and new.status = 'acknowledged'
    ) then
      raise exception 'generation job terminal state is immutable';
    end if;

    if old.status in ('completed', 'acknowledged') then
      if new.image_path is distinct from old.image_path
         or new.remaining_credits is distinct from old.remaining_credits
         or new.provider is distinct from old.provider then
        raise exception 'generation job result is immutable';
      end if;
      if tg_table_name = 'generation_jobs' then
        if new.memory_id is distinct from old.memory_id and (
          new.memory_id is not null or exists(select 1 from public.memories where id = old.memory_id)
        ) then
          raise exception 'generation job result is immutable';
        end if;
      elsif new.sentences is distinct from old.sentences or new.tags is distinct from old.tags then
        raise exception 'generation job result is immutable';
      end if;
    end if;
  end if;
  return new;
end;
$$;


--
-- Name: protect_memory_content_v2(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.protect_memory_content_v2() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
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


--
-- Name: protect_profile_balance_fields(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.protect_profile_balance_fields() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'auth', 'pg_temp'
    AS $$
declare
  requester_role text := auth.role();
  is_anonymous boolean := coalesce(nullif(auth.jwt() ->> 'is_anonymous', '')::boolean, false);
  starter_credit_cap integer := 10;
begin
  -- Service-role Edge Functions and direct SQL maintenance remain trusted writers.
  if requester_role is null or requester_role = 'service_role' then
    return new;
  end if;

  if tg_op = 'INSERT' then
    new.credits_merged_into_user_id := null;
    new.credits_merged_at := null;

    if is_anonymous then
      -- Anonymous profiles may receive the local starter/free balance so it can
      -- later be migrated to a signed-in account, but never more than the app's
      -- current starter grant.
      new.available_generations := least(
        greatest(coalesce(new.available_generations, starter_credit_cap), 0),
        starter_credit_cap
      );
    else
      -- Registered accounts should receive credits through purchase or guest
      -- migration flows, not by direct profile insert.
      new.available_generations := 0;
    end if;
  elsif tg_op = 'UPDATE' then
    if is_anonymous then
      -- Let the client lower an anonymous balance to match locally consumed
      -- starter credits, but never increase it. Paid credits and generated
      -- credits are handled by service-role Edge Functions.
      new.available_generations := least(
        greatest(coalesce(new.available_generations, old.available_generations), 0),
        old.available_generations
      );
    else
      new.available_generations := old.available_generations;
    end if;

    new.credits_merged_into_user_id := old.credits_merged_into_user_id;
    new.credits_merged_at := old.credits_merged_at;
  end if;

  return new;
end;
$$;


--
-- Name: record_generation_violation(uuid, integer, integer, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.record_generation_violation(p_user_id uuid, p_window_seconds integer DEFAULT 86400, p_limit integer DEFAULT 3, p_ban_seconds integer DEFAULT 86400) RETURNS TABLE(violation_count integer, banned_until timestamp with time zone)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
declare
  v_now timestamptz := now();
  v_window_seconds integer := greatest(coalesce(p_window_seconds, 86400), 1);
  v_limit integer := greatest(coalesce(p_limit, 3), 1);
  v_ban_seconds integer := greatest(coalesce(p_ban_seconds, 86400), 1);
begin
  return query
  with locked_profile as (
    select
      profiles.id,
      profiles.generation_violation_window_started_at as old_window_started_at,
      profiles.generation_violation_count as old_violation_count
    from public.profiles
    where profiles.id = p_user_id
    for update
  ),
  computed as (
    select
      locked_profile.id,
      case
        when locked_profile.old_window_started_at is null
          or locked_profile.old_window_started_at < v_now - make_interval(secs => v_window_seconds)
        then v_now
        else locked_profile.old_window_started_at
      end as new_window_started_at,
      case
        when locked_profile.old_window_started_at is null
          or locked_profile.old_window_started_at < v_now - make_interval(secs => v_window_seconds)
        then 1
        else coalesce(locked_profile.old_violation_count, 0) + 1
      end as new_violation_count
    from locked_profile
  ),
  updated as (
    update public.profiles
       set generation_violation_window_started_at = computed.new_window_started_at,
           generation_violation_count = computed.new_violation_count,
           last_generation_violation_at = v_now,
           generation_banned_until = case
             when computed.new_violation_count >= v_limit then greatest(
               coalesce(public.profiles.generation_banned_until, '-infinity'::timestamptz),
               v_now + make_interval(secs => v_ban_seconds)
             )
             else public.profiles.generation_banned_until
           end
      from computed
     where public.profiles.id = computed.id
     returning
       public.profiles.generation_violation_count,
       public.profiles.generation_banned_until
  )
  select
    updated.generation_violation_count,
    updated.generation_banned_until
  from updated;
end;
$$;


--
-- Name: record_sentence_study_result(uuid, boolean, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.record_sentence_study_result(p_sentence_id uuid, p_was_correct boolean, p_scope text DEFAULT 'favorites'::text) RETURNS public.sentence_study_progress
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare v_id uuid := gen_random_uuid(); v_zone text := public.sentence_study_time_zone(); v_result jsonb;
begin
  perform public._study_lock_v2();
  if not exists(select 1 from public.memory_sentences s join public.memories m on m.id = s.memory_id
    where s.id = p_sentence_id and m.user_id = auth.uid() and m.target_language = 'en'
      and m.translation_language = 'zh-Hans' and m.teaching_locale = 'en-US'
      and ((p_scope = 'favorites' and s.is_favorite) or exists (
        select 1 from public.study_scene_sentences link join public.study_scenes scene on scene.id = link.scene_id
        where link.sentence_id = s.id and scene.user_id = auth.uid() and 'scene:' || scene.id::text = p_scope)))
    then raise exception 'Sentence not available for study'; end if;
  if not exists(select 1 from public.sentence_study_activations where user_id = auth.uid() and sentence_id = p_sentence_id) then
    if public._study_remaining_v2(v_zone) = 0 then raise exception 'study_daily_new_limit'; end if;
    insert into public.sentence_study_activations(user_id,sentence_id,source,session_id) values(auth.uid(),p_sentence_id,'legacy',v_id);
  end if;
  insert into public.study_sessions(user_id,session_id,target_language,study_scope,mode,time_zone,requested_limit,legacy_only,sentence_ids)
  values(auth.uid(),v_id,'en',p_scope,'due',v_zone,1,true,array[p_sentence_id]);
  v_result := public.record_study_event_v2(v_id,v_id,p_sentence_id,p_was_correct,now(),v_zone);
  return jsonb_populate_record(null::public.sentence_study_progress,v_result);
end;
$$;


--
-- Name: record_study_event_v2(uuid, uuid, uuid, boolean, timestamp with time zone, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.record_study_event_v2(p_event_id uuid, p_session_id uuid, p_sentence_id uuid, p_was_correct boolean, p_occurred_at timestamp with time zone, p_time_zone text DEFAULT NULL::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare
  v_zone text := public._study_zone_v2(p_time_zone);
  v_session public.study_sessions%rowtype;
  v_receipt public.study_event_receipts%rowtype;
  v_progress public.sentence_study_progress%rowtype;
  v_day date := (p_occurred_at at time zone v_zone)::date;
  v_step integer; v_reviews integer; v_delay integer; v_result jsonb;
begin
  perform public._study_lock_v2();
  if p_event_id is null or p_was_correct is null or p_occurred_at is null then raise exception 'invalid_study_event'; end if;
  select * into v_session from public.study_sessions where user_id = auth.uid() and session_id = p_session_id;
  if not found or not (p_sentence_id = any(v_session.sentence_ids)) then raise exception 'study_session_sentence_unavailable'; end if;
  if not exists(select 1 from public.memory_sentences s join public.memories m on m.id = s.memory_id
    where s.id = p_sentence_id and m.user_id = auth.uid() and m.target_language = v_session.target_language)
    then raise exception 'study_sentence_unavailable'; end if;
  select * into v_receipt from public.study_event_receipts where user_id = auth.uid() and event_id = p_event_id;
  if found then
    if v_receipt.session_id <> p_session_id or v_receipt.sentence_id <> p_sentence_id
      or v_receipt.was_correct <> p_was_correct or v_receipt.occurred_at <> p_occurred_at or v_receipt.time_zone <> v_zone then
      raise exception 'study_event_conflict';
    end if;
    return v_receipt.result;
  end if;
  if v_zone <> v_session.time_zone or p_occurred_at < v_session.started_at - interval '5 minutes'
    or p_occurred_at > now() + interval '5 minutes' or p_occurred_at < now() - interval '90 days' then
    raise exception 'invalid_study_event_time';
  end if;
  select * into v_progress from public.sentence_study_progress
  where user_id = auth.uid() and sentence_id = p_sentence_id and study_scope = v_session.study_scope for update;
  if v_progress.id is null or (coalesce(v_progress.last_studied_at,'-infinity') < p_occurred_at
    and coalesce((v_progress.last_studied_at at time zone v_zone)::date,v_progress.last_studied_on,'-infinity'::date) < v_day) then
    v_step := coalesce(v_progress.learning_step,0);
    v_reviews := coalesce(v_progress.mastered_review_count,0);
    if p_was_correct then
      if v_step < 5 then
        v_step := v_step + 1;
        v_delay := (array[1,2,4,7,14])[v_step];
      else
        v_reviews := v_reviews + 1;
        v_delay := case when v_reviews = 1 then 30 else 60 end;
      end if;
    else v_delay := 1; end if;
    insert into public.sentence_study_progress(user_id,sentence_id,study_scope,learning_step,mastered_review_count,
      correct_count,wrong_count,last_result,last_studied_at,last_studied_on,next_review_at)
    values(auth.uid(),p_sentence_id,v_session.study_scope,v_step,v_reviews,
      coalesce(v_progress.correct_count,0) + case when p_was_correct then 1 else 0 end,
      coalesce(v_progress.wrong_count,0) + case when p_was_correct then 0 else 1 end,
      case when p_was_correct then 'correct' else 'incorrect' end,p_occurred_at,v_day,
      ((v_day + v_delay)::timestamp at time zone v_zone))
    on conflict(user_id,sentence_id,study_scope) do update set
      learning_step = excluded.learning_step,mastered_review_count = excluded.mastered_review_count,
      correct_count = excluded.correct_count,wrong_count = excluded.wrong_count,last_result = excluded.last_result,
      last_studied_at = excluded.last_studied_at,last_studied_on = excluded.last_studied_on,
      next_review_at = excluded.next_review_at,updated_at = now()
    returning * into v_progress;
  end if;
  v_result := to_jsonb(v_progress);
  insert into public.study_event_receipts(user_id,event_id,session_id,sentence_id,was_correct,occurred_at,time_zone,result)
  values(auth.uid(),p_event_id,p_session_id,p_sentence_id,p_was_correct,p_occurred_at,v_zone,v_result);
  return v_result;
end;
$$;


--
-- Name: recover_generation_job_v2(uuid, uuid, boolean, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.recover_generation_job_v2(p_user_id uuid, p_request_id uuid, p_is_anonymous boolean, p_request_fingerprint text DEFAULT NULL::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
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


--
-- Name: release_generation_slot(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.release_generation_slot(p_request_id uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
begin
  delete from public.generation_request_slots
  where request_id = p_request_id;
end;
$$;


--
-- Name: replace_study_topic_expressions(uuid, text, text, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.replace_study_topic_expressions(p_user_id uuid, p_topic_key text, p_source_fingerprint text, p_expressions jsonb) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $_$
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
          from (select legacy_sentence.* from public.memory_sentences legacy_sentence join public.memories legacy_memory
        on legacy_memory.id=legacy_sentence.memory_id where legacy_memory.target_language='en'
        and legacy_memory.translation_language='zh-Hans' and legacy_memory.teaching_locale='en-US') sentence
          join public.memories memory on memory.id = sentence.memory_id
          where sentence.id = v_sentence_id
            and memory.user_id = p_user_id
            and sentence.is_favorite = true
        )
        when v_topic_key ~ '^scene:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then exists (
          select 1
          from public.study_scene_sentences link
          join public.study_scenes scene on scene.id = link.scene_id
          join (select legacy_sentence.* from public.memory_sentences legacy_sentence join public.memories legacy_memory
        on legacy_memory.id=legacy_sentence.memory_id where legacy_memory.target_language='en'
        and legacy_memory.translation_language='zh-Hans' and legacy_memory.teaching_locale='en-US') sentence on sentence.id = link.sentence_id
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
$_$;


--
-- Name: require_content_user_v1(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.require_content_user_v1() RETURNS uuid
    LANGUAGE plpgsql STABLE
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
declare v_user uuid := auth.uid();
begin
  if v_user is null or coalesce((auth.jwt()->>'is_anonymous')::boolean,false) then
    raise exception 'Sign in required' using errcode = '42501';
  end if;
  return v_user;
end;
$$;


--
-- Name: scene_category_catalog_version(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.scene_category_catalog_version() RETURNS text
    LANGUAGE sql IMMUTABLE
    SET search_path TO 'public', 'pg_temp'
    AS $$
  select 'unified-scenes-v1'::text;
$$;


--
-- Name: scene_category_ids(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.scene_category_ids() RETURNS text[]
    LANGUAGE sql IMMUTABLE
    SET search_path TO 'public', 'pg_temp'
    AS $$
  select array[
    'people_and_portraits',
    'self_and_style',
    'family_time',
    'children_growing_up',
    'friends_gatherings',
    'romance_and_companionship',
    'pets_and_animals',
    'flowers_and_plants',
    'food_and_drinks',
    'restaurants_and_cafes',
    'cooking',
    'home_life',
    'city_life',
    'natural_scenery',
    'travel',
    'transport',
    'sports_and_outdoors',
    'festivals_and_celebrations',
    'arts_and_entertainment',
    'school_and_study',
    'work_life',
    'shopping',
    'health_and_wellness',
    'objects_and_details',
    'screenshots_and_documents'
  ]::text[];
$$;


--
-- Name: sentence_explanation_source_v2(uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sentence_explanation_source_v2(p_user_id uuid, p_sentence_id uuid) RETURNS jsonb
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
  select jsonb_build_object(
    'targetText', s.target_text, 'translationText', s.translation_text,
    'contentVersion', s.content_version, 'contentSchemaVersion', m.content_schema_version,
    'targetLanguage', m.target_language, 'translationLanguage', m.translation_language,
    'teachingLocale', m.teaching_locale)
  from public.memory_sentences s join public.memories m on m.id = s.memory_id
  where s.id = p_sentence_id and m.user_id = p_user_id;
$$;


--
-- Name: sentence_study_time_zone(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sentence_study_time_zone() RETURNS text
    LANGUAGE plpgsql STABLE
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare
  v_zone text;
begin
  begin
    v_zone := nullif(current_setting('request.headers', true), '')::jsonb ->> 'x-sanju-study-time-zone';
  exception when others then
    return 'Asia/Shanghai';
  end;
  if v_zone is not null and char_length(v_zone) <= 100
    and exists (select 1 from pg_timezone_names where name = v_zone) then
    return v_zone;
  end if;
  -- Old clients do not send a time zone.
  return 'Asia/Shanghai';
end;
$$;


--
-- Name: set_sentence_favorite_v2(uuid, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.set_sentence_favorite_v2(p_sentence_id uuid, p_is_favorite boolean) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
declare v_user uuid := public.require_content_user_v1();
begin
  if p_is_favorite is null then raise exception 'invalid_favorite' using errcode='22023'; end if;
  update public.memory_sentences s set is_favorite=p_is_favorite
    from public.memories m where s.id=p_sentence_id and m.id=s.memory_id and m.user_id=v_user;
  if not found then raise exception 'sentence_not_found' using errcode='42501'; end if;
  return jsonb_build_object('sentenceID',p_sentence_id,'isFavorite',p_is_favorite);
end;
$$;


--
-- Name: set_updated_at(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.set_updated_at() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
begin
  new.updated_at = now();
  return new;
end;
$$;


--
-- Name: strip_sentence_metadata_v1(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.strip_sentence_metadata_v1(p_sentences jsonb) RETURNS jsonb
    LANGUAGE sql IMMUTABLE
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
  select case when jsonb_typeof(p_sentences)='array' then
    coalesce((select jsonb_agg(value - array['learning_topic_ids','learningTopicIDs',
      'expression_purpose','expressionPurpose','embedding','purpose_embedding'] order by ordinality)
      from jsonb_array_elements(p_sentences) with ordinality), '[]'::jsonb)
    else p_sentences end
$$;


--
-- Name: sync_album_flip_feedback(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sync_album_flip_feedback(p_events jsonb) RETURNS SETOF public.album_flip_progress
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
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


--
-- Name: sync_album_flip_feedback_internal_v1(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sync_album_flip_feedback_internal_v1(p_events jsonb) RETURNS SETOF public.album_flip_progress
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare
  v_user uuid := auth.uid();
  v_event jsonb;
  v_id uuid;
  v_sentence uuid;
  v_memory uuid;
  v_feedback text;
  v_at timestamptz;
  v_zone text;
  v_previous public.album_flip_progress%rowtype;
  v_level integer;
  v_last_familiar timestamptz;
  v_sentences uuid[] := '{}';
begin
  if v_user is null or coalesce((auth.jwt()->>'is_anonymous')::boolean, false) then
    raise exception 'Sign in required' using errcode = '42501';
  end if;
  if p_events is null or jsonb_typeof(p_events) <> 'array' then
    raise exception 'Expected feedback array' using errcode = '22023';
  end if;
  if jsonb_array_length(p_events) not between 1 and 100 then
    raise exception 'Expected 1 to 100 feedback events' using errcode = '22023';
  end if;

  -- Serialize this user's batches, including concurrent devices and retries.
  perform pg_advisory_xact_lock(hashtextextended('album_flip:' || v_user::text, 0));
  for v_event in select e.value from jsonb_array_elements(p_events) e
    order by (e.value->>'occurred_at')::timestamptz, (e.value->>'id')::uuid
  loop
    v_id := (v_event->>'id')::uuid;
    v_sentence := (v_event->>'sentence_id')::uuid;
    v_memory := (v_event->>'memory_id')::uuid;
    v_feedback := v_event->>'feedback';
    v_at := (v_event->>'occurred_at')::timestamptz;
    v_zone := v_event->>'time_zone';
    if v_id is null or v_sentence is null or v_memory is null or v_at is null
      or v_at > now() + interval '5 minutes' or not isfinite(v_at)
      or v_feedback is null or v_feedback not in ('again', 'familiar')
      or not exists (select 1 from pg_timezone_names tz where tz.name = v_zone) then
      raise exception 'Invalid album feedback' using errcode = '22023';
    end if;

    -- Deleted/missing/foreign sentences are acknowledged but cannot create rows.
    if not exists (
      select 1 from public.memory_sentences s join public.memories m on m.id = s.memory_id
      where s.id = v_sentence and m.id = v_memory and m.user_id = v_user
    ) then continue; end if;
    v_sentences := array_append(v_sentences, v_sentence);
    select p.* into v_previous from public.album_flip_progress p
      where p.user_id = v_user and p.sentence_id = v_sentence;
    if found and (v_previous.last_feedback_at, v_previous.last_event_id) >= (v_at, v_id) then
      continue;
    end if;

    v_level := coalesce(v_previous.familiarity_level, 0);
    v_last_familiar := v_previous.last_familiar_at;
    if v_feedback = 'again' then
      v_level := 0;
    else
      if v_level = 0 then
        v_level := 1;
      elsif v_last_familiar is null
        or (v_last_familiar at time zone v_zone)::date <> (v_at at time zone v_zone)::date then
        v_level := least(4, v_level + 1);
      end if;
      v_last_familiar := v_at;
    end if;
    insert into public.album_flip_progress as p
      (user_id, sentence_id, memory_id, last_event_id, last_feedback, last_feedback_at,
       familiarity_level, last_familiar_at)
    values (v_user, v_sentence, v_memory, v_id, v_feedback, v_at, v_level, v_last_familiar)
    on conflict (user_id, sentence_id) do update set
      memory_id = excluded.memory_id, last_event_id = excluded.last_event_id,
      last_feedback = excluded.last_feedback, last_feedback_at = excluded.last_feedback_at,
      familiarity_level = excluded.familiarity_level, last_familiar_at = excluded.last_familiar_at;
  end loop;
  return query select p.* from public.album_flip_progress p
    where p.user_id = v_user and p.sentence_id = any(v_sentences);
end;
$$;


--
-- Name: sync_album_flip_feedback_v2(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sync_album_flip_feedback_v2(p_events jsonb) RETURNS SETOF public.album_flip_progress
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
begin
  perform public.require_content_user_v1();
  return query select * from public.sync_album_flip_feedback_internal_v1(p_events);
end;
$$;


--
-- Name: sync_legacy_english_preferences_v1(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sync_legacy_english_preferences_v1() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
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


--
-- Name: touch_sentence_study_progress_updated_at(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.touch_sentence_study_progress_updated_at() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
begin
  new.updated_at := timezone('utc'::text, now());
  return new;
end;
$$;


--
-- Name: transfer_guest_credits(uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.transfer_guest_credits(p_guest_user_id uuid, p_account_user_id uuid) RETURNS TABLE(available_generations integer, merged boolean)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare
    guest_credits integer := 0;
    account_credits integer := 0;
    guest_merge_target uuid;
    new_balance integer := 0;
begin
    if p_guest_user_id is null or p_account_user_id is null then
        raise exception 'guest and account IDs are required' using errcode = '22023';
    end if;
    if p_guest_user_id = p_account_user_id then
        raise exception 'guest and account must be different users' using errcode = '22023';
    end if;

    select profiles.available_generations into account_credits
      from public.profiles where profiles.id = p_account_user_id for update;
    if not found then
        raise exception 'account profile not found';
    end if;

    select profiles.available_generations, profiles.credits_merged_into_user_id
      into guest_credits, guest_merge_target
      from public.profiles where profiles.id = p_guest_user_id for update;
    if not found then
        return query select account_credits, false;
        return;
    end if;

    if guest_merge_target is not null then
        if guest_merge_target = p_account_user_id then
            return query select account_credits, false;
            return;
        end if;
        raise exception 'guest credits already merged into another account';
    end if;

    guest_credits := greatest(coalesce(guest_credits, 0), 0);
    new_balance := account_credits + guest_credits;
    update public.profiles set available_generations = new_balance where id = p_account_user_id;
    update public.profiles
       set available_generations = 0, credits_merged_into_user_id = p_account_user_id,
           credits_merged_at = timezone('utc', now())
     where id = p_guest_user_id;

    if guest_credits > 0 then
        insert into public.generation_transactions (user_id, delta, balance_after, reason, note)
        values (p_account_user_id, guest_credits, new_balance, 'merge_local',
                'guest_user_id:' || p_guest_user_id::text);
    end if;
    return query select new_balance, guest_credits > 0;
end;
$$;


--
-- Name: try_acquire_generation_slot(uuid, uuid, integer, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.try_acquire_generation_slot(p_request_id uuid, p_user_id uuid, p_max_slots integer DEFAULT 8, p_ttl_seconds integer DEFAULT 180) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
declare
  v_active_count integer;
begin
  perform pg_advisory_xact_lock(284731);

  delete from public.generation_request_slots
  where expires_at <= timezone('utc'::text, now());

  if exists (
    select 1
    from public.generation_request_slots
    where request_id = p_request_id
  ) then
    return true;
  end if;

  select count(*)
    into v_active_count
  from public.generation_request_slots
  where expires_at > timezone('utc'::text, now());

  if v_active_count >= greatest(coalesce(p_max_slots, 8), 1) then
    return false;
  end if;

  insert into public.generation_request_slots (
    request_id,
    user_id,
    expires_at
  )
  values (
    p_request_id,
    p_user_id,
    timezone('utc'::text, now()) + make_interval(secs => greatest(coalesce(p_ttl_seconds, 180), 30))
  );

  return true;
end;
$$;


--
-- Name: update_learning_preferences_v1(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.update_learning_preferences_v1(p_patch jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    AS $_$
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
$_$;


--
-- Name: valid_generation_spec_v3(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.valid_generation_spec_v3(p_spec jsonb) RETURNS boolean
    LANGUAGE sql STABLE
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
  select coalesce(jsonb_typeof(p_spec)='object'
    and p_spec @> '{"schemaVersion":1,"catalogVersion":1}'::jsonb
    and p_spec->>'generationFormat' in ('dual_tabs_v1','dialogue_tabs_v1','dialogue_trio_v1','scenario_dialogue_v1')
    and p_spec->>'level' in ('starter','beginner','intermediate','advanced')
    and exists(select 1 from public.language_capabilities_v1 c
      where c.target_language=p_spec->>'targetLanguage' and c.translation_language=p_spec->>'translationLanguage'
        and c.teaching_locale=p_spec->>'teachingLocale'),false)
$$;


--
-- Name: valid_learning_material_v1(jsonb, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.valid_learning_material_v1(p_material jsonb, p_text text) RETURNS boolean
    LANGUAGE plpgsql IMMUTABLE
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    AS $_$
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
$_$;


--
-- Name: valid_sentence_collection_v1(jsonb, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.valid_sentence_collection_v1(p_sentences jsonb, p_format text DEFAULT NULL::text) RETURNS boolean
    LANGUAGE plpgsql IMMUTABLE
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
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


--
-- Name: valid_sentence_dialogue_v1(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.valid_sentence_dialogue_v1(p_dialogue jsonb) RETURNS boolean
    LANGUAGE plpgsql IMMUTABLE
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
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


--
-- Name: valid_sentence_explanation_v3(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.valid_sentence_explanation_v3(p_content jsonb) RETURNS boolean
    LANGUAGE plpgsql IMMUTABLE
    SET search_path TO 'public', 'pg_temp'
    AS $$
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


--
-- Name: validate_memory_import_v1(jsonb, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.validate_memory_import_v1(p_memory jsonb, p_user_id uuid) RETURNS void
    LANGUAGE plpgsql
    SET search_path TO 'pg_catalog', 'public', 'pg_temp'
    AS $_$
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
$_$;


--
-- Name: account_deletion_jobs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.account_deletion_jobs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    status text NOT NULL,
    requested_at timestamp with time zone DEFAULT now() NOT NULL,
    started_at timestamp with time zone,
    completed_at timestamp with time zone,
    last_error text,
    CONSTRAINT account_deletion_jobs_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'running'::text, 'completed'::text, 'failed'::text])))
);


--
-- Name: apple_auth_credentials; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.apple_auth_credentials (
    user_id uuid NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    refresh_token text NOT NULL
);


--
-- Name: generation_jobs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.generation_jobs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    client_request_id uuid NOT NULL,
    user_id uuid NOT NULL,
    status text DEFAULT 'pending'::text NOT NULL,
    memory_id uuid,
    image_path text,
    provider text,
    mimo_failure_reason text,
    remaining_credits integer,
    error_message text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    completed_at timestamp with time zone,
    failed_at timestamp with time zone,
    request_schema_version integer DEFAULT 1 NOT NULL,
    generation_spec jsonb,
    request_fingerprint text,
    generation_policy jsonb,
    CONSTRAINT generation_jobs_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'completed'::text, 'failed'::text])))
);


--
-- Name: generation_request_slots; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.generation_request_slots (
    request_id uuid NOT NULL,
    user_id uuid NOT NULL,
    created_at timestamp with time zone DEFAULT timezone('utc'::text, now()) NOT NULL,
    expires_at timestamp with time zone NOT NULL
);


--
-- Name: generation_transactions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.generation_transactions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    delta integer NOT NULL,
    balance_after integer NOT NULL,
    reason text NOT NULL,
    related_memory_id uuid,
    note text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    transaction_id text,
    CONSTRAINT generation_transactions_balance_after_check CHECK ((balance_after >= 0)),
    CONSTRAINT generation_transactions_reason_check CHECK ((reason = ANY (ARRAY['init'::text, 'generate'::text, 'purchase'::text, 'admin_adjust'::text, 'merge_local'::text])))
);


--
-- Name: guest_generation_jobs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.guest_generation_jobs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    status text NOT NULL,
    image_path text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    completed_at timestamp with time zone,
    acknowledged_at timestamp with time zone,
    remaining_credits integer,
    sentences jsonb,
    error_message text,
    provider text,
    client_request_id uuid,
    mimo_failure_reason text,
    tags text[] DEFAULT '{}'::text[] NOT NULL,
    request_schema_version integer DEFAULT 1 NOT NULL,
    generation_spec jsonb,
    request_fingerprint text,
    generation_policy jsonb,
    result_content jsonb,
    CONSTRAINT guest_generation_jobs_provider_check CHECK ((provider = ANY (ARRAY['mimo'::text, 'kimi'::text, 'deepseek'::text]))),
    CONSTRAINT guest_generation_jobs_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'completed'::text, 'failed'::text, 'acknowledged'::text])))
);


--
-- Name: guest_memory_import_receipts_v1; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.guest_memory_import_receipts_v1 (
    memory_id uuid NOT NULL,
    user_id uuid NOT NULL,
    content_digest text NOT NULL,
    imported_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: language_capabilities_v1; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.language_capabilities_v1 (
    target_language text NOT NULL,
    translation_language text NOT NULL,
    teaching_locale text NOT NULL,
    can_generate boolean DEFAULT false NOT NULL,
    CONSTRAINT language_capabilities_v1_check CHECK ((((target_language = 'en'::text) AND (teaching_locale = 'en-US'::text) AND (translation_language = ANY (ARRAY['zh-Hans'::text, 'es'::text, 'ja'::text, 'fr'::text]))) OR ((target_language = 'es'::text) AND (teaching_locale = 'es-419'::text) AND (translation_language = ANY (ARRAY['zh-Hans'::text, 'en'::text]))) OR ((target_language = 'ja'::text) AND (teaching_locale = 'ja-JP'::text) AND (translation_language = ANY (ARRAY['zh-Hans'::text, 'en'::text]))) OR ((target_language = 'fr'::text) AND (teaching_locale = 'fr-FR'::text) AND (translation_language = ANY (ARRAY['zh-Hans'::text, 'en'::text])))))
);


--
-- Name: memories; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.memories (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    image_url text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    provider text,
    client_request_id uuid,
    mimo_failure_reason text,
    tags text[] DEFAULT '{}'::text[] NOT NULL,
    target_language text DEFAULT 'en'::text NOT NULL,
    translation_language text DEFAULT 'zh-Hans'::text NOT NULL,
    teaching_locale text DEFAULT 'en-US'::text NOT NULL,
    content_schema_version integer DEFAULT 2 NOT NULL,
    generation_spec jsonb,
    dialogue_format text,
    scenario_count integer,
    CONSTRAINT memories_content_schema_v2 CHECK ((content_schema_version = 2)),
    CONSTRAINT memories_dialogue_format_v1 CHECK ((dialogue_format = ANY (ARRAY['dialogue_tabs_v1'::text, 'dialogue_trio_v1'::text, 'scenario_dialogue_v1'::text]))),
    CONSTRAINT memories_generation_spec_v1 CHECK (((generation_spec IS NULL) OR (public.valid_generation_spec_v3(generation_spec) AND (generation_spec @> jsonb_build_object('targetLanguage', target_language, 'translationLanguage', translation_language, 'teachingLocale', teaching_locale))))),
    CONSTRAINT memories_provider_check CHECK ((provider = ANY (ARRAY['mimo'::text, 'kimi'::text, 'deepseek'::text]))),
    CONSTRAINT memories_scenario_count_v1 CHECK (
CASE
    WHEN (dialogue_format = 'scenario_dialogue_v1'::text) THEN ((scenario_count IS NOT NULL) AND (scenario_count = ANY (ARRAY[2, 3])))
    ELSE (scenario_count IS NULL)
END),
    CONSTRAINT memories_teaching_locale_v1 CHECK ((((target_language = 'en'::text) AND (teaching_locale = 'en-US'::text)) OR ((target_language = 'es'::text) AND (teaching_locale = 'es-419'::text)) OR ((target_language = 'ja'::text) AND (teaching_locale = 'ja-JP'::text)) OR ((target_language = 'fr'::text) AND (teaching_locale = 'fr-FR'::text))))
);


--
-- Name: memory_deletion_receipts_v2; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.memory_deletion_receipts_v2 (
    user_id uuid NOT NULL,
    operation_id uuid NOT NULL,
    memory_id uuid NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: memory_sentences; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.memory_sentences (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    memory_id uuid NOT NULL,
    sort_order integer NOT NULL,
    english text,
    chinese text,
    is_favorite boolean DEFAULT false NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    presentation_group text DEFAULT 'what_i_see'::text NOT NULL,
    target_text text NOT NULL,
    translation_text text NOT NULL,
    content_version integer DEFAULT 1 NOT NULL,
    learning_material jsonb,
    dialogue jsonb,
    learning_topic_ids text[] DEFAULT '{}'::text[] NOT NULL,
    CONSTRAINT memory_sentences_content_version_v1 CHECK ((content_version = 1)),
    CONSTRAINT memory_sentences_dialogue_v1 CHECK (((dialogue IS NULL) OR public.valid_sentence_dialogue_v1(dialogue))),
    CONSTRAINT memory_sentences_learning_material_v1 CHECK (public.valid_learning_material_v1(learning_material, target_text)),
    CONSTRAINT memory_sentences_presentation_group_check CHECK ((presentation_group = ANY (ARRAY['what_i_see'::text, 'what_i_say'::text]))),
    CONSTRAINT memory_sentences_sort_order_check CHECK (((sort_order >= 0) AND (sort_order < 12)))
);


--
-- Name: COLUMN memory_sentences.learning_topic_ids; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.memory_sentences.learning_topic_ids IS 'Legacy client compatibility only. Sentence classification is retired; new rows default to an empty array.';


--
-- Name: profiles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.profiles (
    id uuid NOT NULL,
    apple_user_id text,
    nickname text DEFAULT '英语学习者'::text NOT NULL,
    avatar_url text,
    email text,
    english_level text DEFAULT '中等'::text NOT NULL,
    language_style text DEFAULT '平铺直叙'::text NOT NULL,
    available_generations integer DEFAULT 12 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    credits_merged_into_user_id uuid,
    credits_merged_at timestamp with time zone,
    generation_banned_until timestamp with time zone,
    generation_violation_count integer DEFAULT 0 NOT NULL,
    generation_violation_window_started_at timestamp with time zone,
    last_generation_violation_at timestamp with time zone,
    avatar_storage_path text,
    avatar_mime_type text,
    avatar_updated_at timestamp with time zone,
    speech_voice text,
    CONSTRAINT profiles_available_generations_check CHECK ((available_generations >= 0)),
    CONSTRAINT profiles_english_level_check CHECK ((english_level = ANY (ARRAY['启蒙'::text, '简单'::text, '中等'::text, '高级'::text]))),
    CONSTRAINT profiles_language_style_check CHECK ((language_style = ANY (ARRAY['平铺直叙'::text, '抒情优美'::text]))),
    CONSTRAINT profiles_speech_voice_check CHECK ((speech_voice = ANY (ARRAY['Mia'::text, 'Chloe'::text, 'Milo'::text, 'Dean'::text])))
);


--
-- Name: COLUMN profiles.speech_voice; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.profiles.speech_voice IS 'Account reading voice. Null until first configured; governed by existing profile RLS.';


--
-- Name: purchase_ledger; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.purchase_ledger (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    transaction_id text NOT NULL,
    product_id text NOT NULL,
    credits integer NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT purchase_ledger_credits_check CHECK ((credits > 0))
);


--
-- Name: sentence_explanation_limits; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.sentence_explanation_limits (
    user_id uuid NOT NULL,
    minute_started_at timestamp with time zone NOT NULL,
    minute_count integer NOT NULL,
    request_day date NOT NULL,
    day_count integer NOT NULL
);


--
-- Name: sentence_explanations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.sentence_explanations (
    user_id uuid NOT NULL,
    fingerprint text NOT NULL,
    content jsonb,
    claim_id uuid,
    lease_until timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT sentence_explanations_content_check CHECK (((content IS NULL) OR COALESCE((((jsonb_typeof(content) = 'object'::text) AND ((content ->> 'version'::text) = ANY (ARRAY['1'::text, '2'::text]))) OR public.valid_sentence_explanation_v3(content)), false))),
    CONSTRAINT sentence_explanations_fingerprint_check CHECK ((fingerprint ~ '^[0-9a-f]{64}$'::text))
);


--
-- Name: sentence_study_activations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.sentence_study_activations (
    user_id uuid NOT NULL,
    sentence_id uuid NOT NULL,
    first_activated_at timestamp with time zone DEFAULT now() NOT NULL,
    source text NOT NULL,
    session_id uuid,
    CONSTRAINT sentence_study_activations_source_check CHECK ((source = ANY (ARRAY['session'::text, 'legacy'::text, 'import'::text, 'baseline'::text])))
);


--
-- Name: speech_request_limits; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.speech_request_limits (
    user_id uuid NOT NULL,
    minute_started_at timestamp with time zone NOT NULL,
    minute_count integer NOT NULL,
    request_day date NOT NULL,
    day_count integer NOT NULL
);


--
-- Name: study_event_receipts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.study_event_receipts (
    user_id uuid NOT NULL,
    event_id uuid NOT NULL,
    session_id uuid NOT NULL,
    sentence_id uuid NOT NULL,
    was_correct boolean NOT NULL,
    occurred_at timestamp with time zone NOT NULL,
    time_zone text NOT NULL,
    result jsonb NOT NULL
);


--
-- Name: study_scene_sentence_reviews; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.study_scene_sentence_reviews (
    scene_id uuid NOT NULL,
    sentence_id uuid NOT NULL,
    user_id uuid NOT NULL,
    input_hash text NOT NULL,
    similarity double precision NOT NULL,
    status text DEFAULT 'pending'::text NOT NULL,
    reason text,
    attempts integer DEFAULT 0 NOT NULL,
    retry_at timestamp with time zone DEFAULT now() NOT NULL,
    lease_token uuid,
    lease_until timestamp with time zone,
    reviewed_at timestamp with time zone,
    CONSTRAINT study_scene_sentence_reviews_similarity_check CHECK (((similarity >= ('-1'::integer)::double precision) AND (similarity <= (1)::double precision))),
    CONSTRAINT study_scene_sentence_reviews_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'accepted'::text, 'rejected'::text])))
);


--
-- Name: study_scene_sentences; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.study_scene_sentences (
    scene_id uuid NOT NULL,
    sentence_id uuid NOT NULL,
    match_score integer NOT NULL,
    match_source text DEFAULT 'automatic'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT study_scene_sentences_match_score_check CHECK (((match_score >= 1) AND (match_score <= 100)))
);


--
-- Name: study_scenes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.study_scenes (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    name text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    learning_topic_id text,
    match_threshold double precision DEFAULT 0.42 NOT NULL,
    match_rule_version integer DEFAULT 0 NOT NULL,
    CONSTRAINT study_scenes_learning_topic_id_check CHECK (((learning_topic_id IS NULL) OR (learning_topic_id = ANY (public.scene_category_ids())))),
    CONSTRAINT study_scenes_match_threshold_check CHECK ((match_threshold = ANY (ARRAY[(0.36)::double precision, (0.38)::double precision, (0.40)::double precision, (0.42)::double precision, (0.44)::double precision, (0.46)::double precision, (0.48)::double precision]))),
    CONSTRAINT study_scenes_name_check CHECK (((char_length(btrim(name)) >= 2) AND (char_length(btrim(name)) <= 24)))
);


--
-- Name: study_sessions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.study_sessions (
    user_id uuid NOT NULL,
    session_id uuid NOT NULL,
    target_language text NOT NULL,
    study_scope text NOT NULL,
    mode text NOT NULL,
    time_zone text NOT NULL,
    requested_limit integer NOT NULL,
    legacy_only boolean DEFAULT false NOT NULL,
    sentence_ids uuid[] NOT NULL,
    started_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT study_sessions_mode_check CHECK ((mode = ANY (ARRAY['due'::text, 'today'::text, 'direct'::text]))),
    CONSTRAINT study_sessions_target_language_check CHECK ((target_language = ANY (ARRAY['en'::text, 'es'::text, 'ja'::text, 'fr'::text])))
);


--
-- Name: study_topic_expression_examples; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.study_topic_expression_examples (
    expression_id uuid NOT NULL,
    sentence_id uuid NOT NULL,
    sort_order integer DEFAULT 0 NOT NULL
);


--
-- Name: study_topic_expression_sets; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.study_topic_expression_sets (
    user_id uuid NOT NULL,
    topic_key text NOT NULL,
    source_fingerprint text NOT NULL,
    generated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT study_topic_expression_sets_source_fingerprint_check CHECK ((char_length(source_fingerprint) = 64)),
    CONSTRAINT study_topic_expression_sets_topic_key_check CHECK (((char_length(btrim(topic_key)) >= 1) AND (char_length(btrim(topic_key)) <= 80)))
);


--
-- Name: study_topic_expressions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.study_topic_expressions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    topic_key text NOT NULL,
    kind text NOT NULL,
    english text NOT NULL,
    chinese text NOT NULL,
    part_of_speech text,
    occurrence_count integer NOT NULL,
    sort_order integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT study_topic_expressions_chinese_check CHECK (((char_length(btrim(chinese)) >= 1) AND (char_length(btrim(chinese)) <= 120))),
    CONSTRAINT study_topic_expressions_english_check CHECK (((char_length(btrim(english)) >= 1) AND (char_length(btrim(english)) <= 120))),
    CONSTRAINT study_topic_expressions_kind_check CHECK ((kind = ANY (ARRAY['word'::text, 'phrase'::text]))),
    CONSTRAINT study_topic_expressions_occurrence_count_check CHECK ((occurrence_count >= 1)),
    CONSTRAINT study_topic_expressions_topic_key_check CHECK (((char_length(btrim(topic_key)) >= 1) AND (char_length(btrim(topic_key)) <= 80)))
);


--
-- Name: user_language_preferences; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_language_preferences (
    user_id uuid NOT NULL,
    target_language text NOT NULL,
    level text,
    level_revision bigint DEFAULT 0 NOT NULL,
    speech_voice text,
    voice_revision bigint DEFAULT 0 NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT user_language_preferences_check CHECK (((speech_voice IS NULL) OR ((target_language = 'en'::text) AND (speech_voice = ANY (ARRAY['Mia'::text, 'Chloe'::text, 'Milo'::text, 'Dean'::text]))))),
    CONSTRAINT user_language_preferences_level_check CHECK ((level = ANY (ARRAY['starter'::text, 'beginner'::text, 'intermediate'::text, 'advanced'::text]))),
    CONSTRAINT user_language_preferences_level_revision_check CHECK ((level_revision >= 0)),
    CONSTRAINT user_language_preferences_target_language_check CHECK ((target_language = ANY (ARRAY['en'::text, 'es'::text, 'ja'::text, 'fr'::text]))),
    CONSTRAINT user_language_preferences_voice_revision_check CHECK ((voice_revision >= 0))
);


--
-- Name: user_learning_preferences; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_learning_preferences (
    user_id uuid NOT NULL,
    selection_mode text NOT NULL,
    target_language text NOT NULL,
    translation_language text NOT NULL,
    explanation_language text NOT NULL,
    revision bigint NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT user_learning_preferences_check CHECK ((((selection_mode = 'standard'::text) AND (explanation_language = translation_language)) OR ((selection_mode = 'legacyEnglish'::text) AND (target_language = 'en'::text) AND (translation_language = 'zh-Hans'::text) AND (explanation_language = ANY (ARRAY['zh-Hans'::text, 'en'::text]))))),
    CONSTRAINT user_learning_preferences_revision_check CHECK ((revision > 0)),
    CONSTRAINT user_learning_preferences_selection_mode_check CHECK ((selection_mode = ANY (ARRAY['standard'::text, 'legacyEnglish'::text])))
);


--
-- Name: account_deletion_jobs account_deletion_jobs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.account_deletion_jobs
    ADD CONSTRAINT account_deletion_jobs_pkey PRIMARY KEY (id);


--
-- Name: account_deletion_jobs account_deletion_jobs_user_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.account_deletion_jobs
    ADD CONSTRAINT account_deletion_jobs_user_id_key UNIQUE (user_id);


--
-- Name: album_flip_progress album_flip_progress_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.album_flip_progress
    ADD CONSTRAINT album_flip_progress_pkey PRIMARY KEY (user_id, sentence_id);


--
-- Name: apple_auth_credentials apple_auth_credentials_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.apple_auth_credentials
    ADD CONSTRAINT apple_auth_credentials_pkey PRIMARY KEY (user_id);


--
-- Name: generation_jobs generation_jobs_client_request_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.generation_jobs
    ADD CONSTRAINT generation_jobs_client_request_id_key UNIQUE (client_request_id);


--
-- Name: generation_jobs generation_jobs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.generation_jobs
    ADD CONSTRAINT generation_jobs_pkey PRIMARY KEY (id);


--
-- Name: generation_request_slots generation_request_slots_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.generation_request_slots
    ADD CONSTRAINT generation_request_slots_pkey PRIMARY KEY (request_id);


--
-- Name: generation_transactions generation_transactions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.generation_transactions
    ADD CONSTRAINT generation_transactions_pkey PRIMARY KEY (id);


--
-- Name: guest_generation_jobs guest_generation_jobs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.guest_generation_jobs
    ADD CONSTRAINT guest_generation_jobs_pkey PRIMARY KEY (id);


--
-- Name: guest_memory_import_receipts_v1 guest_memory_import_receipts_v1_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.guest_memory_import_receipts_v1
    ADD CONSTRAINT guest_memory_import_receipts_v1_pkey PRIMARY KEY (memory_id);


--
-- Name: language_capabilities_v1 language_capabilities_v1_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.language_capabilities_v1
    ADD CONSTRAINT language_capabilities_v1_pkey PRIMARY KEY (target_language, translation_language);


--
-- Name: memories memories_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memories
    ADD CONSTRAINT memories_pkey PRIMARY KEY (id);


--
-- Name: memory_deletion_receipts_v2 memory_deletion_receipts_v2_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memory_deletion_receipts_v2
    ADD CONSTRAINT memory_deletion_receipts_v2_pkey PRIMARY KEY (user_id, operation_id);


--
-- Name: memory_image_cleanup_jobs_v2 memory_image_cleanup_jobs_v2_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memory_image_cleanup_jobs_v2
    ADD CONSTRAINT memory_image_cleanup_jobs_v2_pkey PRIMARY KEY (id);


--
-- Name: memory_image_cleanup_jobs_v2 memory_image_cleanup_jobs_v2_user_id_memory_id_image_path_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memory_image_cleanup_jobs_v2
    ADD CONSTRAINT memory_image_cleanup_jobs_v2_user_id_memory_id_image_path_key UNIQUE (user_id, memory_id, image_path);


--
-- Name: memory_sentences memory_sentences_memory_id_sort_order_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memory_sentences
    ADD CONSTRAINT memory_sentences_memory_id_sort_order_key UNIQUE (memory_id, sort_order);


--
-- Name: memory_sentences memory_sentences_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memory_sentences
    ADD CONSTRAINT memory_sentences_pkey PRIMARY KEY (id);


--
-- Name: profiles profiles_apple_user_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.profiles
    ADD CONSTRAINT profiles_apple_user_id_key UNIQUE (apple_user_id);


--
-- Name: profiles profiles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.profiles
    ADD CONSTRAINT profiles_pkey PRIMARY KEY (id);


--
-- Name: purchase_ledger purchase_ledger_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.purchase_ledger
    ADD CONSTRAINT purchase_ledger_pkey PRIMARY KEY (id);


--
-- Name: purchase_ledger purchase_ledger_transaction_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.purchase_ledger
    ADD CONSTRAINT purchase_ledger_transaction_id_key UNIQUE (transaction_id);


--
-- Name: sentence_explanation_limits sentence_explanation_limits_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sentence_explanation_limits
    ADD CONSTRAINT sentence_explanation_limits_pkey PRIMARY KEY (user_id);


--
-- Name: sentence_explanations sentence_explanations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sentence_explanations
    ADD CONSTRAINT sentence_explanations_pkey PRIMARY KEY (user_id, fingerprint);


--
-- Name: sentence_study_activations sentence_study_activations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sentence_study_activations
    ADD CONSTRAINT sentence_study_activations_pkey PRIMARY KEY (user_id, sentence_id);


--
-- Name: sentence_study_progress sentence_study_progress_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sentence_study_progress
    ADD CONSTRAINT sentence_study_progress_pkey PRIMARY KEY (id);


--
-- Name: sentence_study_progress sentence_study_progress_user_id_sentence_id_scope_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sentence_study_progress
    ADD CONSTRAINT sentence_study_progress_user_id_sentence_id_scope_key UNIQUE (user_id, sentence_id, study_scope);


--
-- Name: speech_request_limits speech_request_limits_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.speech_request_limits
    ADD CONSTRAINT speech_request_limits_pkey PRIMARY KEY (user_id);


--
-- Name: study_event_receipts study_event_receipts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.study_event_receipts
    ADD CONSTRAINT study_event_receipts_pkey PRIMARY KEY (user_id, event_id);


--
-- Name: study_scene_sentence_reviews study_scene_sentence_reviews_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.study_scene_sentence_reviews
    ADD CONSTRAINT study_scene_sentence_reviews_pkey PRIMARY KEY (scene_id, sentence_id);


--
-- Name: study_scene_sentences study_scene_sentences_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.study_scene_sentences
    ADD CONSTRAINT study_scene_sentences_pkey PRIMARY KEY (scene_id, sentence_id);


--
-- Name: study_scenes study_scenes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.study_scenes
    ADD CONSTRAINT study_scenes_pkey PRIMARY KEY (id);


--
-- Name: study_scenes study_scenes_user_id_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.study_scenes
    ADD CONSTRAINT study_scenes_user_id_name_key UNIQUE (user_id, name);


--
-- Name: study_sessions study_sessions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.study_sessions
    ADD CONSTRAINT study_sessions_pkey PRIMARY KEY (user_id, session_id);


--
-- Name: study_topic_expression_examples study_topic_expression_examples_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.study_topic_expression_examples
    ADD CONSTRAINT study_topic_expression_examples_pkey PRIMARY KEY (expression_id, sentence_id);


--
-- Name: study_topic_expression_sets study_topic_expression_sets_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.study_topic_expression_sets
    ADD CONSTRAINT study_topic_expression_sets_pkey PRIMARY KEY (user_id, topic_key);


--
-- Name: study_topic_expressions study_topic_expressions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.study_topic_expressions
    ADD CONSTRAINT study_topic_expressions_pkey PRIMARY KEY (id);


--
-- Name: study_topic_expressions study_topic_expressions_user_id_topic_key_kind_english_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.study_topic_expressions
    ADD CONSTRAINT study_topic_expressions_user_id_topic_key_kind_english_key UNIQUE (user_id, topic_key, kind, english);


--
-- Name: user_language_preferences user_language_preferences_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_language_preferences
    ADD CONSTRAINT user_language_preferences_pkey PRIMARY KEY (user_id, target_language);


--
-- Name: user_learning_preferences user_learning_preferences_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_learning_preferences
    ADD CONSTRAINT user_learning_preferences_pkey PRIMARY KEY (user_id);


--
-- Name: account_deletion_jobs_status_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX account_deletion_jobs_status_idx ON public.account_deletion_jobs USING btree (status, requested_at);


--
-- Name: account_deletion_jobs_user_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX account_deletion_jobs_user_id_idx ON public.account_deletion_jobs USING btree (user_id);


--
-- Name: album_flip_progress_memory_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX album_flip_progress_memory_idx ON public.album_flip_progress USING btree (memory_id);


--
-- Name: album_flip_progress_sentence_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX album_flip_progress_sentence_idx ON public.album_flip_progress USING btree (sentence_id);


--
-- Name: generation_jobs_user_id_created_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX generation_jobs_user_id_created_at_idx ON public.generation_jobs USING btree (user_id, created_at DESC);


--
-- Name: generation_request_slots_expires_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX generation_request_slots_expires_at_idx ON public.generation_request_slots USING btree (expires_at);


--
-- Name: generation_transactions_transaction_id_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX generation_transactions_transaction_id_key ON public.generation_transactions USING btree (transaction_id) WHERE (transaction_id IS NOT NULL);


--
-- Name: generation_transactions_transaction_id_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX generation_transactions_transaction_id_unique ON public.generation_transactions USING btree (transaction_id) WHERE (transaction_id IS NOT NULL);


--
-- Name: generation_transactions_user_id_created_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX generation_transactions_user_id_created_at_idx ON public.generation_transactions USING btree (user_id, created_at DESC);


--
-- Name: guest_generation_jobs_client_request_id_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX guest_generation_jobs_client_request_id_unique ON public.guest_generation_jobs USING btree (client_request_id) WHERE (client_request_id IS NOT NULL);


--
-- Name: guest_generation_jobs_user_status_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX guest_generation_jobs_user_status_idx ON public.guest_generation_jobs USING btree (user_id, status, created_at DESC);


--
-- Name: memories_client_request_id_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX memories_client_request_id_unique ON public.memories USING btree (client_request_id) WHERE (client_request_id IS NOT NULL);


--
-- Name: memories_mimo_failure_reason_created_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX memories_mimo_failure_reason_created_at_idx ON public.memories USING btree (mimo_failure_reason, created_at DESC) WHERE (mimo_failure_reason IS NOT NULL);


--
-- Name: memories_owner_language_page_v2; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX memories_owner_language_page_v2 ON public.memories USING btree (user_id, target_language, created_at DESC, id DESC);


--
-- Name: memories_provider_created_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX memories_provider_created_at_idx ON public.memories USING btree (provider, created_at DESC);


--
-- Name: memories_tags_gin_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX memories_tags_gin_idx ON public.memories USING gin (tags);


--
-- Name: memories_user_id_created_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX memories_user_id_created_at_idx ON public.memories USING btree (user_id, created_at DESC);


--
-- Name: memory_image_cleanup_jobs_due_v2; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX memory_image_cleanup_jobs_due_v2 ON public.memory_image_cleanup_jobs_v2 USING btree (next_attempt_at, created_at) WHERE (completed_at IS NULL);


--
-- Name: memory_image_cleanup_jobs_path_v2; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX memory_image_cleanup_jobs_path_v2 ON public.memory_image_cleanup_jobs_v2 USING btree (image_path);


--
-- Name: memory_sentences_dialogue_turn_v1; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX memory_sentences_dialogue_turn_v1 ON public.memory_sentences USING btree (memory_id, presentation_group, ((dialogue -> 'index'::text)), ((dialogue -> 'turn'::text))) WHERE (dialogue IS NOT NULL);


--
-- Name: memory_sentences_memory_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX memory_sentences_memory_id_idx ON public.memory_sentences USING btree (memory_id);


--
-- Name: sentence_study_activations_day; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX sentence_study_activations_day ON public.sentence_study_activations USING btree (user_id, first_activated_at);


--
-- Name: sentence_study_progress_user_id_last_studied_on_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX sentence_study_progress_user_id_last_studied_on_idx ON public.sentence_study_progress USING btree (user_id, last_studied_on);


--
-- Name: sentence_study_progress_user_id_next_review_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX sentence_study_progress_user_id_next_review_at_idx ON public.sentence_study_progress USING btree (user_id, next_review_at);


--
-- Name: sentence_study_progress_user_scope_last_studied_on_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX sentence_study_progress_user_scope_last_studied_on_idx ON public.sentence_study_progress USING btree (user_id, study_scope, last_studied_on);


--
-- Name: sentence_study_progress_user_scope_next_review_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX sentence_study_progress_user_scope_next_review_at_idx ON public.sentence_study_progress USING btree (user_id, study_scope, next_review_at);


--
-- Name: study_scene_sentence_reviews_pending_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX study_scene_sentence_reviews_pending_idx ON public.study_scene_sentence_reviews USING btree (user_id, retry_at) WHERE (status = 'pending'::text);


--
-- Name: study_scene_sentences_sentence_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX study_scene_sentences_sentence_id_idx ON public.study_scene_sentences USING btree (sentence_id);


--
-- Name: study_scenes_user_created_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX study_scenes_user_created_at_idx ON public.study_scenes USING btree (user_id, created_at DESC);


--
-- Name: study_scenes_user_learning_topic_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX study_scenes_user_learning_topic_idx ON public.study_scenes USING btree (user_id, learning_topic_id) WHERE (learning_topic_id IS NOT NULL);


--
-- Name: study_topic_expression_examples_expression_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX study_topic_expression_examples_expression_idx ON public.study_topic_expression_examples USING btree (expression_id, sort_order);


--
-- Name: study_topic_expressions_owner_topic_kind_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX study_topic_expressions_owner_topic_kind_idx ON public.study_topic_expressions USING btree (user_id, topic_key, kind, sort_order);


--
-- Name: memories guard_memory_image_lifecycle_v2; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER guard_memory_image_lifecycle_v2 BEFORE INSERT OR DELETE ON public.memories FOR EACH ROW EXECUTE FUNCTION public.guard_memory_image_lifecycle_v2();


--
-- Name: memory_sentences project_sentence_content_v2; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER project_sentence_content_v2 BEFORE INSERT OR UPDATE ON public.memory_sentences FOR EACH ROW EXECUTE FUNCTION public.project_sentence_content_v2();


--
-- Name: memory_sentences protect_dialogue_collection_v1; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER protect_dialogue_collection_v1 AFTER INSERT OR DELETE OR UPDATE ON public.memory_sentences DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.protect_dialogue_collection_v1();


--
-- Name: generation_jobs protect_generation_context_v3; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER protect_generation_context_v3 BEFORE UPDATE ON public.generation_jobs FOR EACH ROW EXECUTE FUNCTION public.protect_generation_context_v3();


--
-- Name: guest_generation_jobs protect_generation_context_v3; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER protect_generation_context_v3 BEFORE UPDATE ON public.guest_generation_jobs FOR EACH ROW EXECUTE FUNCTION public.protect_generation_context_v3();


--
-- Name: generation_jobs protect_generation_job_result; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER protect_generation_job_result BEFORE UPDATE ON public.generation_jobs FOR EACH ROW EXECUTE FUNCTION public.protect_generation_job_result();


--
-- Name: guest_generation_jobs protect_generation_job_result; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER protect_generation_job_result BEFORE UPDATE ON public.guest_generation_jobs FOR EACH ROW EXECUTE FUNCTION public.protect_generation_job_result();


--
-- Name: memories protect_memory_content_v2; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER protect_memory_content_v2 BEFORE INSERT OR UPDATE ON public.memories FOR EACH ROW EXECUTE FUNCTION public.protect_memory_content_v2();


--
-- Name: profiles protect_profile_balance_fields_on_insert; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER protect_profile_balance_fields_on_insert BEFORE INSERT ON public.profiles FOR EACH ROW EXECUTE FUNCTION public.protect_profile_balance_fields();


--
-- Name: profiles protect_profile_balance_fields_on_update; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER protect_profile_balance_fields_on_update BEFORE UPDATE OF available_generations, credits_merged_into_user_id, credits_merged_at ON public.profiles FOR EACH ROW EXECUTE FUNCTION public.protect_profile_balance_fields();


--
-- Name: sentence_study_progress sentence_study_progress_touch_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER sentence_study_progress_touch_updated_at BEFORE UPDATE ON public.sentence_study_progress FOR EACH ROW EXECUTE FUNCTION public.touch_sentence_study_progress_updated_at();


--
-- Name: profiles set_profiles_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER set_profiles_updated_at BEFORE UPDATE ON public.profiles FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: profiles sync_legacy_english_preferences_v1; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER sync_legacy_english_preferences_v1 AFTER INSERT OR UPDATE OF english_level, speech_voice ON public.profiles FOR EACH ROW EXECUTE FUNCTION public.sync_legacy_english_preferences_v1();


--
-- Name: album_flip_progress album_flip_progress_memory_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.album_flip_progress
    ADD CONSTRAINT album_flip_progress_memory_id_fkey FOREIGN KEY (memory_id) REFERENCES public.memories(id) ON DELETE CASCADE;


--
-- Name: album_flip_progress album_flip_progress_sentence_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.album_flip_progress
    ADD CONSTRAINT album_flip_progress_sentence_id_fkey FOREIGN KEY (sentence_id) REFERENCES public.memory_sentences(id) ON DELETE CASCADE;


--
-- Name: album_flip_progress album_flip_progress_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.album_flip_progress
    ADD CONSTRAINT album_flip_progress_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: apple_auth_credentials apple_auth_credentials_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.apple_auth_credentials
    ADD CONSTRAINT apple_auth_credentials_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: generation_jobs generation_jobs_memory_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.generation_jobs
    ADD CONSTRAINT generation_jobs_memory_id_fkey FOREIGN KEY (memory_id) REFERENCES public.memories(id) ON DELETE SET NULL;


--
-- Name: generation_jobs generation_jobs_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.generation_jobs
    ADD CONSTRAINT generation_jobs_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.profiles(id) ON DELETE CASCADE;


--
-- Name: generation_request_slots generation_request_slots_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.generation_request_slots
    ADD CONSTRAINT generation_request_slots_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.profiles(id) ON DELETE CASCADE;


--
-- Name: generation_transactions generation_transactions_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.generation_transactions
    ADD CONSTRAINT generation_transactions_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.profiles(id) ON DELETE CASCADE;


--
-- Name: guest_memory_import_receipts_v1 guest_memory_import_receipts_v1_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.guest_memory_import_receipts_v1
    ADD CONSTRAINT guest_memory_import_receipts_v1_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.profiles(id) ON DELETE CASCADE;


--
-- Name: memories memories_language_pair_v1; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memories
    ADD CONSTRAINT memories_language_pair_v1 FOREIGN KEY (target_language, translation_language) REFERENCES public.language_capabilities_v1(target_language, translation_language);


--
-- Name: memories memories_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memories
    ADD CONSTRAINT memories_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.profiles(id) ON DELETE CASCADE;


--
-- Name: memory_deletion_receipts_v2 memory_deletion_receipts_v2_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memory_deletion_receipts_v2
    ADD CONSTRAINT memory_deletion_receipts_v2_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: memory_sentences memory_sentences_memory_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memory_sentences
    ADD CONSTRAINT memory_sentences_memory_id_fkey FOREIGN KEY (memory_id) REFERENCES public.memories(id) ON DELETE CASCADE;


--
-- Name: profiles profiles_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.profiles
    ADD CONSTRAINT profiles_id_fkey FOREIGN KEY (id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: purchase_ledger purchase_ledger_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.purchase_ledger
    ADD CONSTRAINT purchase_ledger_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: sentence_explanation_limits sentence_explanation_limits_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sentence_explanation_limits
    ADD CONSTRAINT sentence_explanation_limits_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: sentence_explanations sentence_explanations_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sentence_explanations
    ADD CONSTRAINT sentence_explanations_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: sentence_study_activations sentence_study_activations_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sentence_study_activations
    ADD CONSTRAINT sentence_study_activations_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: sentence_study_progress sentence_study_progress_sentence_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sentence_study_progress
    ADD CONSTRAINT sentence_study_progress_sentence_id_fkey FOREIGN KEY (sentence_id) REFERENCES public.memory_sentences(id) ON DELETE CASCADE;


--
-- Name: sentence_study_progress sentence_study_progress_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sentence_study_progress
    ADD CONSTRAINT sentence_study_progress_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.profiles(id) ON DELETE CASCADE;


--
-- Name: speech_request_limits speech_request_limits_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.speech_request_limits
    ADD CONSTRAINT speech_request_limits_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: study_event_receipts study_event_receipts_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.study_event_receipts
    ADD CONSTRAINT study_event_receipts_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: study_scene_sentence_reviews study_scene_sentence_reviews_scene_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.study_scene_sentence_reviews
    ADD CONSTRAINT study_scene_sentence_reviews_scene_id_fkey FOREIGN KEY (scene_id) REFERENCES public.study_scenes(id) ON DELETE CASCADE;


--
-- Name: study_scene_sentence_reviews study_scene_sentence_reviews_sentence_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.study_scene_sentence_reviews
    ADD CONSTRAINT study_scene_sentence_reviews_sentence_id_fkey FOREIGN KEY (sentence_id) REFERENCES public.memory_sentences(id) ON DELETE CASCADE;


--
-- Name: study_scene_sentence_reviews study_scene_sentence_reviews_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.study_scene_sentence_reviews
    ADD CONSTRAINT study_scene_sentence_reviews_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: study_scene_sentences study_scene_sentences_scene_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.study_scene_sentences
    ADD CONSTRAINT study_scene_sentences_scene_id_fkey FOREIGN KEY (scene_id) REFERENCES public.study_scenes(id) ON DELETE CASCADE;


--
-- Name: study_scene_sentences study_scene_sentences_sentence_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.study_scene_sentences
    ADD CONSTRAINT study_scene_sentences_sentence_id_fkey FOREIGN KEY (sentence_id) REFERENCES public.memory_sentences(id) ON DELETE CASCADE;


--
-- Name: study_scenes study_scenes_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.study_scenes
    ADD CONSTRAINT study_scenes_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: study_sessions study_sessions_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.study_sessions
    ADD CONSTRAINT study_sessions_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: study_topic_expression_examples study_topic_expression_examples_expression_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.study_topic_expression_examples
    ADD CONSTRAINT study_topic_expression_examples_expression_id_fkey FOREIGN KEY (expression_id) REFERENCES public.study_topic_expressions(id) ON DELETE CASCADE;


--
-- Name: study_topic_expression_examples study_topic_expression_examples_sentence_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.study_topic_expression_examples
    ADD CONSTRAINT study_topic_expression_examples_sentence_id_fkey FOREIGN KEY (sentence_id) REFERENCES public.memory_sentences(id) ON DELETE CASCADE;


--
-- Name: study_topic_expression_sets study_topic_expression_sets_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.study_topic_expression_sets
    ADD CONSTRAINT study_topic_expression_sets_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: study_topic_expressions study_topic_expressions_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.study_topic_expressions
    ADD CONSTRAINT study_topic_expressions_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: user_language_preferences user_language_preferences_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_language_preferences
    ADD CONSTRAINT user_language_preferences_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: user_learning_preferences user_learning_preferences_target_language_translation_lang_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_learning_preferences
    ADD CONSTRAINT user_learning_preferences_target_language_translation_lang_fkey FOREIGN KEY (target_language, translation_language) REFERENCES public.language_capabilities_v1(target_language, translation_language);


--
-- Name: user_learning_preferences user_learning_preferences_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_learning_preferences
    ADD CONSTRAINT user_learning_preferences_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: generation_jobs Users can read own generation jobs; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users can read own generation jobs" ON public.generation_jobs FOR SELECT TO authenticated USING ((auth.uid() = user_id));


--
-- Name: generation_jobs Users cannot write generation jobs directly; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Users cannot write generation jobs directly" ON public.generation_jobs TO authenticated USING (false) WITH CHECK (false);


--
-- Name: account_deletion_jobs; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.account_deletion_jobs ENABLE ROW LEVEL SECURITY;

--
-- Name: account_deletion_jobs account_deletion_jobs_insert_own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY account_deletion_jobs_insert_own ON public.account_deletion_jobs FOR INSERT TO authenticated WITH CHECK ((auth.uid() = user_id));


--
-- Name: account_deletion_jobs account_deletion_jobs_select_own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY account_deletion_jobs_select_own ON public.account_deletion_jobs FOR SELECT TO authenticated USING ((auth.uid() = user_id));


--
-- Name: album_flip_progress; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.album_flip_progress ENABLE ROW LEVEL SECURITY;

--
-- Name: album_flip_progress album_flip_progress_select_own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY album_flip_progress_select_own ON public.album_flip_progress FOR SELECT TO authenticated USING (((user_id = auth.uid()) AND (NOT COALESCE(((auth.jwt() ->> 'is_anonymous'::text))::boolean, false))));


--
-- Name: apple_auth_credentials; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.apple_auth_credentials ENABLE ROW LEVEL SECURITY;

--
-- Name: generation_jobs; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.generation_jobs ENABLE ROW LEVEL SECURITY;

--
-- Name: generation_transactions; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.generation_transactions ENABLE ROW LEVEL SECURITY;

--
-- Name: guest_generation_jobs; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.guest_generation_jobs ENABLE ROW LEVEL SECURITY;

--
-- Name: guest_generation_jobs guest_generation_jobs_insert_own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY guest_generation_jobs_insert_own ON public.guest_generation_jobs FOR INSERT TO authenticated WITH CHECK ((auth.uid() = user_id));


--
-- Name: guest_generation_jobs guest_generation_jobs_select_own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY guest_generation_jobs_select_own ON public.guest_generation_jobs FOR SELECT TO authenticated USING ((auth.uid() = user_id));


--
-- Name: guest_generation_jobs guest_generation_jobs_update_own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY guest_generation_jobs_update_own ON public.guest_generation_jobs FOR UPDATE TO authenticated USING ((auth.uid() = user_id)) WITH CHECK ((auth.uid() = user_id));


--
-- Name: guest_memory_import_receipts_v1; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.guest_memory_import_receipts_v1 ENABLE ROW LEVEL SECURITY;

--
-- Name: language_capabilities_v1; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.language_capabilities_v1 ENABLE ROW LEVEL SECURITY;

--
-- Name: memories; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.memories ENABLE ROW LEVEL SECURITY;

--
-- Name: memory_deletion_receipts_v2; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.memory_deletion_receipts_v2 ENABLE ROW LEVEL SECURITY;

--
-- Name: memory_image_cleanup_jobs_v2; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.memory_image_cleanup_jobs_v2 ENABLE ROW LEVEL SECURITY;

--
-- Name: memory_sentences; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.memory_sentences ENABLE ROW LEVEL SECURITY;

--
-- Name: study_topic_expression_examples multilingual_expression_owner_guard; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY multilingual_expression_owner_guard ON public.study_topic_expression_examples AS RESTRICTIVE TO authenticated, anon USING (public.legacy_topic_expression_allowed_v1(expression_id)) WITH CHECK (false);


--
-- Name: album_flip_progress multilingual_legacy_guard; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY multilingual_legacy_guard ON public.album_flip_progress AS RESTRICTIVE TO authenticated, anon USING (((EXISTS ( SELECT 1
   FROM (public.memory_sentences s
     JOIN public.memories m ON ((m.id = s.memory_id)))
  WHERE ((s.id = album_flip_progress.sentence_id) AND (m.user_id = auth.uid())))) AND (user_id = auth.uid()) AND (EXISTS ( SELECT 1
   FROM public.memory_sentences s
  WHERE ((s.id = album_flip_progress.sentence_id) AND (s.memory_id = album_flip_progress.memory_id)))))) WITH CHECK (((EXISTS ( SELECT 1
   FROM (public.memory_sentences s
     JOIN public.memories m ON ((m.id = s.memory_id)))
  WHERE ((s.id = album_flip_progress.sentence_id) AND (m.user_id = auth.uid())))) AND (user_id = auth.uid()) AND (EXISTS ( SELECT 1
   FROM public.memory_sentences s
  WHERE ((s.id = album_flip_progress.sentence_id) AND (s.memory_id = album_flip_progress.memory_id))))));


--
-- Name: generation_jobs multilingual_legacy_guard; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY multilingual_legacy_guard ON public.generation_jobs AS RESTRICTIVE TO authenticated, anon USING (((user_id = auth.uid()) AND (COALESCE((to_jsonb(generation_jobs.*) ->> 'request_schema_version'::text), '1'::text) = '1'::text) AND (((COALESCE((to_jsonb(generation_jobs.*) -> 'generation_spec'::text), 'null'::jsonb) = 'null'::jsonb) AND (COALESCE((to_jsonb(generation_jobs.*) ->> 'request_schema_version'::text), '1'::text) = '1'::text)) OR ((to_jsonb(generation_jobs.*) -> 'generation_spec'::text) @> '{"schemaVersion": 1, "catalogVersion": 1, "targetLanguage": "en", "teachingLocale": "en-US", "generationFormat": "dual_tabs_v1", "translationLanguage": "zh-Hans"}'::jsonb)) AND ((memory_id IS NULL) OR (EXISTS ( SELECT 1
   FROM public.memories m
  WHERE ((m.id = generation_jobs.memory_id) AND (m.user_id = auth.uid()))))))) WITH CHECK (((user_id = auth.uid()) AND (COALESCE((to_jsonb(generation_jobs.*) ->> 'request_schema_version'::text), '1'::text) = '1'::text) AND (((COALESCE((to_jsonb(generation_jobs.*) -> 'generation_spec'::text), 'null'::jsonb) = 'null'::jsonb) AND (COALESCE((to_jsonb(generation_jobs.*) ->> 'request_schema_version'::text), '1'::text) = '1'::text)) OR ((to_jsonb(generation_jobs.*) -> 'generation_spec'::text) @> '{"schemaVersion": 1, "catalogVersion": 1, "targetLanguage": "en", "teachingLocale": "en-US", "generationFormat": "dual_tabs_v1", "translationLanguage": "zh-Hans"}'::jsonb)) AND ((memory_id IS NULL) OR (EXISTS ( SELECT 1
   FROM public.memories m
  WHERE ((m.id = generation_jobs.memory_id) AND (m.user_id = auth.uid())))))));


--
-- Name: guest_generation_jobs multilingual_legacy_guard; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY multilingual_legacy_guard ON public.guest_generation_jobs AS RESTRICTIVE TO authenticated, anon USING (((user_id = auth.uid()) AND (COALESCE((to_jsonb(guest_generation_jobs.*) ->> 'request_schema_version'::text), '1'::text) = '1'::text) AND (((COALESCE((to_jsonb(guest_generation_jobs.*) -> 'generation_spec'::text), 'null'::jsonb) = 'null'::jsonb) AND (COALESCE((to_jsonb(guest_generation_jobs.*) ->> 'request_schema_version'::text), '1'::text) = '1'::text)) OR ((to_jsonb(guest_generation_jobs.*) -> 'generation_spec'::text) @> '{"schemaVersion": 1, "catalogVersion": 1, "targetLanguage": "en", "teachingLocale": "en-US", "generationFormat": "dual_tabs_v1", "translationLanguage": "zh-Hans"}'::jsonb)))) WITH CHECK (((user_id = auth.uid()) AND (COALESCE((to_jsonb(guest_generation_jobs.*) ->> 'request_schema_version'::text), '1'::text) = '1'::text) AND (((COALESCE((to_jsonb(guest_generation_jobs.*) -> 'generation_spec'::text), 'null'::jsonb) = 'null'::jsonb) AND (COALESCE((to_jsonb(guest_generation_jobs.*) ->> 'request_schema_version'::text), '1'::text) = '1'::text)) OR ((to_jsonb(guest_generation_jobs.*) -> 'generation_spec'::text) @> '{"schemaVersion": 1, "catalogVersion": 1, "targetLanguage": "en", "teachingLocale": "en-US", "generationFormat": "dual_tabs_v1", "translationLanguage": "zh-Hans"}'::jsonb))));


--
-- Name: memories multilingual_legacy_guard; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY multilingual_legacy_guard ON public.memories AS RESTRICTIVE TO authenticated, anon USING (((user_id = auth.uid()) AND public.is_legacy_content_v1(target_language, translation_language, teaching_locale))) WITH CHECK (((user_id = auth.uid()) AND public.is_legacy_content_v1(target_language, translation_language, teaching_locale)));


--
-- Name: memory_sentences multilingual_legacy_guard; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY multilingual_legacy_guard ON public.memory_sentences AS RESTRICTIVE TO authenticated, anon USING ((EXISTS ( SELECT 1
   FROM public.memories m
  WHERE ((m.id = memory_sentences.memory_id) AND (m.user_id = auth.uid()))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM public.memories m
  WHERE ((m.id = memory_sentences.memory_id) AND (m.user_id = auth.uid())))));


--
-- Name: sentence_study_progress multilingual_legacy_guard; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY multilingual_legacy_guard ON public.sentence_study_progress AS RESTRICTIVE TO authenticated, anon USING (((EXISTS ( SELECT 1
   FROM (public.memory_sentences s
     JOIN public.memories m ON ((m.id = s.memory_id)))
  WHERE ((s.id = sentence_study_progress.sentence_id) AND (m.user_id = auth.uid())))) AND (user_id = auth.uid()))) WITH CHECK (((EXISTS ( SELECT 1
   FROM (public.memory_sentences s
     JOIN public.memories m ON ((m.id = s.memory_id)))
  WHERE ((s.id = sentence_study_progress.sentence_id) AND (m.user_id = auth.uid())))) AND (user_id = auth.uid())));


--
-- Name: study_scene_sentence_reviews multilingual_legacy_guard; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY multilingual_legacy_guard ON public.study_scene_sentence_reviews AS RESTRICTIVE TO authenticated, anon USING (((EXISTS ( SELECT 1
   FROM (public.memory_sentences s
     JOIN public.memories m ON ((m.id = s.memory_id)))
  WHERE ((s.id = study_scene_sentence_reviews.sentence_id) AND (m.user_id = auth.uid())))) AND (user_id = auth.uid()) AND (EXISTS ( SELECT 1
   FROM public.study_scenes scene
  WHERE ((scene.id = study_scene_sentence_reviews.scene_id) AND (scene.user_id = auth.uid())))))) WITH CHECK (((EXISTS ( SELECT 1
   FROM (public.memory_sentences s
     JOIN public.memories m ON ((m.id = s.memory_id)))
  WHERE ((s.id = study_scene_sentence_reviews.sentence_id) AND (m.user_id = auth.uid())))) AND (user_id = auth.uid()) AND (EXISTS ( SELECT 1
   FROM public.study_scenes scene
  WHERE ((scene.id = study_scene_sentence_reviews.scene_id) AND (scene.user_id = auth.uid()))))));


--
-- Name: study_scene_sentences multilingual_legacy_guard; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY multilingual_legacy_guard ON public.study_scene_sentences AS RESTRICTIVE TO authenticated, anon USING (((EXISTS ( SELECT 1
   FROM (public.memory_sentences s
     JOIN public.memories m ON ((m.id = s.memory_id)))
  WHERE ((s.id = study_scene_sentences.sentence_id) AND (m.user_id = auth.uid())))) AND (EXISTS ( SELECT 1
   FROM public.study_scenes scene
  WHERE ((scene.id = study_scene_sentences.scene_id) AND (scene.user_id = auth.uid())))))) WITH CHECK (((EXISTS ( SELECT 1
   FROM (public.memory_sentences s
     JOIN public.memories m ON ((m.id = s.memory_id)))
  WHERE ((s.id = study_scene_sentences.sentence_id) AND (m.user_id = auth.uid())))) AND (EXISTS ( SELECT 1
   FROM public.study_scenes scene
  WHERE ((scene.id = study_scene_sentences.scene_id) AND (scene.user_id = auth.uid()))))));


--
-- Name: study_topic_expression_examples multilingual_legacy_guard; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY multilingual_legacy_guard ON public.study_topic_expression_examples AS RESTRICTIVE TO authenticated, anon USING ((EXISTS ( SELECT 1
   FROM (public.memory_sentences s
     JOIN public.memories m ON ((m.id = s.memory_id)))
  WHERE ((s.id = study_topic_expression_examples.sentence_id) AND (m.user_id = auth.uid()))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM (public.memory_sentences s
     JOIN public.memories m ON ((m.id = s.memory_id)))
  WHERE ((s.id = study_topic_expression_examples.sentence_id) AND (m.user_id = auth.uid())))));


--
-- Name: study_topic_expression_sets multilingual_legacy_guard; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY multilingual_legacy_guard ON public.study_topic_expression_sets AS RESTRICTIVE TO authenticated, anon USING (((user_id = auth.uid()) AND public.legacy_topic_cache_allowed_v1(topic_key))) WITH CHECK (false);


--
-- Name: study_topic_expressions multilingual_legacy_guard; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY multilingual_legacy_guard ON public.study_topic_expressions AS RESTRICTIVE TO authenticated, anon USING (((user_id = auth.uid()) AND public.legacy_topic_expression_allowed_v1(id))) WITH CHECK (false);


--
-- Name: sentence_explanation_limits multilingual_server_only_guard; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY multilingual_server_only_guard ON public.sentence_explanation_limits AS RESTRICTIVE TO authenticated, anon USING (false) WITH CHECK (false);


--
-- Name: sentence_explanations multilingual_server_only_guard; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY multilingual_server_only_guard ON public.sentence_explanations AS RESTRICTIVE TO authenticated, anon USING (false) WITH CHECK (false);


--
-- Name: profiles; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;

--
-- Name: purchase_ledger; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.purchase_ledger ENABLE ROW LEVEL SECURITY;

--
-- Name: purchase_ledger purchase_ledger_insert_own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY purchase_ledger_insert_own ON public.purchase_ledger FOR INSERT TO authenticated WITH CHECK ((auth.uid() = user_id));


--
-- Name: purchase_ledger purchase_ledger_select_own; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY purchase_ledger_select_own ON public.purchase_ledger FOR SELECT TO authenticated USING ((auth.uid() = user_id));


--
-- Name: sentence_explanation_limits; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.sentence_explanation_limits ENABLE ROW LEVEL SECURITY;

--
-- Name: sentence_explanations; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.sentence_explanations ENABLE ROW LEVEL SECURITY;

--
-- Name: sentence_study_activations; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.sentence_study_activations ENABLE ROW LEVEL SECURITY;

--
-- Name: sentence_study_progress; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.sentence_study_progress ENABLE ROW LEVEL SECURITY;

--
-- Name: speech_request_limits; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.speech_request_limits ENABLE ROW LEVEL SECURITY;

--
-- Name: study_event_receipts; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.study_event_receipts ENABLE ROW LEVEL SECURITY;

--
-- Name: study_scene_sentence_reviews; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.study_scene_sentence_reviews ENABLE ROW LEVEL SECURITY;

--
-- Name: study_scene_sentences; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.study_scene_sentences ENABLE ROW LEVEL SECURITY;

--
-- Name: study_scene_sentences study_scene_sentences_owner_read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY study_scene_sentences_owner_read ON public.study_scene_sentences FOR SELECT USING ((EXISTS ( SELECT 1
   FROM public.study_scenes scene
  WHERE ((scene.id = study_scene_sentences.scene_id) AND (scene.user_id = auth.uid())))));


--
-- Name: study_scenes; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.study_scenes ENABLE ROW LEVEL SECURITY;

--
-- Name: study_scenes study_scenes_owner_access; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY study_scenes_owner_access ON public.study_scenes USING ((auth.uid() = user_id)) WITH CHECK ((auth.uid() = user_id));


--
-- Name: study_sessions; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.study_sessions ENABLE ROW LEVEL SECURITY;

--
-- Name: study_topic_expression_examples; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.study_topic_expression_examples ENABLE ROW LEVEL SECURITY;

--
-- Name: study_topic_expression_examples study_topic_expression_examples_owner_read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY study_topic_expression_examples_owner_read ON public.study_topic_expression_examples FOR SELECT USING ((EXISTS ( SELECT 1
   FROM public.study_topic_expressions expression
  WHERE ((expression.id = study_topic_expression_examples.expression_id) AND (expression.user_id = auth.uid())))));


--
-- Name: study_topic_expression_sets; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.study_topic_expression_sets ENABLE ROW LEVEL SECURITY;

--
-- Name: study_topic_expression_sets study_topic_expression_sets_owner_read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY study_topic_expression_sets_owner_read ON public.study_topic_expression_sets FOR SELECT USING ((auth.uid() = user_id));


--
-- Name: study_topic_expressions; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.study_topic_expressions ENABLE ROW LEVEL SECURITY;

--
-- Name: study_topic_expressions study_topic_expressions_owner_read; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY study_topic_expressions_owner_read ON public.study_topic_expressions FOR SELECT USING ((auth.uid() = user_id));


--
-- Name: user_language_preferences; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.user_language_preferences ENABLE ROW LEVEL SECURITY;

--
-- Name: user_learning_preferences; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.user_learning_preferences ENABLE ROW LEVEL SECURITY;

--
-- Name: profiles users can insert own profile; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "users can insert own profile" ON public.profiles FOR INSERT WITH CHECK ((auth.uid() = id));


--
-- Name: generation_transactions users can insert own transactions; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "users can insert own transactions" ON public.generation_transactions FOR INSERT WITH CHECK ((auth.uid() = user_id));


--
-- Name: memories users can manage own memories; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "users can manage own memories" ON public.memories USING ((auth.uid() = user_id)) WITH CHECK ((auth.uid() = user_id));


--
-- Name: memory_sentences users can manage own memory sentences; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "users can manage own memory sentences" ON public.memory_sentences USING ((EXISTS ( SELECT 1
   FROM public.memories m
  WHERE ((m.id = memory_sentences.memory_id) AND (m.user_id = auth.uid()))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM public.memories m
  WHERE ((m.id = memory_sentences.memory_id) AND (m.user_id = auth.uid())))));


--
-- Name: sentence_study_progress users can manage own sentence study progress; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "users can manage own sentence study progress" ON public.sentence_study_progress TO authenticated USING ((auth.uid() = user_id)) WITH CHECK ((auth.uid() = user_id));


--
-- Name: profiles users can read own profile; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "users can read own profile" ON public.profiles FOR SELECT USING ((auth.uid() = id));


--
-- Name: generation_transactions users can read own transactions; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "users can read own transactions" ON public.generation_transactions FOR SELECT USING ((auth.uid() = user_id));


--
-- Name: profiles users can update own profile; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "users can update own profile" ON public.profiles FOR UPDATE USING ((auth.uid() = id)) WITH CHECK ((auth.uid() = id));


--
-- Name: SCHEMA public; Type: ACL; Schema: -; Owner: -
--

GRANT USAGE ON SCHEMA public TO anon;
GRANT USAGE ON SCHEMA public TO authenticated;
GRANT USAGE ON SCHEMA public TO service_role;


--
-- Name: FUNCTION _begin_study_session_v2(p_session_id uuid, p_target_language text, p_scope text, p_limit integer, p_mode text, p_time_zone text, p_legacy boolean); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public._begin_study_session_v2(p_session_id uuid, p_target_language text, p_scope text, p_limit integer, p_mode text, p_time_zone text, p_legacy boolean) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public._begin_study_session_v2(p_session_id uuid, p_target_language text, p_scope text, p_limit integer, p_mode text, p_time_zone text, p_legacy boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION public._begin_study_session_v2(p_session_id uuid, p_target_language text, p_scope text, p_limit integer, p_mode text, p_time_zone text, p_legacy boolean) TO service_role;


--
-- Name: FUNCTION _merge_local_study_progress_v1(p_items jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public._merge_local_study_progress_v1(p_items jsonb) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public._merge_local_study_progress_v1(p_items jsonb) FROM PUBLIC;


--
-- Name: FUNCTION _merge_study_progress_v2(p_items jsonb, p_legacy boolean); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public._merge_study_progress_v2(p_items jsonb, p_legacy boolean) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public._merge_study_progress_v2(p_items jsonb, p_legacy boolean) FROM PUBLIC;


--
-- Name: FUNCTION _study_candidates_v2(p_language text, p_scope text, p_mode text, p_zone text, p_legacy boolean); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public._study_candidates_v2(p_language text, p_scope text, p_mode text, p_zone text, p_legacy boolean) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public._study_candidates_v2(p_language text, p_scope text, p_mode text, p_zone text, p_legacy boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION public._study_candidates_v2(p_language text, p_scope text, p_mode text, p_zone text, p_legacy boolean) TO service_role;


--
-- Name: FUNCTION _study_lock_v2(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public._study_lock_v2() FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public._study_lock_v2() FROM PUBLIC;
GRANT ALL ON FUNCTION public._study_lock_v2() TO service_role;


--
-- Name: FUNCTION _study_remaining_v2(p_zone text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public._study_remaining_v2(p_zone text) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public._study_remaining_v2(p_zone text) FROM PUBLIC;
GRANT ALL ON FUNCTION public._study_remaining_v2(p_zone text) TO service_role;


--
-- Name: FUNCTION _study_zone_v2(p_zone text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public._study_zone_v2(p_zone text) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public._study_zone_v2(p_zone text) FROM PUBLIC;
GRANT ALL ON FUNCTION public._study_zone_v2(p_zone text) TO service_role;


--
-- Name: FUNCTION authorize_memory_image_cleanup_v2(p_job_id uuid, p_lease_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.authorize_memory_image_cleanup_v2(p_job_id uuid, p_lease_id uuid) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.authorize_memory_image_cleanup_v2(p_job_id uuid, p_lease_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.authorize_memory_image_cleanup_v2(p_job_id uuid, p_lease_id uuid) TO service_role;


--
-- Name: FUNCTION begin_direct_study_session_v2(p_session_id uuid, p_sentence_id uuid, p_time_zone text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.begin_direct_study_session_v2(p_session_id uuid, p_sentence_id uuid, p_time_zone text) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.begin_direct_study_session_v2(p_session_id uuid, p_sentence_id uuid, p_time_zone text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.begin_direct_study_session_v2(p_session_id uuid, p_sentence_id uuid, p_time_zone text) TO authenticated;
GRANT ALL ON FUNCTION public.begin_direct_study_session_v2(p_session_id uuid, p_sentence_id uuid, p_time_zone text) TO service_role;


--
-- Name: FUNCTION begin_study_session_v2(p_session_id uuid, p_target_language text, p_scope text, p_limit integer, p_mode text, p_time_zone text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.begin_study_session_v2(p_session_id uuid, p_target_language text, p_scope text, p_limit integer, p_mode text, p_time_zone text) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.begin_study_session_v2(p_session_id uuid, p_target_language text, p_scope text, p_limit integer, p_mode text, p_time_zone text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.begin_study_session_v2(p_session_id uuid, p_target_language text, p_scope text, p_limit integer, p_mode text, p_time_zone text) TO authenticated;
GRANT ALL ON FUNCTION public.begin_study_session_v2(p_session_id uuid, p_target_language text, p_scope text, p_limit integer, p_mode text, p_time_zone text) TO service_role;


--
-- Name: FUNCTION claim_generation_job(p_user_id uuid, p_request_id uuid, p_is_anonymous boolean, p_image_path text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.claim_generation_job(p_user_id uuid, p_request_id uuid, p_is_anonymous boolean, p_image_path text) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.claim_generation_job(p_user_id uuid, p_request_id uuid, p_is_anonymous boolean, p_image_path text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.claim_generation_job(p_user_id uuid, p_request_id uuid, p_is_anonymous boolean, p_image_path text) TO service_role;


--
-- Name: FUNCTION claim_generation_job_legacy_internal(p_user_id uuid, p_request_id uuid, p_is_anonymous boolean, p_image_path text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.claim_generation_job_legacy_internal(p_user_id uuid, p_request_id uuid, p_is_anonymous boolean, p_image_path text) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.claim_generation_job_legacy_internal(p_user_id uuid, p_request_id uuid, p_is_anonymous boolean, p_image_path text) FROM PUBLIC;


--
-- Name: FUNCTION claim_generation_job_v3(p_user_id uuid, p_request_id uuid, p_is_anonymous boolean, p_image_path text, p_generation_spec jsonb, p_request_fingerprint text, p_generation_policy jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.claim_generation_job_v3(p_user_id uuid, p_request_id uuid, p_is_anonymous boolean, p_image_path text, p_generation_spec jsonb, p_request_fingerprint text, p_generation_policy jsonb) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.claim_generation_job_v3(p_user_id uuid, p_request_id uuid, p_is_anonymous boolean, p_image_path text, p_generation_spec jsonb, p_request_fingerprint text, p_generation_policy jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.claim_generation_job_v3(p_user_id uuid, p_request_id uuid, p_is_anonymous boolean, p_image_path text, p_generation_spec jsonb, p_request_fingerprint text, p_generation_policy jsonb) TO service_role;


--
-- Name: TABLE memory_image_cleanup_jobs_v2; Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON TABLE public.memory_image_cleanup_jobs_v2 FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE public.memory_image_cleanup_jobs_v2 TO service_role;


--
-- Name: FUNCTION claim_memory_image_cleanup_v2(p_limit integer); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.claim_memory_image_cleanup_v2(p_limit integer) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.claim_memory_image_cleanup_v2(p_limit integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.claim_memory_image_cleanup_v2(p_limit integer) TO service_role;


--
-- Name: FUNCTION claim_sentence_explanation(p_user_id uuid, p_fingerprint text, p_generate boolean); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.claim_sentence_explanation(p_user_id uuid, p_fingerprint text, p_generate boolean) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.claim_sentence_explanation(p_user_id uuid, p_fingerprint text, p_generate boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION public.claim_sentence_explanation(p_user_id uuid, p_fingerprint text, p_generate boolean) TO service_role;


--
-- Name: FUNCTION confirm_purchase_atomically(p_user_id uuid, p_transaction_id text, p_product_id text, p_credits integer); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.confirm_purchase_atomically(p_user_id uuid, p_transaction_id text, p_product_id text, p_credits integer) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.confirm_purchase_atomically(p_user_id uuid, p_transaction_id text, p_product_id text, p_credits integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.confirm_purchase_atomically(p_user_id uuid, p_transaction_id text, p_product_id text, p_credits integer) TO service_role;


--
-- Name: FUNCTION consume_speech_request(p_user_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.consume_speech_request(p_user_id uuid) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.consume_speech_request(p_user_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.consume_speech_request(p_user_id uuid) TO service_role;


--
-- Name: FUNCTION cosine_similarity_real_arrays(p_left real[], p_right real[]); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.cosine_similarity_real_arrays(p_left real[], p_right real[]) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.cosine_similarity_real_arrays(p_left real[], p_right real[]) FROM PUBLIC;
GRANT ALL ON FUNCTION public.cosine_similarity_real_arrays(p_left real[], p_right real[]) TO service_role;


--
-- Name: FUNCTION count_mastered_sentences(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.count_mastered_sentences() FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.count_mastered_sentences() FROM PUBLIC;
GRANT ALL ON FUNCTION public.count_mastered_sentences() TO authenticated;
GRANT ALL ON FUNCTION public.count_mastered_sentences() TO service_role;


--
-- Name: FUNCTION count_sentence_studied_today(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.count_sentence_studied_today() FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.count_sentence_studied_today() FROM PUBLIC;
GRANT ALL ON FUNCTION public.count_sentence_studied_today() TO authenticated;
GRANT ALL ON FUNCTION public.count_sentence_studied_today() TO service_role;


--
-- Name: FUNCTION count_sentence_studied_today_reviewable(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.count_sentence_studied_today_reviewable() FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.count_sentence_studied_today_reviewable() FROM PUBLIC;
GRANT ALL ON FUNCTION public.count_sentence_studied_today_reviewable() TO authenticated;
GRANT ALL ON FUNCTION public.count_sentence_studied_today_reviewable() TO service_role;


--
-- Name: FUNCTION count_sentence_study_queue(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.count_sentence_study_queue() FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.count_sentence_study_queue() FROM PUBLIC;
GRANT ALL ON FUNCTION public.count_sentence_study_queue() TO authenticated;
GRANT ALL ON FUNCTION public.count_sentence_study_queue() TO service_role;


--
-- Name: FUNCTION delete_memory_v2(p_memory_id uuid, p_operation_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.delete_memory_v2(p_memory_id uuid, p_operation_id uuid) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.delete_memory_v2(p_memory_id uuid, p_operation_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.delete_memory_v2(p_memory_id uuid, p_operation_id uuid) TO authenticated;


--
-- Name: FUNCTION finalize_authenticated_generation(p_user_id uuid, p_memory_id uuid, p_image_path text, p_created_at timestamp with time zone, p_provider text, p_sentences jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.finalize_authenticated_generation(p_user_id uuid, p_memory_id uuid, p_image_path text, p_created_at timestamp with time zone, p_provider text, p_sentences jsonb) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.finalize_authenticated_generation(p_user_id uuid, p_memory_id uuid, p_image_path text, p_created_at timestamp with time zone, p_provider text, p_sentences jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.finalize_authenticated_generation(p_user_id uuid, p_memory_id uuid, p_image_path text, p_created_at timestamp with time zone, p_provider text, p_sentences jsonb) TO service_role;


--
-- Name: FUNCTION finalize_authenticated_generation(p_user_id uuid, p_memory_id uuid, p_client_request_id uuid, p_image_path text, p_created_at timestamp with time zone, p_provider text, p_sentences jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.finalize_authenticated_generation(p_user_id uuid, p_memory_id uuid, p_client_request_id uuid, p_image_path text, p_created_at timestamp with time zone, p_provider text, p_sentences jsonb) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.finalize_authenticated_generation(p_user_id uuid, p_memory_id uuid, p_client_request_id uuid, p_image_path text, p_created_at timestamp with time zone, p_provider text, p_sentences jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.finalize_authenticated_generation(p_user_id uuid, p_memory_id uuid, p_client_request_id uuid, p_image_path text, p_created_at timestamp with time zone, p_provider text, p_sentences jsonb) TO service_role;


--
-- Name: FUNCTION finalize_authenticated_generation(p_user_id uuid, p_memory_id uuid, p_client_request_id uuid, p_image_path text, p_created_at timestamp with time zone, p_provider text, p_sentences jsonb, p_tags text[]); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.finalize_authenticated_generation(p_user_id uuid, p_memory_id uuid, p_client_request_id uuid, p_image_path text, p_created_at timestamp with time zone, p_provider text, p_sentences jsonb, p_tags text[]) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.finalize_authenticated_generation(p_user_id uuid, p_memory_id uuid, p_client_request_id uuid, p_image_path text, p_created_at timestamp with time zone, p_provider text, p_sentences jsonb, p_tags text[]) FROM PUBLIC;
GRANT ALL ON FUNCTION public.finalize_authenticated_generation(p_user_id uuid, p_memory_id uuid, p_client_request_id uuid, p_image_path text, p_created_at timestamp with time zone, p_provider text, p_sentences jsonb, p_tags text[]) TO service_role;


--
-- Name: FUNCTION finalize_generation_job_v3(p_user_id uuid, p_request_id uuid, p_is_anonymous boolean, p_request_fingerprint text, p_memory jsonb, p_provider text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.finalize_generation_job_v3(p_user_id uuid, p_request_id uuid, p_is_anonymous boolean, p_request_fingerprint text, p_memory jsonb, p_provider text) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.finalize_generation_job_v3(p_user_id uuid, p_request_id uuid, p_is_anonymous boolean, p_request_fingerprint text, p_memory jsonb, p_provider text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.finalize_generation_job_v3(p_user_id uuid, p_request_id uuid, p_is_anonymous boolean, p_request_fingerprint text, p_memory jsonb, p_provider text) TO service_role;


--
-- Name: FUNCTION finalize_guest_generation(p_user_id uuid, p_guest_job_id uuid, p_completed_at timestamp with time zone, p_provider text, p_sentences jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.finalize_guest_generation(p_user_id uuid, p_guest_job_id uuid, p_completed_at timestamp with time zone, p_provider text, p_sentences jsonb) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.finalize_guest_generation(p_user_id uuid, p_guest_job_id uuid, p_completed_at timestamp with time zone, p_provider text, p_sentences jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.finalize_guest_generation(p_user_id uuid, p_guest_job_id uuid, p_completed_at timestamp with time zone, p_provider text, p_sentences jsonb) TO service_role;


--
-- Name: FUNCTION finalize_guest_generation(p_user_id uuid, p_guest_job_id uuid, p_completed_at timestamp with time zone, p_provider text, p_sentences jsonb, p_tags text[]); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.finalize_guest_generation(p_user_id uuid, p_guest_job_id uuid, p_completed_at timestamp with time zone, p_provider text, p_sentences jsonb, p_tags text[]) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.finalize_guest_generation(p_user_id uuid, p_guest_job_id uuid, p_completed_at timestamp with time zone, p_provider text, p_sentences jsonb, p_tags text[]) FROM PUBLIC;
GRANT ALL ON FUNCTION public.finalize_guest_generation(p_user_id uuid, p_guest_job_id uuid, p_completed_at timestamp with time zone, p_provider text, p_sentences jsonb, p_tags text[]) TO service_role;


--
-- Name: FUNCTION finalize_guest_generation(p_user_id uuid, p_guest_job_id uuid, p_client_request_id uuid, p_completed_at timestamp with time zone, p_provider text, p_sentences jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.finalize_guest_generation(p_user_id uuid, p_guest_job_id uuid, p_client_request_id uuid, p_completed_at timestamp with time zone, p_provider text, p_sentences jsonb) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.finalize_guest_generation(p_user_id uuid, p_guest_job_id uuid, p_client_request_id uuid, p_completed_at timestamp with time zone, p_provider text, p_sentences jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.finalize_guest_generation(p_user_id uuid, p_guest_job_id uuid, p_client_request_id uuid, p_completed_at timestamp with time zone, p_provider text, p_sentences jsonb) TO service_role;


--
-- Name: FUNCTION finish_memory_image_cleanup_v2(p_job_id uuid, p_lease_id uuid, p_success boolean, p_error text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.finish_memory_image_cleanup_v2(p_job_id uuid, p_lease_id uuid, p_success boolean, p_error text) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.finish_memory_image_cleanup_v2(p_job_id uuid, p_lease_id uuid, p_success boolean, p_error text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.finish_memory_image_cleanup_v2(p_job_id uuid, p_lease_id uuid, p_success boolean, p_error text) TO service_role;


--
-- Name: FUNCTION finish_sentence_explanation(p_user_id uuid, p_fingerprint text, p_claim_id uuid, p_content jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.finish_sentence_explanation(p_user_id uuid, p_fingerprint text, p_claim_id uuid, p_content jsonb) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.finish_sentence_explanation(p_user_id uuid, p_fingerprint text, p_claim_id uuid, p_content jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.finish_sentence_explanation(p_user_id uuid, p_fingerprint text, p_claim_id uuid, p_content jsonb) TO service_role;


--
-- Name: FUNCTION finish_sentence_explanation_v2(p_user_id uuid, p_fingerprint text, p_claim_id uuid, p_content jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.finish_sentence_explanation_v2(p_user_id uuid, p_fingerprint text, p_claim_id uuid, p_content jsonb) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.finish_sentence_explanation_v2(p_user_id uuid, p_fingerprint text, p_claim_id uuid, p_content jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.finish_sentence_explanation_v2(p_user_id uuid, p_fingerprint text, p_claim_id uuid, p_content jsonb) TO service_role;


--
-- Name: TABLE album_flip_progress; Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON TABLE public.album_flip_progress FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE public.album_flip_progress TO service_role;
GRANT SELECT ON TABLE public.album_flip_progress TO authenticated;


--
-- Name: FUNCTION get_album_flip_progress_v2(p_target_language text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.get_album_flip_progress_v2(p_target_language text) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.get_album_flip_progress_v2(p_target_language text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_album_flip_progress_v2(p_target_language text) TO authenticated;


--
-- Name: FUNCTION get_language_capabilities_v1(p_catalog_version integer); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.get_language_capabilities_v1(p_catalog_version integer) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.get_language_capabilities_v1(p_catalog_version integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_language_capabilities_v1(p_catalog_version integer) TO authenticated;


--
-- Name: FUNCTION get_learning_preferences_v1(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.get_learning_preferences_v1() FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.get_learning_preferences_v1() FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_learning_preferences_v1() TO authenticated;


--
-- Name: FUNCTION get_memory_v2(p_memory_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.get_memory_v2(p_memory_id uuid) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.get_memory_v2(p_memory_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_memory_v2(p_memory_id uuid) TO authenticated;


--
-- Name: FUNCTION get_sentence_studied_today_queue(p_limit integer); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.get_sentence_studied_today_queue(p_limit integer) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.get_sentence_studied_today_queue(p_limit integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_sentence_studied_today_queue(p_limit integer) TO authenticated;
GRANT ALL ON FUNCTION public.get_sentence_studied_today_queue(p_limit integer) TO service_role;


--
-- Name: TABLE sentence_study_progress; Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON TABLE public.sentence_study_progress FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE ON TABLE public.sentence_study_progress TO anon;
GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE ON TABLE public.sentence_study_progress TO authenticated;
GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE public.sentence_study_progress TO service_role;


--
-- Name: FUNCTION get_sentence_study_progress_v2(p_target_language text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.get_sentence_study_progress_v2(p_target_language text) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.get_sentence_study_progress_v2(p_target_language text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_sentence_study_progress_v2(p_target_language text) TO authenticated;
GRANT ALL ON FUNCTION public.get_sentence_study_progress_v2(p_target_language text) TO service_role;


--
-- Name: FUNCTION get_sentence_study_queue(p_limit integer); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.get_sentence_study_queue(p_limit integer) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.get_sentence_study_queue(p_limit integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_sentence_study_queue(p_limit integer) TO authenticated;
GRANT ALL ON FUNCTION public.get_sentence_study_queue(p_limit integer) TO service_role;


--
-- Name: FUNCTION get_studied_today_scene_queue(p_scene_id uuid, p_limit integer); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.get_studied_today_scene_queue(p_scene_id uuid, p_limit integer) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.get_studied_today_scene_queue(p_scene_id uuid, p_limit integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_studied_today_scene_queue(p_scene_id uuid, p_limit integer) TO authenticated;
GRANT ALL ON FUNCTION public.get_studied_today_scene_queue(p_scene_id uuid, p_limit integer) TO service_role;


--
-- Name: FUNCTION get_study_overview_v2(p_target_language text, p_scope text, p_time_zone text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.get_study_overview_v2(p_target_language text, p_scope text, p_time_zone text) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.get_study_overview_v2(p_target_language text, p_scope text, p_time_zone text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_study_overview_v2(p_target_language text, p_scope text, p_time_zone text) TO authenticated;
GRANT ALL ON FUNCTION public.get_study_overview_v2(p_target_language text, p_scope text, p_time_zone text) TO service_role;


--
-- Name: FUNCTION get_study_topic_expressions(p_topic_key text, p_source_fingerprint text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.get_study_topic_expressions(p_topic_key text, p_source_fingerprint text) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.get_study_topic_expressions(p_topic_key text, p_source_fingerprint text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_study_topic_expressions(p_topic_key text, p_source_fingerprint text) TO authenticated;
GRANT ALL ON FUNCTION public.get_study_topic_expressions(p_topic_key text, p_source_fingerprint text) TO service_role;


--
-- Name: FUNCTION get_study_topic_source_sentences(p_topic_key text, p_limit integer); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.get_study_topic_source_sentences(p_topic_key text, p_limit integer) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.get_study_topic_source_sentences(p_topic_key text, p_limit integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_study_topic_source_sentences(p_topic_key text, p_limit integer) TO authenticated;
GRANT ALL ON FUNCTION public.get_study_topic_source_sentences(p_topic_key text, p_limit integer) TO service_role;


--
-- Name: FUNCTION guard_memory_image_lifecycle_v2(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.guard_memory_image_lifecycle_v2() FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.guard_memory_image_lifecycle_v2() FROM PUBLIC;
GRANT ALL ON FUNCTION public.guard_memory_image_lifecycle_v2() TO service_role;


--
-- Name: FUNCTION immutable_memory_identity_v1(p_memory jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.immutable_memory_identity_v1(p_memory jsonb) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.immutable_memory_identity_v1(p_memory jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.immutable_memory_identity_v1(p_memory jsonb) TO service_role;


--
-- Name: FUNCTION import_guest_memory_v1(p_user_id uuid, p_guest_user_id uuid, p_memory jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.import_guest_memory_v1(p_user_id uuid, p_guest_user_id uuid, p_memory jsonb) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.import_guest_memory_v1(p_user_id uuid, p_guest_user_id uuid, p_memory jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.import_guest_memory_v1(p_user_id uuid, p_guest_user_id uuid, p_memory jsonb) TO service_role;


--
-- Name: FUNCTION insert_memory_content_v2(p_user_id uuid, p_memory jsonb, p_spec jsonb, p_provider text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.insert_memory_content_v2(p_user_id uuid, p_memory jsonb, p_spec jsonb, p_provider text) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.insert_memory_content_v2(p_user_id uuid, p_memory jsonb, p_spec jsonb, p_provider text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.insert_memory_content_v2(p_user_id uuid, p_memory jsonb, p_spec jsonb, p_provider text) TO service_role;


--
-- Name: FUNCTION is_legacy_content_v1(p_target text, p_translation text, p_locale text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.is_legacy_content_v1(p_target text, p_translation text, p_locale text) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.is_legacy_content_v1(p_target text, p_translation text, p_locale text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.is_legacy_content_v1(p_target text, p_translation text, p_locale text) TO anon;
GRANT ALL ON FUNCTION public.is_legacy_content_v1(p_target text, p_translation text, p_locale text) TO authenticated;
GRANT ALL ON FUNCTION public.is_legacy_content_v1(p_target text, p_translation text, p_locale text) TO service_role;


--
-- Name: FUNCTION jsonb_to_embedding_real_array(p_embedding jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.jsonb_to_embedding_real_array(p_embedding jsonb) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.jsonb_to_embedding_real_array(p_embedding jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.jsonb_to_embedding_real_array(p_embedding jsonb) TO service_role;


--
-- Name: FUNCTION legacy_level_to_id_v1(p_level text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.legacy_level_to_id_v1(p_level text) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.legacy_level_to_id_v1(p_level text) FROM PUBLIC;


--
-- Name: FUNCTION legacy_storage_mutation_allowed_v1(p_bucket text, p_name text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.legacy_storage_mutation_allowed_v1(p_bucket text, p_name text) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.legacy_storage_mutation_allowed_v1(p_bucket text, p_name text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.legacy_storage_mutation_allowed_v1(p_bucket text, p_name text) TO anon;
GRANT ALL ON FUNCTION public.legacy_storage_mutation_allowed_v1(p_bucket text, p_name text) TO authenticated;
GRANT ALL ON FUNCTION public.legacy_storage_mutation_allowed_v1(p_bucket text, p_name text) TO service_role;


--
-- Name: FUNCTION legacy_topic_cache_allowed_v1(p_topic_key text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.legacy_topic_cache_allowed_v1(p_topic_key text) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.legacy_topic_cache_allowed_v1(p_topic_key text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.legacy_topic_cache_allowed_v1(p_topic_key text) TO anon;
GRANT ALL ON FUNCTION public.legacy_topic_cache_allowed_v1(p_topic_key text) TO authenticated;


--
-- Name: FUNCTION legacy_topic_expression_allowed_v1(p_expression_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.legacy_topic_expression_allowed_v1(p_expression_id uuid) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.legacy_topic_expression_allowed_v1(p_expression_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.legacy_topic_expression_allowed_v1(p_expression_id uuid) TO anon;
GRANT ALL ON FUNCTION public.legacy_topic_expression_allowed_v1(p_expression_id uuid) TO authenticated;


--
-- Name: FUNCTION level_id_to_legacy_v1(p_level text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.level_id_to_legacy_v1(p_level text) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.level_id_to_legacy_v1(p_level text) FROM PUBLIC;


--
-- Name: FUNCTION list_memories_v2(p_target_language text, p_cursor_created_at timestamp with time zone, p_cursor_id uuid, p_limit integer); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.list_memories_v2(p_target_language text, p_cursor_created_at timestamp with time zone, p_cursor_id uuid, p_limit integer) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.list_memories_v2(p_target_language text, p_cursor_created_at timestamp with time zone, p_cursor_id uuid, p_limit integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.list_memories_v2(p_target_language text, p_cursor_created_at timestamp with time zone, p_cursor_id uuid, p_limit integer) TO authenticated;


--
-- Name: FUNCTION memory_content_dto_v2(p_memory_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.memory_content_dto_v2(p_memory_id uuid) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.memory_content_dto_v2(p_memory_id uuid) FROM PUBLIC;


--
-- Name: FUNCTION merge_local_sentence_study_progress(p_items jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.merge_local_sentence_study_progress(p_items jsonb) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.merge_local_sentence_study_progress(p_items jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.merge_local_sentence_study_progress(p_items jsonb) TO authenticated;
GRANT ALL ON FUNCTION public.merge_local_sentence_study_progress(p_items jsonb) TO service_role;


--
-- Name: FUNCTION merge_local_sentence_study_progress_v2(p_items jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.merge_local_sentence_study_progress_v2(p_items jsonb) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.merge_local_sentence_study_progress_v2(p_items jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.merge_local_sentence_study_progress_v2(p_items jsonb) TO authenticated;
GRANT ALL ON FUNCTION public.merge_local_sentence_study_progress_v2(p_items jsonb) TO service_role;


--
-- Name: FUNCTION normalize_memory_photo_categories(p_tags text[]); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.normalize_memory_photo_categories(p_tags text[]) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.normalize_memory_photo_categories(p_tags text[]) FROM PUBLIC;
GRANT ALL ON FUNCTION public.normalize_memory_photo_categories(p_tags text[]) TO service_role;


--
-- Name: FUNCTION normalize_scene_category_ids(p_ids text[], p_limit integer); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.normalize_scene_category_ids(p_ids text[], p_limit integer) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.normalize_scene_category_ids(p_ids text[], p_limit integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.normalize_scene_category_ids(p_ids text[], p_limit integer) TO service_role;


--
-- Name: FUNCTION project_sentence_content_v2(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.project_sentence_content_v2() FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.project_sentence_content_v2() FROM PUBLIC;


--
-- Name: FUNCTION protect_dialogue_collection_v1(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.protect_dialogue_collection_v1() FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.protect_dialogue_collection_v1() FROM PUBLIC;
GRANT ALL ON FUNCTION public.protect_dialogue_collection_v1() TO service_role;


--
-- Name: FUNCTION protect_generation_context_v3(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.protect_generation_context_v3() FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.protect_generation_context_v3() FROM PUBLIC;
GRANT ALL ON FUNCTION public.protect_generation_context_v3() TO service_role;


--
-- Name: FUNCTION protect_generation_job_result(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.protect_generation_job_result() FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.protect_generation_job_result() FROM PUBLIC;
GRANT ALL ON FUNCTION public.protect_generation_job_result() TO service_role;


--
-- Name: FUNCTION protect_memory_content_v2(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.protect_memory_content_v2() FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.protect_memory_content_v2() FROM PUBLIC;


--
-- Name: FUNCTION protect_profile_balance_fields(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.protect_profile_balance_fields() FROM PUBLIC, anon, authenticated, service_role;
GRANT ALL ON FUNCTION public.protect_profile_balance_fields() TO anon;
GRANT ALL ON FUNCTION public.protect_profile_balance_fields() TO authenticated;
GRANT ALL ON FUNCTION public.protect_profile_balance_fields() TO service_role;


--
-- Name: FUNCTION record_generation_violation(p_user_id uuid, p_window_seconds integer, p_limit integer, p_ban_seconds integer); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.record_generation_violation(p_user_id uuid, p_window_seconds integer, p_limit integer, p_ban_seconds integer) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.record_generation_violation(p_user_id uuid, p_window_seconds integer, p_limit integer, p_ban_seconds integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.record_generation_violation(p_user_id uuid, p_window_seconds integer, p_limit integer, p_ban_seconds integer) TO service_role;


--
-- Name: FUNCTION record_sentence_study_result(p_sentence_id uuid, p_was_correct boolean, p_scope text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.record_sentence_study_result(p_sentence_id uuid, p_was_correct boolean, p_scope text) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.record_sentence_study_result(p_sentence_id uuid, p_was_correct boolean, p_scope text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.record_sentence_study_result(p_sentence_id uuid, p_was_correct boolean, p_scope text) TO authenticated;
GRANT ALL ON FUNCTION public.record_sentence_study_result(p_sentence_id uuid, p_was_correct boolean, p_scope text) TO service_role;


--
-- Name: FUNCTION record_study_event_v2(p_event_id uuid, p_session_id uuid, p_sentence_id uuid, p_was_correct boolean, p_occurred_at timestamp with time zone, p_time_zone text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.record_study_event_v2(p_event_id uuid, p_session_id uuid, p_sentence_id uuid, p_was_correct boolean, p_occurred_at timestamp with time zone, p_time_zone text) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.record_study_event_v2(p_event_id uuid, p_session_id uuid, p_sentence_id uuid, p_was_correct boolean, p_occurred_at timestamp with time zone, p_time_zone text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.record_study_event_v2(p_event_id uuid, p_session_id uuid, p_sentence_id uuid, p_was_correct boolean, p_occurred_at timestamp with time zone, p_time_zone text) TO authenticated;
GRANT ALL ON FUNCTION public.record_study_event_v2(p_event_id uuid, p_session_id uuid, p_sentence_id uuid, p_was_correct boolean, p_occurred_at timestamp with time zone, p_time_zone text) TO service_role;


--
-- Name: FUNCTION recover_generation_job_v2(p_user_id uuid, p_request_id uuid, p_is_anonymous boolean, p_request_fingerprint text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.recover_generation_job_v2(p_user_id uuid, p_request_id uuid, p_is_anonymous boolean, p_request_fingerprint text) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.recover_generation_job_v2(p_user_id uuid, p_request_id uuid, p_is_anonymous boolean, p_request_fingerprint text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.recover_generation_job_v2(p_user_id uuid, p_request_id uuid, p_is_anonymous boolean, p_request_fingerprint text) TO service_role;


--
-- Name: FUNCTION release_generation_slot(p_request_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.release_generation_slot(p_request_id uuid) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.release_generation_slot(p_request_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.release_generation_slot(p_request_id uuid) TO service_role;


--
-- Name: FUNCTION replace_study_topic_expressions(p_user_id uuid, p_topic_key text, p_source_fingerprint text, p_expressions jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.replace_study_topic_expressions(p_user_id uuid, p_topic_key text, p_source_fingerprint text, p_expressions jsonb) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.replace_study_topic_expressions(p_user_id uuid, p_topic_key text, p_source_fingerprint text, p_expressions jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.replace_study_topic_expressions(p_user_id uuid, p_topic_key text, p_source_fingerprint text, p_expressions jsonb) TO service_role;


--
-- Name: FUNCTION require_content_user_v1(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.require_content_user_v1() FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.require_content_user_v1() FROM PUBLIC;


--
-- Name: FUNCTION scene_category_catalog_version(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.scene_category_catalog_version() FROM PUBLIC, anon, authenticated, service_role;
GRANT ALL ON FUNCTION public.scene_category_catalog_version() TO anon;
GRANT ALL ON FUNCTION public.scene_category_catalog_version() TO authenticated;
GRANT ALL ON FUNCTION public.scene_category_catalog_version() TO service_role;


--
-- Name: FUNCTION scene_category_ids(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.scene_category_ids() FROM PUBLIC, anon, authenticated, service_role;
GRANT ALL ON FUNCTION public.scene_category_ids() TO anon;
GRANT ALL ON FUNCTION public.scene_category_ids() TO authenticated;
GRANT ALL ON FUNCTION public.scene_category_ids() TO service_role;


--
-- Name: FUNCTION sentence_explanation_source_v2(p_user_id uuid, p_sentence_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.sentence_explanation_source_v2(p_user_id uuid, p_sentence_id uuid) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.sentence_explanation_source_v2(p_user_id uuid, p_sentence_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.sentence_explanation_source_v2(p_user_id uuid, p_sentence_id uuid) TO service_role;


--
-- Name: FUNCTION sentence_study_time_zone(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.sentence_study_time_zone() FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.sentence_study_time_zone() FROM PUBLIC;
GRANT ALL ON FUNCTION public.sentence_study_time_zone() TO authenticated;
GRANT ALL ON FUNCTION public.sentence_study_time_zone() TO service_role;


--
-- Name: FUNCTION set_sentence_favorite_v2(p_sentence_id uuid, p_is_favorite boolean); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.set_sentence_favorite_v2(p_sentence_id uuid, p_is_favorite boolean) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.set_sentence_favorite_v2(p_sentence_id uuid, p_is_favorite boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION public.set_sentence_favorite_v2(p_sentence_id uuid, p_is_favorite boolean) TO authenticated;


--
-- Name: FUNCTION set_updated_at(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.set_updated_at() FROM PUBLIC, anon, authenticated, service_role;
GRANT ALL ON FUNCTION public.set_updated_at() TO anon;
GRANT ALL ON FUNCTION public.set_updated_at() TO authenticated;
GRANT ALL ON FUNCTION public.set_updated_at() TO service_role;


--
-- Name: FUNCTION strip_sentence_metadata_v1(p_sentences jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.strip_sentence_metadata_v1(p_sentences jsonb) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.strip_sentence_metadata_v1(p_sentences jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.strip_sentence_metadata_v1(p_sentences jsonb) TO service_role;


--
-- Name: FUNCTION sync_album_flip_feedback(p_events jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.sync_album_flip_feedback(p_events jsonb) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.sync_album_flip_feedback(p_events jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.sync_album_flip_feedback(p_events jsonb) TO authenticated;


--
-- Name: FUNCTION sync_album_flip_feedback_internal_v1(p_events jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.sync_album_flip_feedback_internal_v1(p_events jsonb) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.sync_album_flip_feedback_internal_v1(p_events jsonb) FROM PUBLIC;


--
-- Name: FUNCTION sync_album_flip_feedback_v2(p_events jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.sync_album_flip_feedback_v2(p_events jsonb) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.sync_album_flip_feedback_v2(p_events jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.sync_album_flip_feedback_v2(p_events jsonb) TO authenticated;


--
-- Name: FUNCTION sync_legacy_english_preferences_v1(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.sync_legacy_english_preferences_v1() FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.sync_legacy_english_preferences_v1() FROM PUBLIC;


--
-- Name: FUNCTION touch_sentence_study_progress_updated_at(); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.touch_sentence_study_progress_updated_at() FROM PUBLIC, anon, authenticated, service_role;
GRANT ALL ON FUNCTION public.touch_sentence_study_progress_updated_at() TO anon;
GRANT ALL ON FUNCTION public.touch_sentence_study_progress_updated_at() TO authenticated;
GRANT ALL ON FUNCTION public.touch_sentence_study_progress_updated_at() TO service_role;


--
-- Name: FUNCTION transfer_guest_credits(p_guest_user_id uuid, p_account_user_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.transfer_guest_credits(p_guest_user_id uuid, p_account_user_id uuid) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.transfer_guest_credits(p_guest_user_id uuid, p_account_user_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.transfer_guest_credits(p_guest_user_id uuid, p_account_user_id uuid) TO service_role;


--
-- Name: FUNCTION try_acquire_generation_slot(p_request_id uuid, p_user_id uuid, p_max_slots integer, p_ttl_seconds integer); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.try_acquire_generation_slot(p_request_id uuid, p_user_id uuid, p_max_slots integer, p_ttl_seconds integer) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.try_acquire_generation_slot(p_request_id uuid, p_user_id uuid, p_max_slots integer, p_ttl_seconds integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.try_acquire_generation_slot(p_request_id uuid, p_user_id uuid, p_max_slots integer, p_ttl_seconds integer) TO service_role;


--
-- Name: FUNCTION update_learning_preferences_v1(p_patch jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.update_learning_preferences_v1(p_patch jsonb) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.update_learning_preferences_v1(p_patch jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.update_learning_preferences_v1(p_patch jsonb) TO authenticated;


--
-- Name: FUNCTION valid_generation_spec_v3(p_spec jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.valid_generation_spec_v3(p_spec jsonb) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.valid_generation_spec_v3(p_spec jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.valid_generation_spec_v3(p_spec jsonb) TO service_role;


--
-- Name: FUNCTION valid_learning_material_v1(p_material jsonb, p_text text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.valid_learning_material_v1(p_material jsonb, p_text text) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.valid_learning_material_v1(p_material jsonb, p_text text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.valid_learning_material_v1(p_material jsonb, p_text text) TO anon;
GRANT ALL ON FUNCTION public.valid_learning_material_v1(p_material jsonb, p_text text) TO authenticated;
GRANT ALL ON FUNCTION public.valid_learning_material_v1(p_material jsonb, p_text text) TO service_role;


--
-- Name: FUNCTION valid_sentence_collection_v1(p_sentences jsonb, p_format text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.valid_sentence_collection_v1(p_sentences jsonb, p_format text) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.valid_sentence_collection_v1(p_sentences jsonb, p_format text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.valid_sentence_collection_v1(p_sentences jsonb, p_format text) TO service_role;


--
-- Name: FUNCTION valid_sentence_dialogue_v1(p_dialogue jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.valid_sentence_dialogue_v1(p_dialogue jsonb) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.valid_sentence_dialogue_v1(p_dialogue jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.valid_sentence_dialogue_v1(p_dialogue jsonb) TO service_role;
GRANT ALL ON FUNCTION public.valid_sentence_dialogue_v1(p_dialogue jsonb) TO authenticated;


--
-- Name: FUNCTION valid_sentence_explanation_v3(p_content jsonb); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.valid_sentence_explanation_v3(p_content jsonb) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.valid_sentence_explanation_v3(p_content jsonb) FROM PUBLIC;
GRANT ALL ON FUNCTION public.valid_sentence_explanation_v3(p_content jsonb) TO service_role;


--
-- Name: FUNCTION validate_memory_import_v1(p_memory jsonb, p_user_id uuid); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.validate_memory_import_v1(p_memory jsonb, p_user_id uuid) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.validate_memory_import_v1(p_memory jsonb, p_user_id uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.validate_memory_import_v1(p_memory jsonb, p_user_id uuid) TO service_role;


--
-- Name: TABLE account_deletion_jobs; Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON TABLE public.account_deletion_jobs FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE public.account_deletion_jobs TO anon;
GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE public.account_deletion_jobs TO authenticated;
GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE public.account_deletion_jobs TO service_role;


--
-- Name: TABLE apple_auth_credentials; Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON TABLE public.apple_auth_credentials FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE public.apple_auth_credentials TO anon;
GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE public.apple_auth_credentials TO authenticated;
GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE public.apple_auth_credentials TO service_role;


--
-- Name: TABLE generation_jobs; Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON TABLE public.generation_jobs FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE public.generation_jobs TO authenticated;
GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE public.generation_jobs TO service_role;


--
-- Name: TABLE generation_request_slots; Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON TABLE public.generation_request_slots FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE public.generation_request_slots TO anon;
GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE public.generation_request_slots TO authenticated;
GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE public.generation_request_slots TO service_role;


--
-- Name: TABLE generation_transactions; Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON TABLE public.generation_transactions FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE public.generation_transactions TO anon;
GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE public.generation_transactions TO authenticated;
GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE public.generation_transactions TO service_role;


--
-- Name: TABLE guest_generation_jobs; Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON TABLE public.guest_generation_jobs FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE public.guest_generation_jobs TO anon;
GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE public.guest_generation_jobs TO authenticated;
GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE public.guest_generation_jobs TO service_role;


--
-- Name: TABLE guest_memory_import_receipts_v1; Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON TABLE public.guest_memory_import_receipts_v1 FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE public.guest_memory_import_receipts_v1 TO service_role;


--
-- Name: TABLE language_capabilities_v1; Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON TABLE public.language_capabilities_v1 FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE public.language_capabilities_v1 TO service_role;


--
-- Name: TABLE memories; Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON TABLE public.memories FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE public.memories TO anon;
GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE public.memories TO authenticated;
GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE public.memories TO service_role;


--
-- Name: TABLE memory_deletion_receipts_v2; Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON TABLE public.memory_deletion_receipts_v2 FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE public.memory_deletion_receipts_v2 TO service_role;


--
-- Name: TABLE memory_sentences; Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON TABLE public.memory_sentences FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE public.memory_sentences TO anon;
GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE public.memory_sentences TO authenticated;
GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE public.memory_sentences TO service_role;


--
-- Name: TABLE profiles; Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON TABLE public.profiles FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE public.profiles TO anon;
GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE public.profiles TO authenticated;
GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE public.profiles TO service_role;


--
-- Name: TABLE purchase_ledger; Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON TABLE public.purchase_ledger FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE public.purchase_ledger TO anon;
GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE public.purchase_ledger TO authenticated;
GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE public.purchase_ledger TO service_role;


--
-- Name: TABLE sentence_explanation_limits; Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON TABLE public.sentence_explanation_limits FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE public.sentence_explanation_limits TO service_role;


--
-- Name: TABLE sentence_explanations; Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON TABLE public.sentence_explanations FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE public.sentence_explanations TO service_role;


--
-- Name: TABLE sentence_study_activations; Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON TABLE public.sentence_study_activations FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE public.sentence_study_activations TO service_role;


--
-- Name: TABLE speech_request_limits; Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON TABLE public.speech_request_limits FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE public.speech_request_limits TO service_role;


--
-- Name: TABLE study_event_receipts; Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON TABLE public.study_event_receipts FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE public.study_event_receipts TO service_role;


--
-- Name: TABLE study_scene_sentence_reviews; Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON TABLE public.study_scene_sentence_reviews FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE public.study_scene_sentence_reviews TO service_role;


--
-- Name: TABLE study_scene_sentences; Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON TABLE public.study_scene_sentences FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE public.study_scene_sentences TO anon;
GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE public.study_scene_sentences TO authenticated;
GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE public.study_scene_sentences TO service_role;


--
-- Name: TABLE study_scenes; Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON TABLE public.study_scenes FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE public.study_scenes TO anon;
GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE public.study_scenes TO authenticated;
GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE public.study_scenes TO service_role;


--
-- Name: TABLE study_sessions; Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON TABLE public.study_sessions FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE public.study_sessions TO service_role;


--
-- Name: TABLE study_topic_expression_examples; Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON TABLE public.study_topic_expression_examples FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE public.study_topic_expression_examples TO anon;
GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE public.study_topic_expression_examples TO authenticated;
GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE public.study_topic_expression_examples TO service_role;


--
-- Name: TABLE study_topic_expression_sets; Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON TABLE public.study_topic_expression_sets FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE public.study_topic_expression_sets TO anon;
GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE public.study_topic_expression_sets TO authenticated;
GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE public.study_topic_expression_sets TO service_role;


--
-- Name: TABLE study_topic_expressions; Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON TABLE public.study_topic_expressions FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE public.study_topic_expressions TO anon;
GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE public.study_topic_expressions TO authenticated;
GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE public.study_topic_expressions TO service_role;


--
-- Name: TABLE user_language_preferences; Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON TABLE public.user_language_preferences FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE public.user_language_preferences TO service_role;


--
-- Name: TABLE user_learning_preferences; Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON TABLE public.user_learning_preferences FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLE public.user_learning_preferences TO service_role;


--
-- Name: DEFAULT PRIVILEGES FOR SEQUENCES; Type: DEFAULT ACL; Schema: public; Owner: -
--

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON SEQUENCES TO postgres;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON SEQUENCES TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON SEQUENCES TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON SEQUENCES TO service_role;


--
-- Name: DEFAULT PRIVILEGES FOR FUNCTIONS; Type: DEFAULT ACL; Schema: public; Owner: -
--

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON FUNCTIONS TO postgres;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON FUNCTIONS TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON FUNCTIONS TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON FUNCTIONS TO service_role;


--
-- Name: DEFAULT PRIVILEGES FOR TABLES; Type: DEFAULT ACL; Schema: public; Owner: -
--

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLES TO postgres;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLES TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLES TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,UPDATE ON TABLES TO service_role;


--
-- PostgreSQL database dump complete
--
