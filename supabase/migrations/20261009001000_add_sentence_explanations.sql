-- On-demand sentence explanations do not consume image-generation credits.
create table public.sentence_explanations (
  user_id uuid not null references auth.users(id) on delete cascade,
  fingerprint text not null check (fingerprint ~ '^[0-9a-f]{64}$'),
  content jsonb check (content is null or (jsonb_typeof(content) = 'object' and content->>'version' = '1')),
  claim_id uuid,
  lease_until timestamptz,
  created_at timestamptz not null default now(),
  primary key (user_id, fingerprint)
);
alter table public.sentence_explanations enable row level security;
revoke all on public.sentence_explanations from public, anon, authenticated;
grant all on public.sentence_explanations to service_role;

create table public.sentence_explanation_limits (
  user_id uuid primary key references auth.users(id) on delete cascade,
  minute_started_at timestamptz not null,
  minute_count integer not null,
  request_day date not null,
  day_count integer not null
);
alter table public.sentence_explanation_limits enable row level security;
revoke all on public.sentence_explanation_limits from public, anon, authenticated;
grant all on public.sentence_explanation_limits to service_role;

create function public.claim_sentence_explanation(p_user_id uuid, p_fingerprint text, p_generate boolean)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
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

create function public.finish_sentence_explanation(p_user_id uuid, p_fingerprint text, p_claim_id uuid, p_content jsonb)
returns boolean language plpgsql security definer set search_path = public, pg_temp as $$
declare completed uuid;
begin
  if p_content is null or jsonb_typeof(p_content) <> 'object' or p_content->>'version' is distinct from '1' then
    raise exception 'Invalid explanation';
  end if;
  update public.sentence_explanations set content = p_content, claim_id = null, lease_until = null
    where user_id = p_user_id and fingerprint = p_fingerprint and claim_id = p_claim_id
      and content is null and lease_until > now()
    returning user_id into completed;
  return completed is not null;
end;
$$;
revoke all on function public.claim_sentence_explanation(uuid, text, boolean) from public, anon, authenticated;
revoke all on function public.finish_sentence_explanation(uuid, text, uuid, jsonb) from public, anon, authenticated;
grant execute on function public.claim_sentence_explanation(uuid, text, boolean) to service_role;
grant execute on function public.finish_sentence_explanation(uuid, text, uuid, jsonb) to service_role;
notify pgrst, 'reload schema';
