-- Album browsing is self-reported familiarity, independent of study progress.
create table public.album_flip_progress (
  user_id uuid not null references auth.users(id) on delete cascade,
  sentence_id uuid not null references public.memory_sentences(id) on delete cascade,
  memory_id uuid not null references public.memories(id) on delete cascade,
  last_event_id uuid not null,
  last_feedback text not null check (last_feedback in ('again', 'familiar')),
  last_feedback_at timestamptz not null,
  familiarity_level integer not null check (familiarity_level between 0 and 4),
  last_familiar_at timestamptz,
  primary key (user_id, sentence_id)
);

create index album_flip_progress_sentence_idx on public.album_flip_progress(sentence_id);
create index album_flip_progress_memory_idx on public.album_flip_progress(memory_id);

alter table public.album_flip_progress enable row level security;
create policy album_flip_progress_select_own on public.album_flip_progress
  for select to authenticated
  using (user_id = auth.uid() and not coalesce((auth.jwt()->>'is_anonymous')::boolean, false));
revoke all on public.album_flip_progress from anon, authenticated;
grant select on public.album_flip_progress to authenticated;

create function public.sync_album_flip_feedback(p_events jsonb)
returns setof public.album_flip_progress
language plpgsql security definer
set search_path = public, pg_temp
as $$
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

revoke all on function public.sync_album_flip_feedback(jsonb) from public, anon, authenticated;
grant execute on function public.sync_album_flip_feedback(jsonb) to authenticated;
comment on table public.album_flip_progress is
  'Latest per-sentence album browsing feedback. Does not change study counts, mastery, favorites or credits.';
notify pgrst, 'reload schema';
