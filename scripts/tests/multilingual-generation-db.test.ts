import { deepStrictEqual, rejects, strictEqual } from "node:assert"
import { PGlite } from "npm:@electric-sql/pglite@0.5.8"
import { sha256 } from "../../supabase/functions/_shared/content-contracts/memory.ts"
import { languageCatalog } from "../../supabase/functions/_shared/languages/main.ts"

const root = new URL("../../supabase/migrations/", import.meta.url)
const owner="10000000-0000-4000-8000-000000000001", other="10000000-0000-4000-8000-000000000002"
const spec={schemaVersion:1,catalogVersion:1,targetLanguage:"en",translationLanguage:"zh-Hans",teachingLocale:"en-US",level:"starter",generationFormat:"dual_tabs_v1"}
const fp="a".repeat(64)
const requestID="20000000-0000-4000-8000-000000000001"
const memoryID="30000000-0000-4000-8000-000000000001"
const memory=(id=memoryID,target="en",translation="zh-Hans",locale="en-US")=>({schemaVersion:2,id,createdAt:"2026-10-13T00:00:00Z",imagePath:`${owner}/${id}.jpg`,
  tags:["pets_and_animals"],context:{schemaVersion:2,targetLanguage:target,translationLanguage:translation,teachingLocale:locale},
  sentences:Array.from({length:6},(_,i)=>({id:crypto.randomUUID(),targetText:"This is a cat.",translationText:"这是一只猫。",contentVersion:1,
    learningTopicIDs:["pets_and_animals"],presentationGroup:i<3?"what_i_see":"what_i_say",isFavorite:false}))})
const value=async(db:PGlite,sql:string,args:unknown[]=[]) => (await db.query<{value:any}>(`select ${sql} as value`,args)).rows[0].value
const claim=(db:PGlite,id=requestID,s=spec,anonymous=false,user=owner,fingerprint=fp)=>value(db,
  "claim_generation_job_v3($1,$2,$3,$4,$5::jsonb,$6,$7::jsonb)",[user,id,anonymous,anonymous?`${user}/guest/${id}.jpg`:null,JSON.stringify(s),fingerprint,'{"version":1}'])
const finalize=(db:PGlite,m:any,id=requestID,anonymous=false,user=owner)=>value(db,
  "finalize_generation_job_v3($1,$2,$3,$4,$5::jsonb,$6,$7::jsonb)",[user,id,anonymous,fp,JSON.stringify(m),"mimo",JSON.stringify(Array(6).fill("Describing a pet."))])
const recover=(db:PGlite,id=requestID,anonymous=false,user=owner)=>value(db,"recover_generation_job_v2($1,$2,$3,null)",[user,id,anonymous])
const importMemory=(db:PGlite,m:any,user=other,guest:string|null=owner)=>value(db,"import_guest_memory_v1($1,$2,$3::jsonb)",[user,guest,JSON.stringify(m)])

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

Deno.test("multilingual generation DB: immutable claims, atomic finalize, capabilities and version fencing", async t=>{
  const db=await setup()
  try {
    await t.step("canonical file, generated resource and DB seed agree; only legacy English is enabled",async()=>{
      const canonical=JSON.parse(await Deno.readTextFile(new URL("../../contracts/languages.v1.json",import.meta.url)))
      deepStrictEqual(languageCatalog,canonical)
      const expected=canonical.generationPairs.map((p:any)=>({target_language:p.targetLanguage,
        translation_language:p.supportLanguage,teaching_locale:canonical.learningLanguages.find((l:any)=>l.id===p.targetLanguage).teachingLocale,
        can_generate:p.targetLanguage==="en" && p.supportLanguage==="zh-Hans"}))
        .sort((a:any,b:any)=>`${a.target_language}/${a.translation_language}`.localeCompare(`${b.target_language}/${b.translation_language}`))
      const actual=(await db.query<any>("select * from language_capabilities_v1")).rows
        .sort((a:any,b:any)=>`${a.target_language}/${a.translation_language}`.localeCompare(`${b.target_language}/${b.translation_language}`))
      deepStrictEqual(actual,expected)
      deepStrictEqual(canonical.selectableLevels,["starter","beginner","intermediate"])
      for(const level of canonical.levels) strictEqual(await value(db,"valid_generation_spec_v3($1::jsonb)",[JSON.stringify({...spec,level})]),true)
    })
    await t.step("RPC permissions are service-only",async()=>{
      for(const signature of ["claim_generation_job_v3(uuid,uuid,boolean,text,jsonb,text,jsonb)","finalize_generation_job_v3(uuid,uuid,boolean,text,jsonb,text,jsonb)",
        "recover_generation_job_v2(uuid,uuid,boolean,text)","import_guest_memory_v1(uuid,uuid,jsonb)"]) {
        for(const role of ["anon","authenticated","service_role"]) strictEqual(await value(db,"has_function_privilege($1,$2,'EXECUTE')",[role,signature]),role==="service_role")
      }
    })
    await t.step("new combinations closed; same request cannot change owner, image digest or spec",async()=>{
      await rejects(()=>claim(db,crypto.randomUUID(),{...spec,targetLanguage:"es",teachingLocale:"es-419"}),/generation_disabled/)
      strictEqual(await claim(db),"acquired")
      strictEqual(await claim(db),"pending")
      await rejects(()=>claim(db,requestID,{...spec,level:"advanced"}),/request_context_mismatch/)
      await rejects(()=>claim(db,requestID,spec,false,owner,"b".repeat(64)),/request_context_mismatch/)
      await rejects(()=>claim(db,requestID,spec,false,other),/generation_job_not_found/)
      await rejects(()=>value(db,"claim_generation_job($1,$2,false,null)",[owner,requestID]),/request_context_mismatch/)
      await rejects(()=>db.query("update generation_jobs set generation_spec=$1::jsonb",[JSON.stringify({...spec,level:"advanced"})]),/request_context_mismatch/)
      strictEqual(await value(db,"has_function_privilege('service_role','claim_generation_job_legacy_internal(uuid,uuid,boolean,text)','EXECUTE')"),false)
    })
    const m=memory()
    await t.step("old finalizers cannot complete a new claim or debit its balance",async()=>{
      const sentences=m.sentences.map(s=>({id:s.id,english:s.targetText,chinese:s.translationText,
        learning_topic_ids:s.learningTopicIDs,presentation_group:s.presentationGroup,is_favorite:false}))
      await rejects(()=>value(db,"finalize_authenticated_generation($1,$2,$3,$4,now(),'mimo',$5::jsonb,'{}')",
        [owner,m.id,requestID,m.imagePath,JSON.stringify(sentences)]),/request_context_mismatch/)
      const guestID=crypto.randomUUID()
      await claim(db,guestID,spec,true)
      await rejects(()=>value(db,"finalize_guest_generation($1,$2,now(),'mimo',$3::jsonb,'{}')",
        [owner,guestID,JSON.stringify(sentences)]),/request_context_mismatch/)
      strictEqual(await value(db,"(select available_generations from profiles where id=$1)",[owner]),10)
      strictEqual(await value(db,"(select count(*) from memories)"),0)
      strictEqual(await value(db,"(select count(*) from generation_transactions)"),0)
    })
    await t.step("invalid output rolls back and valid finalize atomically saves six sentences plus one debit/outbox",async()=>{
      await rejects(()=>finalize(db,{...m,sentences:m.sentences.slice(1)}),/invalid_content/)
      strictEqual(await value(db,"(select available_generations from profiles where id=$1)",[owner]),10)
      strictEqual((await finalize(db,m)).memory.id,m.id)
      strictEqual(await value(db,"(select count(*) from memory_sentences)"),6)
      strictEqual(await value(db,"(select available_generations from profiles where id=$1)",[owner]),9)
      strictEqual(await value(db,"(select count(*) from generation_transactions)"),1)
      strictEqual(await value(db,"(select count(*) from generation_enrichment_jobs)"),1)
      strictEqual((await finalize(db,m)).remainingCredits,9)
      strictEqual(await value(db,"(select count(*) from generation_transactions)"),1)
      deepStrictEqual((await recover(db)).generationSpec,spec)
      strictEqual((await recover(db,requestID,false,other)).status,"not_found")
    })
    await t.step("completed recovery works while capability is disabled, deleted memory is not resurrected",async()=>{
      await db.exec("update language_capabilities_v1 set can_generate=false")
      strictEqual(await claim(db),"completed")
      strictEqual((await recover(db)).memory.id,m.id)
      await db.query("delete from memories where id=$1",[m.id])
      strictEqual((await recover(db)).memory,null)
      strictEqual((await finalize(db,m)).memory,null)
      strictEqual(await value(db,"(select count(*) from memories)"),0)
    })
  } finally {await db.close()}
})

Deno.test("multilingual generation DB: guest finalize/import identity, local copies, rollback and no credit grants",async t=>{
  const db=await setup()
  try {
    const id=crypto.randomUUID()
    await claim(db,id,spec,true)
    const original=memory(id); original.imagePath=`${owner}/guest/${id}.jpg`
    const result=await finalize(db,original,id,true)
    const imported={...result.memory,imagePath:`${other}/${id}.jpg`}
    await t.step("guest recovery returns original context and IDs with image separately",async()=>{
      const recovered=await recover(db,id,true)
      strictEqual(recovered.guestImagePath,original.imagePath)
      strictEqual(recovered.memory.imagePath,"")
      deepStrictEqual(recovered.memory.sentences.map((s:any)=>s.id),original.sentences.map(s=>s.id))
      await rejects(()=>db.query("update guest_generation_jobs set result_content='{}' where id=$1",[id]),/immutable_generation_result/)
    })
    await t.step("guest proof binds source owner, imports once and never changes either credit balance",async()=>{
      await rejects(()=>importMemory(db,imported,other,null),/content_conflict/)
      strictEqual((await importMemory(db,imported)).imported,true)
      strictEqual((await importMemory(db,imported)).alreadyImported,true)
      strictEqual(await value(db,"(select available_generations from profiles where id=$1)",[owner]),9)
      strictEqual(await value(db,"(select available_generations from profiles where id=$1)",[other]),10)
      const changed=structuredClone(imported); changed.sentences[0].targetText="Not the same sentence."
      await rejects(()=>importMemory(db,changed),/content_conflict/)
      await db.query("update memory_sentences set is_favorite=true where id=$1",[imported.sentences[0].id])
      await importMemory(db,imported)
      strictEqual(await value(db,"(select is_favorite from memory_sentences where id=$1)",[imported.sentences[0].id]),true)
    })
    await t.step("deleted imported memory is not resurrected by retry",async()=>{
      await db.query("delete from memories where id=$1",[id])
      strictEqual((await importMemory(db,imported)).alreadyImported,true)
      strictEqual(await value(db,"(select count(*) from memories)"),0)
    })
    await t.step("expired-job local copies supported, duplicate sentence insert rolls back entire memory",async()=>{
      const local={...memory(crypto.randomUUID()),imagePath:""}
      strictEqual((await importMemory(db,local,other,null)).imported,true)
      const broken={...memory(crypto.randomUUID()),imagePath:""}; broken.sentences[4].id=local.sentences[0].id
      await rejects(()=>importMemory(db,broken,other,null),/duplicate key/)
      strictEqual(await value(db,"(select count(*) from memories where id=$1)",[broken.id]),0)
      strictEqual(await value(db,"(select count(*) from memory_sentences where memory_id=$1)",[broken.id]),0)
    })
    await t.step("Japanese imported material is digest-bound and immutable body is not rewritten",async()=>{
      const ja:any={...memory(crypto.randomUUID(),"ja","en","ja-JP"),imagePath:""}
      for (const s of ja.sentences) {
        s.targetText="猫です。"; s.translationText="It is a cat."
        s.learningMaterial={schemaVersion:1,policyVersion:1,textDigest:await sha256(s.targetText),segments:[
          {id:"1",surface:"猫",reading:"ねこ",kind:"word",canBlank:true},
          {id:"2",surface:"です。",kind:"phrase",canBlank:false}]}
      }
      strictEqual((await importMemory(db,ja,other,null)).imported,true)
      const invalid=structuredClone(ja); invalid.id=crypto.randomUUID(); invalid.sentences[0].learningMaterial.textDigest="0".repeat(64)
      await rejects(()=>importMemory(db,invalid,other,null),/invalid_learning_material/)
    })
  }finally{await db.close()}
})

Deno.test("multilingual generation DB: Spanish/French materials and early/late guest vectors retain ownership",async()=>{
  const db=await setup()
  try {
    for(const [language,locale,text] of [["es","es-419","El café está caliente."],["fr","fr-FR","Le café est chaud."]]) {
      const s={...spec,targetLanguage:language,teachingLocale:locale}
      await db.query("update language_capabilities_v1 set can_generate=true where target_language=$1 and translation_language='zh-Hans'",[language])
      const id=crypto.randomUUID()
      await claim(db,id,s,true)
      const m:any=memory(id,language,"zh-Hans",locale)
      m.imagePath=`${owner}/guest/${id}.jpg`
      for(const sentence of m.sentences) {
        sentence.targetText=text
        sentence.learningMaterial={schemaVersion:1,policyVersion:1,textDigest:await sha256(text),segments:[
          {id:"1",surface:text.slice(0,-1),kind:"phrase",canBlank:true},{id:"2",surface:".",kind:"punctuation",canBlank:false}]}
      }
      const invalid=structuredClone(m); delete invalid.sentences[0].learningMaterial
      await rejects(()=>finalize(db,invalid,id,true),/invalid_learning_material/)
      const finalized=await finalize(db,m,id,true)
      const lease=crypto.randomUUID()
      await db.query("update generation_enrichment_jobs set status='processing',lease_token=$1,lease_until=now()+interval '1 minute' where guest_job_id=$2",[lease,id])
      const job=await value(db,"(select id from generation_enrichment_jobs where guest_job_id=$1)",[id])
      const rows=m.sentences.map((sentence:any)=>({sentence_id:sentence.id,model:"qwen3.7-text-embedding:multilingual-v1",
        embedding:Array(1024).fill(0.01),purpose_embedding:Array(1024).fill(0.02)}))
      const finish=()=>value(db,"complete_multilingual_generation_enrichment_v1($1,$2,$3::jsonb)",[job,lease,JSON.stringify(rows)])
      await rejects(()=>value(db,"complete_generation_enrichment($1,$2,$3::jsonb)",[job,lease,JSON.stringify(rows)]),/legacy_enrichment_only/)
      if(language==="es") strictEqual(await finish(),true)
      await importMemory(db,{...finalized.memory,imagePath:`${other}/${id}.jpg`})
      strictEqual(await value(db,"promote_guest_sentence_embedding_for_id($1)",[m.sentences[0].id]),false)
      if(language==="fr") strictEqual(await finish(),true)
      strictEqual(await finish(),false)
      strictEqual(await value(db,"(select count(*) from multilingual_sentence_embeddings_v1 where memory_id=$1 and user_id=$2 and guest_job_id is null)",[id,other]),6)
      await db.query("delete from memories where id=$1",[id])
      strictEqual(await value(db,"(select count(*) from multilingual_sentence_embeddings_v1 where memory_id=$1)",[id]),0)
    }
  }finally{await db.close()}
})
