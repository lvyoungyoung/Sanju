-- Requires 20261013000000's immutable generic content/context fields.
-- Activations intentionally have NO sentence FK: deleting content never refunds a slot.
begin;

create table public.sentence_study_activations (
  user_id uuid not null references auth.users(id) on delete cascade,
  sentence_id uuid not null,
  first_activated_at timestamptz not null default now(),
  source text not null check (source in ('session', 'legacy', 'import', 'baseline')),
  session_id uuid,
  primary key (user_id, sentence_id)
);
create index sentence_study_activations_day on public.sentence_study_activations(user_id, first_activated_at);
insert into public.sentence_study_activations(user_id, sentence_id, first_activated_at, source)
select distinct user_id, sentence_id, '-infinity'::timestamptz, 'baseline'
from public.sentence_study_progress;

create table public.study_sessions (
  user_id uuid not null references auth.users(id) on delete cascade,
  session_id uuid not null,
  target_language text not null check (target_language in ('en','es','ja','fr')),
  study_scope text not null,
  mode text not null check (mode in ('due','today','direct')),
  time_zone text not null,
  requested_limit integer not null,
  legacy_only boolean not null default false,
  sentence_ids uuid[] not null,
  started_at timestamptz not null default now(),
  primary key (user_id, session_id)
);
create table public.study_event_receipts (
  user_id uuid not null references auth.users(id) on delete cascade,
  event_id uuid not null,
  session_id uuid not null,
  sentence_id uuid not null,
  was_correct boolean not null,
  occurred_at timestamptz not null,
  time_zone text not null,
  result jsonb not null,
  primary key (user_id, event_id)
);
alter table public.sentence_study_activations enable row level security;
alter table public.study_sessions enable row level security;
alter table public.study_event_receipts enable row level security;
revoke all on public.sentence_study_activations, public.study_sessions, public.study_event_receipts from public, anon, authenticated;
-- Released clients read progress directly but write through the guarded RPCs.
revoke insert,update,delete on public.sentence_study_progress from anon,authenticated;

create function public._study_zone_v2(p_zone text) returns text
language plpgsql stable set search_path = public, pg_temp as $$
begin
  if p_zone is null then return public.sentence_study_time_zone(); end if;
  if char_length(p_zone) > 100 or not exists (select 1 from pg_timezone_names where name = p_zone) then
    raise exception 'invalid_study_time_zone';
  end if;
  return p_zone;
end;
$$;

create function public._study_lock_v2() returns void
language plpgsql set search_path = public, pg_temp as $$
begin
  if auth.uid() is null then raise exception 'authentication_required'; end if;
  -- One account lock across every language, scope, legacy API and event write.
  perform pg_advisory_xact_lock(hashtextextended('study:' || auth.uid()::text, 0));
end;
$$;

create function public._study_remaining_v2(p_zone text) returns integer
language sql stable security definer set search_path = public, pg_temp as $$
  select greatest(0, 30 - count(*)::integer)
  from public.sentence_study_activations
  where user_id = auth.uid() and source <> 'baseline'
    and first_activated_at >= ((now() at time zone p_zone)::date::timestamp at time zone p_zone)
    and first_activated_at < (((now() at time zone p_zone)::date + 1)::timestamp at time zone p_zone);
$$;

create function public._study_candidates_v2(p_language text, p_scope text, p_mode text, p_zone text, p_legacy boolean default false)
returns table(sentence_id uuid, priority integer, item jsonb, activated boolean)
language plpgsql stable security definer set search_path = public, pg_temp as $$
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

create function public._begin_study_session_v2(p_session_id uuid, p_target_language text, p_scope text,
  p_limit integer, p_mode text, p_time_zone text, p_legacy boolean)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
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

create function public.begin_study_session_v2(p_session_id uuid, p_target_language text,
  p_scope text default 'favorites', p_limit integer default 5, p_mode text default 'due', p_time_zone text default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if p_mode is null or p_mode not in ('due','today') then raise exception 'invalid_study_filter'; end if;
  return public._begin_study_session_v2(p_session_id,p_target_language,p_scope,p_limit,p_mode,p_time_zone,false);
end;
$$;

-- Direct study shares favorites progress, but never changes favorite membership.
-- A distinct mode prevents a queue retry from reusing a direct-session identity.
create function public.begin_direct_study_session_v2(p_session_id uuid, p_sentence_id uuid, p_time_zone text default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
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

create function public.get_sentence_study_progress_v2(p_target_language text default null)
returns setof public.sentence_study_progress language plpgsql stable security definer
set search_path = pg_catalog, public, pg_temp as $$
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

create function public.get_study_overview_v2(p_target_language text, p_scope text default 'favorites', p_time_zone text default null)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
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

create function public.record_study_event_v2(p_event_id uuid, p_session_id uuid, p_sentence_id uuid,
  p_was_correct boolean, p_occurred_at timestamptz, p_time_zone text default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
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

-- Existing record contract delegates to the same activation/event transaction.
create or replace function public.record_sentence_study_result(p_sentence_id uuid,p_was_correct boolean,p_scope text default 'favorites')
returns public.sentence_study_progress language plpgsql security definer set search_path = public, pg_temp as $$
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

-- Old queue DTO remains byte-for-byte compatible in field names/types. Its act of
-- claiming is the legacy equivalent of begin; read-only statistics never call it.
create or replace function public.get_sentence_study_queue(p_limit integer default 5)
returns table(sentence_id uuid,memory_id uuid,english text,chinese text,image_path text,memory_created_at timestamptz,
  learning_step integer,mastered_review_count integer,correct_count integer,wrong_count integer,last_result text,next_review_at timestamptz)
language sql security definer set search_path = public, pg_temp as $$
  select (i->>'sentence_id')::uuid,(i->>'memory_id')::uuid,i->>'target_text',i->>'translation_text',i->>'image_path',
    (i->>'memory_created_at')::timestamptz,(i->>'learning_step')::integer,(i->>'mastered_review_count')::integer,
    (i->>'correct_count')::integer,(i->>'wrong_count')::integer,i->>'last_result',(i->>'next_review_at')::timestamptz
  from jsonb_array_elements(public._begin_study_session_v2(gen_random_uuid(),'en','favorites',
    least(greatest(coalesce(p_limit,5),1),1000),'due',null,true)->'items') i;
$$;

create or replace function public.get_study_scene_queue(p_scene_id uuid,p_limit integer default 1000)
returns table(sentence_id uuid,memory_id uuid,english text,chinese text,image_path text,memory_created_at timestamptz,
  learning_step integer,mastered_review_count integer,correct_count integer,wrong_count integer,last_result text,next_review_at timestamptz)
language sql security definer set search_path = public, pg_temp as $$
  select (i->>'sentence_id')::uuid,(i->>'memory_id')::uuid,i->>'target_text',i->>'translation_text',i->>'image_path',
    (i->>'memory_created_at')::timestamptz,(i->>'learning_step')::integer,(i->>'mastered_review_count')::integer,
    (i->>'correct_count')::integer,(i->>'wrong_count')::integer,i->>'last_result',(i->>'next_review_at')::timestamptz
  from jsonb_array_elements(public._begin_study_session_v2(gen_random_uuid(),'en','scene:' || p_scene_id::text,
    least(greatest(coalesce(p_limit,1000),1),1000),'due',null,true)->'items') i;
$$;

create or replace function public.count_sentence_study_queue() returns integer
language sql stable security definer set search_path = public, pg_temp as $$
  select (count(*) filter(where activated))::integer + least((count(*) filter(where not activated))::integer,
    public._study_remaining_v2(public.sentence_study_time_zone()))
  from public._study_candidates_v2('en','favorites','due',public.sentence_study_time_zone(),true);
$$;

create or replace function public.count_sentence_studied_today() returns integer
language sql stable security definer set search_path = public, pg_temp as $$
  select count(*)::integer from public.sentence_study_progress sp
  join public.memory_sentences ms on ms.id=sp.sentence_id
  join public.memories m on m.id=ms.memory_id
  where sp.user_id=auth.uid() and m.user_id=auth.uid() and m.target_language='en'
    and m.translation_language='zh-Hans' and m.teaching_locale='en-US'
    and coalesce((sp.last_studied_at at time zone public.sentence_study_time_zone())::date,sp.last_studied_on)
      = (now() at time zone public.sentence_study_time_zone())::date;
$$;

-- Keep the deployed max/most-recent merge semantics, but account for accepted
-- imported activations atomically. Import may exceed 30: it must not lose work.
alter function public.merge_local_sentence_study_progress(jsonb) rename to _merge_local_study_progress_v1;
revoke all on function public._merge_local_study_progress_v1(jsonb) from public,anon,authenticated,service_role;
create function public._merge_study_progress_v2(p_items jsonb,p_legacy boolean)
returns table(sentence_id uuid,study_scope text)
language plpgsql security definer set search_path = public, pg_temp as $$
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
create function public.merge_local_sentence_study_progress(p_items jsonb)
returns table(sentence_id uuid,study_scope text)
language sql security definer set search_path = public, pg_temp as $$
  select * from public._merge_study_progress_v2(p_items,true);
$$;
create function public.merge_local_sentence_study_progress_v2(p_items jsonb)
returns table(sentence_id uuid,study_scope text)
language sql security definer set search_path = public, pg_temp as $$
  select * from public._merge_study_progress_v2(p_items,false);
$$;

-- Restrict legacy SECURITY DEFINER reads too: RLS alone cannot protect them.
-- These deployed definitions use either m/ms or memory/sentence aliases. Apply
-- compatibility at the memory join, including LEFT JOIN summaries/cover queries.
do $$
declare f record; v_definition text;
begin
  for f in select p.oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname in (
      'get_sentence_studied_today_queue','get_studied_today_scene_queue','count_sentence_studied_today',
      'count_sentence_studied_today_reviewable','get_study_scenes','get_study_scene_summary_for_owner',
      'get_sentence_study_topic_queue','get_sentence_studied_today_topic_queue','get_sentence_study_topic_summaries',
      'get_study_topic_expressions','get_study_topic_source_sentences','get_study_scene_detail_sentences',
      'study_scene_similarity_scores','get_study_scene_match_diagnostics','replace_study_topic_expressions')
  loop
    v_definition := pg_get_functiondef(f.oid);
    v_definition := replace(v_definition,'public.memory_sentences',
      '(select legacy_sentence.* from public.memory_sentences legacy_sentence join public.memories legacy_memory
        on legacy_memory.id=legacy_sentence.memory_id where legacy_memory.target_language=''en''
        and legacy_memory.translation_language=''zh-Hans'' and legacy_memory.teaching_locale=''en-US'')');
    -- Aggregate only successfully joined sentences, not dangling scene links.
    v_definition := replace(v_definition,'link.sentence_id,','sentence.id as sentence_id,');
    v_definition := replace(v_definition,'when scene_sentences.correct_count <= 0',
      'when scene_sentences.sentence_id is null then null when scene_sentences.correct_count <= 0');
    if v_definition like '%public.study_topic_expressions expression%' then
      v_definition := replace(v_definition,'order by expression.kind,',
        'having count(sentence.id)>0 and count(*) filter(where example.sentence_id is not null and sentence.id is null)=0 order by expression.kind,');
    end if;
    execute v_definition;
  end loop;
end;
$$;

revoke all on function public._study_zone_v2(text),public._study_lock_v2(),public._study_remaining_v2(text),
  public._study_candidates_v2(text,text,text,text,boolean),public._begin_study_session_v2(uuid,text,text,integer,text,text,boolean)
  from public,anon,authenticated;
revoke all on function public._merge_study_progress_v2(jsonb,boolean) from public,anon,authenticated,service_role;
revoke all on function public.merge_local_sentence_study_progress(jsonb),public.merge_local_sentence_study_progress_v2(jsonb) from public,anon;
grant execute on function public.merge_local_sentence_study_progress(jsonb),public.merge_local_sentence_study_progress_v2(jsonb) to authenticated;
revoke all on function public.begin_study_session_v2(uuid,text,text,integer,text,text),
  public.get_study_overview_v2(text,text,text),public.record_study_event_v2(uuid,uuid,uuid,boolean,timestamptz,text) from public,anon;
grant execute on function public.begin_study_session_v2(uuid,text,text,integer,text,text),
  public.get_study_overview_v2(text,text,text),public.record_study_event_v2(uuid,uuid,uuid,boolean,timestamptz,text) to authenticated;
revoke all on function public.get_sentence_study_progress_v2(text) from public,anon;
grant execute on function public.get_sentence_study_progress_v2(text) to authenticated;
revoke all on function public.begin_direct_study_session_v2(uuid,uuid,text) from public,anon;
grant execute on function public.begin_direct_study_session_v2(uuid,uuid,text) to authenticated;
notify pgrst,'reload schema';
commit;
