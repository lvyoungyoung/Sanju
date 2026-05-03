create or replace function public.merge_local_sentence_study_progress(p_items jsonb)
returns table (
  sentence_id uuid
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
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
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;

  if p_items is null or jsonb_typeof(p_items) <> 'array' then
    return;
  end if;

  for v_item in
    select value
    from jsonb_array_elements(p_items)
  loop
    begin
      v_sentence_id := nullif(v_item->>'sentence_id', '')::uuid;
      v_learning_step := least(greatest(coalesce(nullif(v_item->>'learning_step', '')::integer, 0), 0), 5);
      v_mastered_review_count := greatest(coalesce(nullif(v_item->>'mastered_review_count', '')::integer, 0), 0);
      v_correct_count := greatest(coalesce(nullif(v_item->>'correct_count', '')::integer, 0), 0);
      v_wrong_count := greatest(coalesce(nullif(v_item->>'wrong_count', '')::integer, 0), 0);
      v_last_result := case
        when v_item->>'last_result' in ('correct', 'incorrect') then v_item->>'last_result'
        else null
      end;
      v_last_studied_at := nullif(v_item->>'last_studied_at', '')::timestamptz;
      v_last_studied_on := nullif(v_item->>'last_studied_on', '')::date;
      v_next_review_on := nullif(v_item->>'next_review_on', '')::date;
    exception when others then
      continue;
    end;

    if v_sentence_id is null then
      continue;
    end if;

    if v_last_studied_on is null and v_last_studied_at is not null then
      v_last_studied_on := (v_last_studied_at at time zone 'Asia/Shanghai')::date;
    end if;

    v_next_review_on := coalesce(
      v_next_review_on,
      v_last_studied_on,
      (now() at time zone 'Asia/Shanghai')::date
    );
    v_next_review_at := (v_next_review_on::timestamp at time zone 'Asia/Shanghai');

    perform 1
    from public.memory_sentences ms
    join public.memories m
      on m.id = ms.memory_id
    where ms.id = v_sentence_id
      and ms.is_favorite = true
      and m.user_id = auth.uid();

    if not found then
      continue;
    end if;

    insert into public.sentence_study_progress as sp (
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
      v_sentence_id,
      v_learning_step,
      v_mastered_review_count,
      v_correct_count,
      v_wrong_count,
      v_last_result,
      v_last_studied_at,
      v_last_studied_on,
      v_next_review_at
    )
    on conflict on constraint sentence_study_progress_user_id_sentence_id_key do update
      set learning_step = greatest(sp.learning_step, excluded.learning_step),
          mastered_review_count = greatest(sp.mastered_review_count, excluded.mastered_review_count),
          correct_count = greatest(sp.correct_count, excluded.correct_count),
          wrong_count = greatest(sp.wrong_count, excluded.wrong_count),
          last_result = case
            when excluded.last_studied_on is not null
              and (
                sp.last_studied_on is null
                or excluded.last_studied_on >= sp.last_studied_on
              )
              then coalesce(excluded.last_result, sp.last_result)
            else sp.last_result
          end,
          last_studied_at = case
            when excluded.last_studied_at is null then sp.last_studied_at
            when sp.last_studied_at is null then excluded.last_studied_at
            else greatest(sp.last_studied_at, excluded.last_studied_at)
          end,
          last_studied_on = case
            when excluded.last_studied_on is null then sp.last_studied_on
            when sp.last_studied_on is null then excluded.last_studied_on
            else greatest(sp.last_studied_on, excluded.last_studied_on)
          end,
          next_review_at = greatest(sp.next_review_at, excluded.next_review_at),
          updated_at = timezone('utc'::text, now());

    return query select v_sentence_id;
  end loop;
end;
$$;

revoke all on function public.merge_local_sentence_study_progress(jsonb) from public;
revoke all on function public.merge_local_sentence_study_progress(jsonb) from anon;
grant execute on function public.merge_local_sentence_study_progress(jsonb) to authenticated;
