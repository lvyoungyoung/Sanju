-- Anonymous generations receive stable sentence IDs before a memory row exists.
-- Keep their vectors here until the client copies the local memory into an account.
create table if not exists public.guest_sentence_embeddings (
  sentence_id uuid primary key,
  guest_user_id uuid not null references auth.users(id) on delete cascade,
  guest_job_id uuid not null,
  embedding real[] not null check (cardinality(embedding) = 1024),
  model text not null default 'qwen3.7-text-embedding',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists guest_sentence_embeddings_guest_user_id_idx
  on public.guest_sentence_embeddings (guest_user_id);

alter table public.guest_sentence_embeddings enable row level security;

-- A memory copied after login keeps the same sentence IDs. Promote any staged
-- vector at that moment and refresh semantic matches for the newly signed-in user.
create or replace function public.promote_guest_sentence_embedding()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_owner_id uuid;
  v_promoted_count integer := 0;
begin
  select user_id
    into v_owner_id
    from public.memories
   where id = new.memory_id;

  if v_owner_id is null then
    return new;
  end if;

  insert into public.sentence_embeddings (
    sentence_id,
    user_id,
    embedding,
    model,
    updated_at
  )
  select
    staged.sentence_id,
    v_owner_id,
    staged.embedding,
    staged.model,
    now()
  from public.guest_sentence_embeddings as staged
  where staged.sentence_id = new.id
  on conflict (sentence_id) do update
    set user_id = excluded.user_id,
        embedding = excluded.embedding,
        model = excluded.model,
        updated_at = excluded.updated_at;

  get diagnostics v_promoted_count = row_count;

  if v_promoted_count > 0 then
    delete from public.guest_sentence_embeddings
     where sentence_id = new.id;

    perform public.refresh_semantic_study_scene_matches_for_sentence(
      new.id,
      v_owner_id
    );
  end if;

  return new;
end;
$$;

drop trigger if exists promote_guest_sentence_embedding_after_memory_sentence_insert
  on public.memory_sentences;

create trigger promote_guest_sentence_embedding_after_memory_sentence_insert
after insert on public.memory_sentences
for each row
execute function public.promote_guest_sentence_embedding();

revoke all on table public.guest_sentence_embeddings from public, anon, authenticated;
revoke all on function public.promote_guest_sentence_embedding() from public, anon, authenticated;
