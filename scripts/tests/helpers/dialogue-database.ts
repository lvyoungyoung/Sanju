import { PGlite } from "npm:@electric-sql/pglite@0.5.8"
const root = new URL("../../../supabase/migrations/", import.meta.url)
const owner="10000000-0000-4000-8000-000000000001", other="10000000-0000-4000-8000-000000000002"
export async function setupDialogueDatabase() {
  const db=new PGlite()
  await db.exec(`
    create role anon; create role authenticated; create role service_role bypassrls;
    create schema auth; create schema storage;
    create function auth.uid() returns uuid language sql as $$ select nullif(current_setting('test.user_id',true),'')::uuid $$;
    create function auth.jwt() returns jsonb language sql as $$ select '{"is_anonymous":false}'::jsonb $$;
    create table auth.users(id uuid primary key);
    create table profiles(id uuid primary key references auth.users(id),english_level text,speech_voice text,available_generations integer default 10);
    create table memories(id uuid primary key,user_id uuid references profiles(id),image_url text,created_at timestamptz default now(),provider text,tags text[]);
    create table memory_sentences(id uuid primary key,memory_id uuid references memories(id) on delete cascade,sort_order integer,
      english text not null,chinese text not null,learning_topic_ids text[],presentation_group text,is_favorite boolean);
    create table sentence_study_progress(user_id uuid,sentence_id uuid references memory_sentences(id) on delete cascade,correct_count integer default 0);
    create table study_scene_sentences(sentence_id uuid references memory_sentences(id) on delete cascade);
    create table storage.objects(id uuid primary key default gen_random_uuid(),bucket_id text,name text,unique(bucket_id,name));
    create table generation_transactions(user_id uuid,delta integer,balance_after integer,reason text,note text);
    create table generation_jobs(id uuid primary key default gen_random_uuid(),client_request_id uuid unique not null,user_id uuid references profiles(id),
      status text default 'pending',memory_id uuid references memories(id) on delete set null,image_path text,provider text,mimo_failure_reason text,
      remaining_credits integer,error_message text,created_at timestamptz default now(),updated_at timestamptz,completed_at timestamptz,failed_at timestamptz);
    create table guest_generation_jobs(id uuid primary key,user_id uuid references profiles(id),status text default 'pending',image_path text,provider text,
      mimo_failure_reason text,sentences jsonb,tags text[],remaining_credits integer,created_at timestamptz default now(),completed_at timestamptz,acknowledged_at timestamptz,error_message text);
    create function learning_topic_ids_from_json(p_value jsonb) returns text[] language sql as
      $$ select array(select jsonb_array_elements_text(p_value)) $$;
    insert into auth.users values('${owner}'),('${other}'); insert into profiles(id) values('${owner}'),('${other}');
  `)
  for (const file of ["20260826001000_fix_six_sentence_sort_order.sql",
    "20260925000000_add_album_flip_progress.sql","20260921005000_claim_generation_jobs_atomically.sql",
    "20260925001000_defer_generation_enrichment.sql","20260927000000_reuse_generated_sentence_metadata.sql",
    "20261013000000_multilingual_content.sql","20261013002000_multilingual_generation.sql"]) await db.exec(await Deno.readTextFile(new URL(file,root)))
  // Model existing direct REST favorite access, still ANDed with the migrated
  // restrictive ownership policies. Production grants/policies are unchanged.
  await db.exec(`
    grant usage on schema auth to authenticated;
    grant select on memories,memory_sentences to authenticated;
    grant update(is_favorite) on memory_sentences to authenticated;
    create policy fixture_read_memories on memories for select to authenticated using (true);
    create policy fixture_read_sentences on memory_sentences for select to authenticated using (true);
    create policy fixture_update_favorites on memory_sentences for update to authenticated using (true) with check (true);
  `)
  return db
}
