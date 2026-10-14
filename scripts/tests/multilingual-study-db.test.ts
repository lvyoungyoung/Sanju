import { deepStrictEqual, ok, rejects, strictEqual } from "node:assert";
import { PGlite } from "npm:@electric-sql/pglite@0.5.8";

const root = new URL("../../", import.meta.url);
const read = (path: string) => Deno.readTextFile(new URL(path, root));
const owner = "10000000-0000-0000-0000-000000000001";
const other = "10000000-0000-0000-0000-000000000002";
const mid = (n: number) => `20000000-0000-0000-0000-${String(n).padStart(12, "0")}`;
const sid = (n: number) => `40000000-0000-0000-0000-${String(n).padStart(12, "0")}`;
const scene = "30000000-0000-0000-0000-000000000001";
const migration = await read("supabase/migrations/20261013003000_multilingual_study.sql");

async function setup() {
  const db = new PGlite();
  const prior = await read("scripts/tests/semantic-study-scene-matching.test.ts");
  const schema = prior.match(/const schema = `([\s\S]*?)`;/)![1];
  await db.exec(schema);
  await db.exec(`
    grant usage on schema auth to authenticated,anon;
    alter table memories add target_language text not null default 'en',
      add translation_language text not null default 'zh-Hans', add teaching_locale text not null default 'en-US';
    alter table memory_sentences add target_text text not null default 'Exact source.',
      add translation_text text not null default 'Translation.', add learning_material jsonb;
    alter table sentence_study_progress add learning_step integer not null default 0,
      add mastered_review_count integer not null default 0, add wrong_count integer not null default 0,
      add last_result text, add last_studied_at timestamptz, add updated_at timestamptz default now(),
      add constraint sentence_study_progress_user_id_sentence_id_scope_key unique(user_id,sentence_id,study_scope);
    alter table sentence_study_progress drop constraint sentence_study_progress_sentence_id_fkey,
      add foreign key(sentence_id) references memory_sentences(id) on delete cascade;
    insert into auth.users values('${owner}'),('${other}');
    insert into memories(id,user_id) values('${mid(1)}','${owner}');
    insert into memory_sentences(id,memory_id,is_favorite) values('${sid(999)}','${mid(1)}',true);
    insert into sentence_study_progress(user_id,sentence_id,study_scope,correct_count,learning_step)
      values('${owner}','${sid(999)}','favorites',4,4);
    select set_config('request.jwt.claim.sub','${owner}',false);
  `);
  await db.exec(await read("supabase/migrations/20260921000000_use_device_study_time_zone.sql"));
  await db.exec(await read("supabase/migrations/20260921004000_use_oldest_study_scene_cover.sql"));
  await db.exec(await read("supabase/migrations/20260812007000_add_study_scene_detail_sentences.sql"));
  await db.exec(migration);
  await db.exec(`
    insert into memories(id,user_id,target_language,translation_language,teaching_locale) values
      ('${mid(2)}','${owner}','ja','zh-Hans','ja-JP'),
      ('${mid(3)}','${owner}','en','es','en-US'),
      ('${mid(4)}','${other}','en','zh-Hans','en-US');
    insert into study_scenes(id,user_id,name) values('${scene}','${owner}','Mixed scene');
  `);
  for (let i = 1; i <= 70; i++) {
    await db.query(`insert into memory_sentences(id,memory_id,is_favorite,sort_order)
      values($1,$2,true,$3)`, [sid(i), mid(i <= 35 ? 1 : 2), i]);
    await db.query("insert into study_scene_sentences(scene_id,sentence_id,match_score) values($1,$2,100)", [scene, sid(i)]);
  }
  await db.query("insert into memory_sentences(id,memory_id,is_favorite) values($1,$2,true),($3,$4,true)", [sid(71),mid(3),sid(72),mid(4)]);
  await db.exec("grant select on memories,memory_sentences,sentence_study_progress to authenticated; set role authenticated");
  return db;
}

async function value(db: PGlite, expression: string, args: unknown[] = []): Promise<any> {
  return (await db.query<{v: any}>(`select ${expression} as v`, args)).rows[0].v;
}
const begin = (db: PGlite, lang = "en", count = 5, id = crypto.randomUUID(), mode = "due", scope = "favorites") =>
  value(db, "begin_study_session_v2($1,$2,$3,$4,$5,'UTC')", [id,lang,scope,count,mode]);
const overview = (db: PGlite, lang = "en") => value(db, "get_study_overview_v2($1,'favorites','UTC')", [lang]);
async function adminValue(db: PGlite, expr: string) {
  await db.exec("reset role");
  try { return await value(db,expr); } finally { await db.exec("set role authenticated"); }
}

Deno.test("multilingual study: budget, identity, language and legacy contracts", async (t) => {
  const db = await setup();
  try {
    await t.step("migration preserves progress and seeds no-cost historical activations; stats are read-only", async () => {
      strictEqual(await value(db, `(select correct_count from sentence_study_progress where sentence_id='${sid(999)}')`),4);
      strictEqual((await overview(db)).remaining_new,30);
      await overview(db,"ja");
      await value(db,"count_sentence_study_queue()");
      strictEqual(await adminValue(db,"(select count(*) from study_sessions)"),0);
      strictEqual(await adminValue(db,"(select count(*) from sentence_study_activations where source='baseline')"),1);
    });
    let english: any;
    await t.step("one account budget across languages and scopes with deterministic retry/conflict", async () => {
      const id = crypto.randomUUID();
      english = await begin(db,"en",30,id);
      // Historical unfinished progress is also eligible; exactly 29 new claims here.
      strictEqual(english.items.length,30);
      strictEqual(english.remaining_new,1);
      deepStrictEqual(await begin(db,"en",30,id),english);
      await rejects(() => begin(db,"ja",30,id),/study_session_conflict/);
      const japanese = await begin(db,"ja",30);
      strictEqual(japanese.items.length,1);
      strictEqual(japanese.remaining_new,0);
      strictEqual(japanese.items[0].target_language,"ja");
      const sceneQueue = await begin(db,"ja",30,crypto.randomUUID(),"due",`scene:${scene}`);
      deepStrictEqual(sceneQueue.sentence_ids,japanese.sentence_ids);
      strictEqual(await adminValue(db,"(select count(*) from sentence_study_activations where source<>'baseline')"),30);
      ok(english.items.every((i: any) => i.target_language==="en"));
      ok(!english.sentence_ids.includes(sid(72)));
    });
    await t.step("legacy stale queues cannot bypass budget or access en/es content", async () => {
      const old = (await db.query<any>("select * from get_sentence_study_queue(1000)")).rows;
      ok(old.length>0);
      ok(old.every(i => i.english==="Exact source." && ![sid(71),sid(72)].includes(i.sentence_id)));
      await rejects(() => value(db,"record_sentence_study_result($1,true)",[sid(35)]),/study_daily_new_limit/);
      await rejects(() => value(db,"record_sentence_study_result($1,true)",[sid(71)]),/not available/);
      await rejects(() => db.query("insert into sentence_study_progress(user_id,sentence_id,study_scope) values($1,$2,'favorites')",[owner,sid(35)]),/permission denied/);
      const scenes=(await db.query<any>("select * from get_study_scenes()")).rows;
      strictEqual(scenes[0].total_count,35);
      const details=(await db.query<any>("select * from get_study_scene_detail_sentences($1)",[scene])).rows;
      strictEqual(details.length,35);
      ok(details.every(i=>i.memory_id===mid(1)));
    });
    await t.step("same event returns its receipt; new same-day event does not advance twice", async () => {
      const sentence = english.sentence_ids.find((id: string) => id!==sid(999) && id!==sid(71));
      const event = crypto.randomUUID();
      const time=await adminValue(db,"now()::text");
      const call=(id=event,correct=true) => value(db,"record_study_event_v2($1,$2,$3,$4,$5,'UTC')",[id,english.session_id,sentence,correct,time]);
      const first=await call();
      strictEqual(first.learning_step,1);
      strictEqual(first.correct_count,1);
      deepStrictEqual(await call(),first);
      deepStrictEqual(await call(crypto.randomUUID()),first);
      await rejects(() => call(event,false),/study_event_conflict/);
      strictEqual((await begin(db,"en",100,crypto.randomUUID(),"today")).items.length,1);
      strictEqual((await overview(db)).remaining_new,0);
      // Legacy aggregate must exclude today's Japanese progress.
      const ja=await begin(db,"ja",5);
      await value(db,"record_study_event_v2($1,$2,$3,true,now(),'UTC')",[crypto.randomUUID(),ja.session_id,ja.sentence_ids[0]]);
      strictEqual(await value(db,"count_sentence_studied_today()"),1);
      const progress=(await db.query<any>("select * from get_sentence_study_progress_v2('ja')")).rows;
      strictEqual(progress.length,1);
      strictEqual(progress[0].sentence_id,ja.sentence_ids[0]);
      strictEqual((await db.query("select * from get_sentence_study_progress_v2()")).rows.length,3);
      await rejects(()=>db.query("select * from get_sentence_study_progress_v2('xx')"),/invalid_study_filter/);
    });
    await t.step("delete cannot refund or resurrect a sentence on retry", async () => {
      const target=english.sentence_ids.find((id: string) => id!==sid(999));
      await db.exec("reset role");
      await db.query("delete from memory_sentences where id=$1",[target]);
      await db.exec("set role authenticated");
      const retry=await begin(db,"en",30,english.session_id);
      ok(retry.sentence_ids.includes(target));
      ok(!retry.items.some((i: any)=>i.sentence_id===target));
      strictEqual(retry.remaining_new,0);
      await rejects(() => value(db,"record_study_event_v2($1,$2,$3,true,now(),'UTC')",[crypto.randomUUID(),english.session_id,target]),/unavailable/);
    });
    await t.step("invalid auth, zones, scope and event times are rejected; internals inaccessible", async () => {
      await rejects(() => value(db,"get_study_overview_v2('ja','favorites','Not/AZone')"),/invalid_study_time_zone/);
      await rejects(() => begin(db,"ja",5,crypto.randomUUID(),"due","scene:garbage"),/invalid_study_scope/);
      await rejects(() => value(db,"_study_remaining_v2('UTC')"),/permission denied/);
      await rejects(() => value(db,"_merge_local_study_progress_v1('[]')"),/permission denied/);
      await rejects(() => value(db,"record_study_event_v2($1,$2,$3,true,now()+interval '1 day','UTC')",[crypto.randomUUID(),english.session_id,english.sentence_ids[2]]),/invalid_study_event_time/);
      await db.query("select set_config('request.jwt.claim.sub',$1,false)",[other]);
      strictEqual((await overview(db)).remaining_new,30);
      await rejects(() => value(db,"record_study_event_v2($1,$2,$3,true,now(),'UTC')",[crypto.randomUUID(),english.session_id,english.sentence_ids[2]]),/unavailable/);
      await db.exec("set request.jwt.claim.sub=''");
      await rejects(() => overview(db),/authentication_required/);
    });
  } finally { await db.close(); }
});

Deno.test("multilingual study: direct nonfavorite sessions enforce ownership, shared budget and immutable retries", async () => {
  const db=await setup();
  const id=crypto.randomUUID();
  const direct=(sentence=sid(36),session=id,zone="UTC")=>value(db,"begin_direct_study_session_v2($1,$2,$3)",[session,sentence,zone]);
  try {
    await db.exec("reset role");
    await db.query("update memory_sentences set is_favorite=false where id=$1",[sid(36)]);
    await db.exec("set role authenticated");
    const first=await direct();
    strictEqual(first.remaining_new,29);
    deepStrictEqual(first.sentence_ids,[sid(36)]);
    strictEqual(first.items[0].target_language,"ja");
    deepStrictEqual(await direct(),first);
    strictEqual(await value(db,"(select is_favorite from memory_sentences where id=$1)",[sid(36)]),false);
    await rejects(()=>direct(sid(37)),/study_session_conflict/);
    await rejects(()=>direct(sid(36),id,"Asia/Tokyo"),/study_session_conflict/);
    await rejects(()=>begin(db,"ja",1,id),/study_session_conflict/);
    await rejects(()=>begin(db,"ja",1,id,"direct"),/invalid_study_filter/);
    await rejects(()=>direct(sid(72),crypto.randomUUID()),/study_sentence_unavailable/);
    await rejects(()=>direct(sid(36),crypto.randomUUID(),"Invalid/Zone"),/invalid_study_time_zone/);
    const progress=await value(db,"record_study_event_v2($1,$2,$3,true,now(),'UTC')",[crypto.randomUUID(),id,sid(36)]);
    strictEqual(progress.learning_step,1);
    strictEqual(progress.study_scope,"favorites");
    strictEqual((await direct()).items[0].learning_step,1);
    await begin(db,"en",100);
    strictEqual((await direct(sid(36),crypto.randomUUID())).remaining_new,0);
    const blocked=crypto.randomUUID();
    await rejects(()=>direct(sid(37),blocked),/study_daily_new_limit/);
    strictEqual(await adminValue(db,`(select count(*) from study_sessions where session_id='${blocked}')`),0);
    await db.query("select set_config('request.jwt.claim.sub',$1,false)",[other]);
    await rejects(()=>direct(),/study_sentence_unavailable/);
    await db.query("select set_config('request.jwt.claim.sub',$1,false)",[owner]);
    await db.exec("reset role");
    await db.query("delete from memory_sentences where id=$1",[sid(36)]);
    await db.exec("set role authenticated");
    const deleted=await direct();
    deepStrictEqual(deleted.sentence_ids,[sid(36)]);
    deepStrictEqual(deleted.items,[]);
    strictEqual(deleted.remaining_new,0);
    await rejects(()=>value(db,"record_study_event_v2($1,$2,$3,true,now(),'UTC')",[crypto.randomUUID(),id,sid(36)]),/unavailable/);
    strictEqual(await value(db,"has_function_privilege('anon','begin_direct_study_session_v2(uuid,uuid,text)','EXECUTE')"),false);
    await db.exec("set request.jwt.claim.sub=''");
    await rejects(()=>direct(),/authentication_required/);
  } finally { await db.close(); }
});

Deno.test("multilingual study: guest activation import includes unfinished, unfavorited and deleted work without granting ownership",async(t)=>{
  const db=await setup();
  const merge=(items:unknown[])=>db.query<any>("select * from merge_local_sentence_study_progress_v2($1::jsonb)",[JSON.stringify(items)]);
  try {
    const now=await adminValue(db,"now()::text");
    const activation=(id:string)=>({sentence_id:id,study_scope:"favorites",first_activated_at:now,
      learning_step:0,mastered_review_count:0,correct_count:0,wrong_count:0,last_result:null,last_studied_at:null});
    const items=[{...activation(sid(1)),learning_step:2,correct_count:2,last_result:"correct",last_studied_at:now},
      activation(sid(36)),activation(sid(37)),activation(sid(900))];
    await db.exec("reset role");
    await db.query("update memory_sentences set is_favorite=false where id=any($1::uuid[])",[[sid(1),sid(36)]]);
    await db.query("delete from memory_sentences where id=$1",[sid(37)]);
    await db.exec("set role authenticated");
    await t.step("accept owned nonfavorite progress and activation-only/deleted quota receipts",async()=>{
      deepStrictEqual((await merge(items)).rows,items.map(i=>({sentence_id:i.sentence_id,study_scope:"favorites"})));
      strictEqual((await overview(db)).remaining_new,26);
      strictEqual(await value(db,"(select correct_count from sentence_study_progress where sentence_id=$1)",[sid(1)]),2);
      strictEqual(await value(db,"(select count(*) from sentence_study_progress where sentence_id=any($1::uuid[]))",[[sid(36),sid(37),sid(900)]]),0);
      strictEqual(await value(db,"(select is_favorite from memory_sentences where id=$1)",[sid(1)]),false);
      strictEqual(await value(db,"(select count(*) from memory_sentences where id=any($1::uuid[]))",[[sid(37),sid(900)]]),0);
      // A self-reported quota receipt never authorizes studying absent or foreign content.
      for(const id of [sid(37),sid(900),sid(72)]) await rejects(()=>value(db,"begin_direct_study_session_v2($1,$2,'UTC')",[crypto.randomUUID(),id]),/unavailable/);
    });
    await t.step("retries and backdated repeats cannot refund a used slot or fabricate unfinished progress",async()=>{
      await merge(items);
      await merge(items.map(i=>({...i,first_activated_at:"1970-01-01T00:00:00Z",learning_step:0,correct_count:0,last_result:null,last_studied_at:null})));
      strictEqual((await overview(db)).remaining_new,26);
      strictEqual(await value(db,"(select correct_count from sentence_study_progress where sentence_id=$1)",[sid(1)]),2);
      const direct=await value(db,"begin_direct_study_session_v2($1,$2,'UTC')",[crypto.randomUUID(),sid(36)]);
      strictEqual(direct.remaining_new,26);
      strictEqual(direct.items[0].learning_step,0);
    });
    await t.step("foreign IDs, unsupported scopes and malformed activations are not acknowledged",async()=>{
      const bad=[activation(sid(72)),{sentence_id:sid(901)},
        {...activation(sid(902)),first_activated_at:"infinity"},
        {...activation(sid(903)),first_activated_at:"2100-01-01T00:00:00Z"},
        {...activation(sid(904)),study_scope:`scene:${scene}`},
        {...activation(sid(905)),correct_count:-1},
        {...activation(sid(906)),last_studied_at:"-infinity"},
        {...activation(sid(907)),last_studied_on:"infinity"},
        {...activation(sid(908)),next_review_on:"infinity"},
        {...activation(sid(909)),learning_step:999999999999},
        {...activation(sid(911)),next_review_on:"400000-01-01"},{sentence_id:sid(38)},null];
      deepStrictEqual((await merge(bad)).rows,[]);
      strictEqual((await overview(db)).remaining_new,26);
      strictEqual(await adminValue(db,`(select count(*) from sentence_study_activations where user_id='${other}')`),0);
      // Legacy merger retains its favorites-only and live-English contract.
      strictEqual((await db.query("select * from merge_local_sentence_study_progress($1::jsonb)",[JSON.stringify(items)])).rows.length,0);
    });
    await t.step("late content upload does not lose completed progress or double-charge activation",async()=>{
      const pending={...activation(sid(910)),learning_step:1,correct_count:1,last_result:"correct",last_studied_at:now};
      deepStrictEqual((await merge([pending])).rows,[]);
      strictEqual((await overview(db)).remaining_new,25);
      await db.exec("reset role");
      await db.query("insert into memory_sentences(id,memory_id,is_favorite) values($1,$2,false)",[sid(910),mid(1)]);
      await db.exec("set role authenticated");
      deepStrictEqual((await merge([pending])).rows,[{sentence_id:sid(910),study_scope:"favorites"}]);
      strictEqual((await overview(db)).remaining_new,25);
      strictEqual(await value(db,"(select correct_count from sentence_study_progress where sentence_id=$1)",[sid(910)]),1);
    });
    await t.step("offline overflow persists all debits, then blocks new study globally",async()=>{
      const deleted=Array.from({length:35},(_,i)=>activation(sid(1000+i)));
      strictEqual((await merge(deleted)).rows.length,35);
      strictEqual((await overview(db)).remaining_new,0);
      strictEqual((await overview(db,"ja")).remaining_new,0);
      strictEqual(await adminValue(db,"(select count(*) from sentence_study_activations where source='import')"),40);
      await rejects(()=>value(db,"begin_direct_study_session_v2($1,$2,'UTC')",[crypto.randomUUID(),sid(38)]),/study_daily_new_limit/);
      strictEqual((await value(db,"begin_direct_study_session_v2($1,$2,'UTC')",[crypto.randomUUID(),sid(36)])).items.length,1);
      await db.exec("set request.jwt.claim.sub=''");
      await rejects(()=>merge(deleted),/authentication_required/);
    });
  } finally {await db.close();}
});

Deno.test("multilingual study: import overflow, time boundaries and stale events", async (t) => {
  const db=await setup();
  try {
    await t.step("legacy merge cannot touch other languages; v2 imports are idempotent and can exceed 30",async()=>{
      const now=await adminValue(db,"now()::text");
      const items=Array.from({length:40},(_,i)=>({sentence_id:sid(i+1),correct_count:1,learning_step:1,last_studied_at:now,first_activated_at:now}));
      const old=(await db.query("select * from merge_local_sentence_study_progress($1)",[JSON.stringify(items)])).rows;
      strictEqual(old.length,35);
      const newer=()=>db.query("select * from merge_local_sentence_study_progress_v2($1)",[JSON.stringify(items)]);
      strictEqual((await newer()).rows.length,40);
      await newer();
      strictEqual(await adminValue(db,"(select count(*) from sentence_study_activations where source='import')"),40);
      strictEqual((await overview(db)).remaining_new,0);
      strictEqual(await value(db,`(select correct_count from sentence_study_progress where sentence_id='${sid(1)}')`),1);
    });
    await t.step("new day allows 30; unfinished activated sentences do not spend a second slot",async()=>{
      await db.exec("reset role");
      await db.exec("update sentence_study_activations set first_activated_at=now()-interval '2 days' where source='import'");
      await db.exec("set role authenticated");
      strictEqual((await overview(db)).remaining_new,30);
      const session=await begin(db,"ja",30);
      strictEqual(session.remaining_new,0);
      // Start happened yesterday; an older result must not roll back a newer result.
      await db.exec("reset role");
      await db.query("update study_sessions set started_at=now()-interval '3 days' where session_id=$1",[session.session_id]);
      await db.exec("set role authenticated");
      const current=await value(db,"record_study_event_v2($1,$2,$3,true,now(),'UTC')",[crypto.randomUUID(),session.session_id,session.sentence_ids[0]]);
      const stale=await value(db,"record_study_event_v2($1,$2,$3,false,now()-interval '1 day','UTC')",[crypto.randomUUID(),session.session_id,session.sentence_ids[0]]);
      deepStrictEqual(stale,current);
    });
    await t.step("DST boundaries use local midnight, and ledgers/receipts have only account cascade",async()=>{
      strictEqual(await adminValue(db,`extract(epoch from (('2026-03-09'::timestamp at time zone 'America/Los_Angeles')-('2026-03-08'::timestamp at time zone 'America/Los_Angeles')))/3600`),"23.0000000000000000");
      const fks=await adminValue(db,"(select jsonb_agg(confrelid::regclass::text) from pg_constraint where contype='f' and conrelid='sentence_study_activations'::regclass)");
      deepStrictEqual(fks,["auth.users"]);
      strictEqual(await value(db,"has_function_privilege('anon','begin_study_session_v2(uuid,text,text,integer,text,text)','EXECUTE')"),false);
    });
  } finally {await db.close();}
});
