-- Enforce the per-user limit for both creation RPCs and direct table writes.
-- Existing accounts over the limit keep their themes but cannot add more.
create or replace function public.enforce_study_scene_count_limit()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if tg_op = 'UPDATE' and new.user_id = old.user_id then
    return new;
  end if;

  -- Serialize count + insert across devices and transactions for this owner.
  perform pg_advisory_xact_lock(hashtextextended('study-scene-count:' || new.user_id::text, 0));

  -- Both creation RPCs upsert by (user_id, name). Updating an existing theme
  -- does not consume another slot, including when the account is at its limit.
  if tg_op = 'INSERT' and exists (
    select 1 from public.study_scenes where user_id = new.user_id and name = new.name
  ) then
    return new;
  end if;

  if (select count(*) from public.study_scenes where user_id = new.user_id) >= 20 then
    raise exception using errcode = 'P0001', message = 'study_scene_limit_reached';
  end if;

  return new;
end;
$$;

revoke all on function public.enforce_study_scene_count_limit() from public, anon, authenticated;

drop trigger if exists enforce_study_scene_count_limit_trigger on public.study_scenes;
create trigger enforce_study_scene_count_limit_trigger
before insert or update of user_id on public.study_scenes
for each row execute function public.enforce_study_scene_count_limit();
