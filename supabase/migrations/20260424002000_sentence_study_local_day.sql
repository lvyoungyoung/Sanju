drop function if exists public.get_sentence_study_queue(integer);
drop function if exists public.count_sentence_study_queue();
drop function if exists public.record_sentence_study_result(uuid, boolean);

create or replace function public.get_sentence_study_queue(p_limit integer default 5)
returns table (
  sentence_id uuid,
  memory_id uuid,
  english text,
  chinese text,
  image_path text,
  memory_created_at timestamptz,
  learning_step integer,
  mastered_review_count integer,
  correct_count integer,
  wrong_count integer,
  last_result text,
  next_review_at timestamptz
)
language sql
security definer
set search_path = public, pg_temp
as $$
  with candidates as (
    select
      ms.id as sentence_id,
      ms.memory_id,
      ms.english,
      ms.chinese,
      m.image_url,
      m.created_at,
      coalesce(sp.learning_step, 0) as learning_step,
      coalesce(sp.mastered_review_count, 0) as mastered_review_count,
      coalesce(sp.correct_count, 0) as correct_count,
      coalesce(sp.wrong_count, 0) as wrong_count,
      sp.last_result,
      sp.next_review_at,
      case
        when sp.id is not null
          and sp.learning_step < 5
          and (sp.next_review_at at time zone 'Asia/Shanghai')::date <= (now() at time zone 'Asia/Shanghai')::date then 1
        when sp.id is null then 2
        when sp.id is not null
          and sp.learning_step >= 5
          and (sp.next_review_at at time zone 'Asia/Shanghai')::date <= (now() at time zone 'Asia/Shanghai')::date then 3
        else 99
      end as priority
    from public.memory_sentences ms
    join public.memories m
      on m.id = ms.memory_id
    left join public.sentence_study_progress sp
      on sp.sentence_id = ms.id
     and sp.user_id = auth.uid()
    where auth.uid() is not null
      and m.user_id = auth.uid()
      and ms.is_favorite = true
      and (
        sp.last_studied_on is null
        or sp.last_studied_on < (now() at time zone 'Asia/Shanghai')::date
      )
  )
  select
    sentence_id,
    memory_id,
    english,
    chinese,
    image_url,
    created_at,
    learning_step,
    mastered_review_count,
    correct_count,
    wrong_count,
    last_result,
    next_review_at
  from candidates
  where priority < 99
  order by
    priority asc,
    coalesce((next_review_at at time zone 'Asia/Shanghai')::date, (now() at time zone 'Asia/Shanghai')::date) asc,
    created_at desc
  limit greatest(coalesce(p_limit, 5), 1);
$$;

grant execute on function public.get_sentence_study_queue(integer) to authenticated;

create or replace function public.count_sentence_study_queue()
returns integer
language sql
security definer
set search_path = public, pg_temp
as $$
  with candidates as (
    select
      case
        when sp.id is not null
          and sp.learning_step < 5
          and (sp.next_review_at at time zone 'Asia/Shanghai')::date <= (now() at time zone 'Asia/Shanghai')::date then 1
        when sp.id is null then 2
        when sp.id is not null
          and sp.learning_step >= 5
          and (sp.next_review_at at time zone 'Asia/Shanghai')::date <= (now() at time zone 'Asia/Shanghai')::date then 3
        else 99
      end as priority
    from public.memory_sentences ms
    join public.memories m
      on m.id = ms.memory_id
    left join public.sentence_study_progress sp
      on sp.sentence_id = ms.id
     and sp.user_id = auth.uid()
    where auth.uid() is not null
      and m.user_id = auth.uid()
      and ms.is_favorite = true
      and (
        sp.last_studied_on is null
        or sp.last_studied_on < (now() at time zone 'Asia/Shanghai')::date
      )
  )
  select count(*)::integer
  from candidates
  where priority < 99;
$$;

grant execute on function public.count_sentence_study_queue() to authenticated;

create or replace function public.record_sentence_study_result(
  p_sentence_id uuid,
  p_was_correct boolean
)
returns public.sentence_study_progress
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_now timestamptz := now();
  v_today date := (now() at time zone 'Asia/Shanghai')::date;
  v_existing public.sentence_study_progress%rowtype;
  v_result public.sentence_study_progress%rowtype;
  v_learning_step integer;
  v_mastered_review_count integer;
  v_correct_count integer;
  v_wrong_count integer;
  v_next_review_at timestamptz;
  v_last_result text;
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;

  perform 1
  from public.memory_sentences ms
  join public.memories m
    on m.id = ms.memory_id
  where ms.id = p_sentence_id
    and ms.is_favorite = true
    and m.user_id = auth.uid();

  if not found then
    raise exception 'Sentence not available for study';
  end if;

  select *
    into v_existing
  from public.sentence_study_progress
  where user_id = auth.uid()
    and sentence_id = p_sentence_id
  for update;

  if found and v_existing.last_studied_on = v_today then
    return v_existing;
  end if;

  if p_was_correct then
    v_correct_count := coalesce(v_existing.correct_count, 0) + 1;
    v_wrong_count := coalesce(v_existing.wrong_count, 0);
    v_last_result := 'correct';

    if coalesce(v_existing.learning_step, 0) < 5 then
      v_learning_step := coalesce(v_existing.learning_step, 0) + 1;
      v_mastered_review_count := coalesce(v_existing.mastered_review_count, 0);

      case v_learning_step
        when 1 then v_next_review_at := ((v_today + 1)::timestamp at time zone 'Asia/Shanghai');
        when 2 then v_next_review_at := ((v_today + 2)::timestamp at time zone 'Asia/Shanghai');
        when 3 then v_next_review_at := ((v_today + 4)::timestamp at time zone 'Asia/Shanghai');
        when 4 then v_next_review_at := ((v_today + 7)::timestamp at time zone 'Asia/Shanghai');
        else v_next_review_at := ((v_today + 14)::timestamp at time zone 'Asia/Shanghai');
      end case;
    else
      v_learning_step := 5;
      v_mastered_review_count := coalesce(v_existing.mastered_review_count, 0) + 1;

      if v_mastered_review_count = 1 then
        v_next_review_at := ((v_today + 30)::timestamp at time zone 'Asia/Shanghai');
      else
        v_next_review_at := ((v_today + 60)::timestamp at time zone 'Asia/Shanghai');
      end if;
    end if;
  else
    v_learning_step := least(coalesce(v_existing.learning_step, 0), 5);
    v_mastered_review_count := coalesce(v_existing.mastered_review_count, 0);
    v_correct_count := coalesce(v_existing.correct_count, 0);
    v_wrong_count := coalesce(v_existing.wrong_count, 0) + 1;
    v_last_result := 'incorrect';
    v_next_review_at := ((v_today + 1)::timestamp at time zone 'Asia/Shanghai');
  end if;

  insert into public.sentence_study_progress (
    user_id,
    sentence_id,
    learning_step,
    mastered_review_count,
    correct_count,
    wrong_count,
    last_result,
    last_studied_at,
    last_studied_on,
    next_review_at
  )
  values (
    auth.uid(),
    p_sentence_id,
    v_learning_step,
    v_mastered_review_count,
    v_correct_count,
    v_wrong_count,
    v_last_result,
    v_now,
    v_today,
    v_next_review_at
  )
  on conflict (user_id, sentence_id) do update
    set learning_step = excluded.learning_step,
        mastered_review_count = excluded.mastered_review_count,
        correct_count = excluded.correct_count,
        wrong_count = excluded.wrong_count,
        last_result = excluded.last_result,
        last_studied_at = excluded.last_studied_at,
        last_studied_on = excluded.last_studied_on,
        next_review_at = excluded.next_review_at,
        updated_at = v_now
  returning *
    into v_result;

  return v_result;
end;
$$;

grant execute on function public.record_sentence_study_result(uuid, boolean) to authenticated;
