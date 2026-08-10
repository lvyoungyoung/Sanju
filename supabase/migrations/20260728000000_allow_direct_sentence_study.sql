-- A sentence can be studied directly from its generated result or detail page.
-- Only the owner may write study progress; regular study queues still select favorites.
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

revoke all on function public.record_sentence_study_result(uuid, boolean) from public;
revoke all on function public.record_sentence_study_result(uuid, boolean) from anon;
grant execute on function public.record_sentence_study_result(uuid, boolean) to authenticated;
