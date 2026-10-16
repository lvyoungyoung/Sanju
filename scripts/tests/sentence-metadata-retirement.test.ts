import { deepStrictEqual, rejects, strictEqual, ok } from "node:assert"
import { PGlite } from "npm:@electric-sql/pglite@0.5.8"
const root = new URL("../../supabase/migrations/", import.meta.url)
const owner="10000000-0000-4000-8000-000000000001", other="10000000-0000-4000-8000-000000000002"
const value=async(db:PGlite,sql:string,args:unknown[]=[]) => (await db.query<{value:any}>(`select ${sql} as value`,args)).rows[0].value
async function setup() {
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
  for (const file of ["20260925000000_add_album_flip_progress.sql","20260921005000_claim_generation_jobs_atomically.sql",
    "20260925001000_defer_generation_enrichment.sql","20260927000000_reuse_generated_sentence_metadata.sql",
    "20261013000000_multilingual_content.sql","20261013002000_multilingual_generation.sql"]) await db.exec(await Deno.readTextFile(new URL(file,root)))
  return db
}

const migration = new URL("20261016000000_remove_sentence_metadata.sql",root)
const spec={schemaVersion:1,catalogVersion:1,targetLanguage:"en",translationLanguage:"zh-Hans",teachingLocale:"en-US",level:"starter",generationFormat:"dual_tabs_v1"}
const fp="a".repeat(64)
const memory=(id=crypto.randomUUID())=>({schemaVersion:2,id,createdAt:"2026-10-16T00:00:00Z",imagePath:`${owner}/${id}.jpg`,
 tags:["pets_and_animals"],context:{schemaVersion:2,targetLanguage:"en",translationLanguage:"zh-Hans",teachingLocale:"en-US"},
 sentences:Array.from({length:6},(_,i)=>({id:crypto.randomUUID(),targetText:"This is a cat.",translationText:"这是一只猫。",contentVersion:1,
 presentationGroup:i<3?"what_i_see":"what_i_say",isFavorite:false}))})
const claim=(db:PGlite,id:string,anonymous=false)=>value(db,"claim_generation_job_v3($1,$2,$3,$4,$5::jsonb,$6,$7::jsonb)",
 [owner,id,anonymous,anonymous?`${owner}/guest/${id}.jpg`:null,JSON.stringify(spec),fp,'{"version":1}'])
const finalize=(db:PGlite,m:any,id:string,anonymous=false)=>value(db,"finalize_generation_job_v3($1,$2,$3,$4,$5::jsonb,$6)",
 [owner,id,anonymous,fp,JSON.stringify(m),"deepseek"])

Deno.test("metadata retirement: generation, recovery, guest migration and history survive", async t=>{
 const db=await setup()
 try {
  // Seed a genuinely completed old guest result and metadata outbox before migration.
  const oldID=crypto.randomUUID(), oldMemory=memory(oldID)
  oldMemory.imagePath=`${owner}/guest/${oldID}.jpg`
  const oldPayload={...oldMemory,sentences:oldMemory.sentences.map(s=>({...s,learningTopicIDs:["pets_and_animals"]}))}
  await claim(db,oldID,true)
  await value(db,"finalize_generation_job_v3($1,$2,true,$3,$4::jsonb,'mimo',$5::jsonb)",
   [owner,oldID,fp,JSON.stringify(oldPayload),JSON.stringify(Array(6).fill("Describe a pet."))])
  // Derived data and triggers are present, not just an empty schema.
  await db.exec(`
    create table sentence_embeddings(sentence_id uuid primary key, expression_purpose text, embedding real[], purpose_embedding real[]);
    create table guest_sentence_embeddings(sentence_id uuid primary key, expression_purpose text, embedding real[], purpose_embedding real[]);
    create table learning_topic_embeddings(topic_id text primary key, embedding real[]);
    create table study_scene_embeddings(scene_id uuid primary key, embedding real[]);
    insert into guest_sentence_embeddings values(gen_random_uuid(),'Describe a pet.',array[1.0],array[1.0]);
    create function preserve_enriched_sentence_categories() returns trigger language plpgsql as $$
      begin new.learning_topic_ids:='{}'; return new; end $$;
    create trigger preserve_enriched_sentence_categories before insert or update on memory_sentences
      for each row execute function preserve_enriched_sentence_categories();
  `)
  await db.exec(await Deno.readTextFile(migration))
  await t.step("removed tables/columns and service-only finalization",async()=>{
   for(const table of ["generation_enrichment_jobs","multilingual_sentence_embeddings_v1","sentence_embeddings","guest_sentence_embeddings"])
    strictEqual(await value(db,"to_regclass($1)",["public."+table]),null)
   strictEqual(await value(db,"(select count(*) from information_schema.columns where table_name='memory_sentences' and column_name='learning_topic_ids')"),0)
   for(const role of ["anon","authenticated","service_role"])
    strictEqual(await value(db,"has_function_privilege($1,'finalize_generation_job_v3(uuid,uuid,boolean,text,jsonb,text)','EXECUTE')",[role]),role==="service_role")
  })
  await t.step("old guest recovery strips only derived fields and import is idempotent",async()=>{
   const result=await value(db,"recover_generation_job_v2($1,$2,true,null)",[owner,oldID])
   ok(result.memory.sentences.every((s:any)=>!("learningTopicIDs" in s)))
   deepStrictEqual(result.memory.tags,oldMemory.tags)
   const imported={...result.memory,imagePath:`${other}/${oldID}.jpg`}
   for(let i=0;i<2;i++) await value(db,"import_guest_memory_v1($1,$2,$3::jsonb)",[other,owner,JSON.stringify(imported)])
   strictEqual(await value(db,"(select count(*) from memory_sentences)"),6)
   strictEqual(await value(db,"(select available_generations from profiles where id=$1)",[other]),10)
   await rejects(()=>db.query("update guest_generation_jobs set result_content='{}' where id=$1",[oldID]),/immutable_generation_result/)
  })
  await t.step("new guest generation ignores unsolicited metadata and preserves recovery identity",async()=>{
   const id=crypto.randomUUID(),m=memory(id)
   m.imagePath=`${owner}/guest/${id}.jpg`
   await claim(db,id,true)
   const payload={...m,sentences:m.sentences.map(s=>({...s,learningTopicIDs:["pets_and_animals"],expressionPurpose:"Describe a pet."}))}
   const result=await finalize(db,payload,id,true)
   deepStrictEqual(result.memory.sentences,m.sentences)
   strictEqual(result.guestImagePath,m.imagePath)
   strictEqual((await finalize(db,payload,id,true)).remainingCredits,result.remainingCredits)
  })
  await t.step("new six-sentence generation debits once and round-trips without metadata",async()=>{
   const id=crypto.randomUUID(),m=memory()
   await claim(db,id)
   const first=await finalize(db,m,id)
   strictEqual(first.remainingCredits,7)
   strictEqual((await finalize(db,m,id)).remainingCredits,7)
   deepStrictEqual(first.memory.sentences,m.sentences)
   deepStrictEqual(first.memory.tags,m.tags)
   await db.query("update memory_sentences set is_favorite=true where id=$1",[m.sentences[0].id])
   await db.query("insert into sentence_study_progress(user_id,sentence_id,correct_count) values($1,$2,3)",[owner,m.sentences[0].id])
   const restored=await value(db,"memory_content_dto_v2($1)",[m.id])
   strictEqual(restored.sentences[0].isFavorite,true)
   strictEqual(await value(db,"(select correct_count from sentence_study_progress where sentence_id=$1)",[m.sentences[0].id]),3)
  })
  await t.step("invalid output rolls back without debit; legacy generation still saves photo tags",async()=>{
   const id=crypto.randomUUID(),m=memory()
   await claim(db,id)
   await rejects(()=>finalize(db,{...m,sentences:m.sentences.slice(1)},id),/invalid_content/)
   strictEqual(await value(db,"(select available_generations from profiles where id=$1)",[owner]),7)
   const sentences=m.sentences.map(s=>({id:s.id,english:s.targetText,chinese:s.translationText,presentation_group:s.presentationGroup,is_favorite:false}))
   // Photo normalization exists on deployed databases; this small harness supplies the catalog helper.
   await db.exec("create function normalize_memory_photo_categories(text[]) returns text[] language sql as $$ select $1 $$")
   await value(db,"finalize_authenticated_generation($1,$2,null,$3,now(),'deepseek',$4::jsonb,$5::text[])",
    [owner,m.id,m.imagePath,JSON.stringify(sentences),m.tags])
   strictEqual(await value(db,"(select count(*) from memory_sentences where memory_id=$1)",[m.id]),6)
  })
 } finally {await db.close()}
})
