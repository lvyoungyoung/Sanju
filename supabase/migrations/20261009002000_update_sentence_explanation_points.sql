-- Keep saved v1 rows intact while accepting the simpler word/phrase + example format.
alter table public.sentence_explanations
  drop constraint sentence_explanations_content_check,
  add constraint sentence_explanations_content_check
    check (content is null or (jsonb_typeof(content) = 'object' and content->>'version' in ('1', '2')));

create or replace function public.finish_sentence_explanation(p_user_id uuid, p_fingerprint text, p_claim_id uuid, p_content jsonb)
returns boolean language plpgsql security definer set search_path = public, pg_temp as $$
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
revoke all on function public.finish_sentence_explanation(uuid, text, uuid, jsonb) from public, anon, authenticated;
grant execute on function public.finish_sentence_explanation(uuid, text, uuid, jsonb) to service_role;
notify pgrst, 'reload schema';
