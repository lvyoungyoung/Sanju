import { deepStrictEqual, ok, rejects, strictEqual } from "node:assert";
import { PGlite } from "npm:@electric-sql/pglite@0.5.8";

const root = new URL("../../supabase/migrations/", import.meta.url);
const alice = "00000000-0000-4000-8000-000000000001";
const bob = "00000000-0000-4000-8000-000000000002";
const legacy = "10000000-0000-4000-8000-000000000001";
const spanishTranslation = "10000000-0000-4000-8000-000000000002";
const japanese = "10000000-0000-4000-8000-000000000003";
const foreign = "10000000-0000-4000-8000-000000000004";
const sid = (memory: string) => memory.replace(/^1/, "2");
const migration = await Deno.readTextFile(
  new URL("20261013000000_multilingual_content.sql", root),
);

// Deliberately permissive baseline policies demonstrate AND composition, not
// replacement of unknown hosted policy names. This is not a production dump.
async function setup() {
  const db = new PGlite();
  await db.exec(`
    create role anon; create role authenticated; create role service_role bypassrls;
    create schema auth; create schema storage;
    create function auth.uid() returns uuid language sql as $$
      select nullif(current_setting('test.user_id',true),'')::uuid $$;
    create function auth.jwt() returns jsonb language sql as $$
      select jsonb_build_object('is_anonymous',coalesce(nullif(current_setting('test.anonymous',true),''),'false')::boolean) $$;
    create table auth.users(id uuid primary key);
    create table profiles(id uuid primary key references auth.users(id) on delete cascade,
      english_level text, speech_voice text, available_generations integer default 10);
    create table memories(id uuid primary key,user_id uuid not null references profiles(id) on delete cascade,
      image_url text,created_at timestamptz not null default now(),tags text[] default '{}',provider text);
    create table memory_sentences(id uuid primary key,memory_id uuid not null references memories(id) on delete cascade,
      english text not null,chinese text not null,sort_order integer default 1,
      presentation_group text not null default 'what_i_see',learning_topic_ids text[] default '{}',is_favorite boolean not null default false);
    create table sentence_study_progress(user_id uuid,sentence_id uuid references memory_sentences(id) on delete cascade,correct_count integer default 0);
    create table study_scene_sentences(sentence_id uuid references memory_sentences(id) on delete cascade);
    create table study_topic_expressions(id uuid primary key,user_id uuid,topic_key text);
    create table study_topic_expression_sets(user_id uuid,topic_key text);
    create table study_topic_expression_examples(expression_id uuid references study_topic_expressions(id) on delete cascade,
      sentence_id uuid references memory_sentences(id) on delete cascade);
    create table generation_enrichment_jobs(id uuid);
    create table guest_sentence_embeddings(sentence_id uuid);
    create table sentence_explanations(user_id uuid);
    create table generation_jobs(id uuid primary key,user_id uuid,memory_id uuid references memories(id) on delete set null,generation_spec jsonb,request_schema_version integer default 1);
    create table guest_generation_jobs(id uuid primary key,user_id uuid,generation_spec jsonb,request_schema_version integer default 1);
    create table storage.objects(id uuid primary key default gen_random_uuid(),bucket_id text,name text,unique(bucket_id,name));
    insert into auth.users values('${alice}'),('${bob}');
    insert into profiles(id,english_level,speech_voice) values('${alice}',U&'\\7B80\\5355','Mia'),('${bob}',null,null);
    insert into memories(id,user_id,image_url,created_at) values('${legacy}','${alice}','${alice}/${legacy}.jpg','2020-01-01');
    insert into memory_sentences(id,memory_id,english,chinese,is_favorite)
      values('${
    sid(legacy)
  }','${legacy}',E'  A lake.\\n',E'  A translation.\\n',true);
    grant usage on schema public,auth,storage to anon,authenticated,service_role;
    grant all on all tables in schema public,storage to authenticated;
    alter table profiles enable row level security;
    create policy profile_owner on profiles for all to authenticated using(id=auth.uid()) with check(id=auth.uid());
    do $$ declare t text; begin
      foreach t in array array['memories','memory_sentences','sentence_study_progress','study_scene_sentences','generation_jobs','guest_generation_jobs',
        'study_topic_expressions','study_topic_expression_sets','study_topic_expression_examples',
        'generation_enrichment_jobs','guest_sentence_embeddings','sentence_explanations'] loop
        execute format('alter table %I enable row level security',t);
        execute format('create policy broad_legacy on %I for all to authenticated using(true) with check(true)',t);
      end loop;
    end $$;
    alter table storage.objects enable row level security;
    create policy existing_storage on storage.objects for all to authenticated using(true) with check(true);
  `);
  await db.exec(
    await Deno.readTextFile(
      new URL("20260925000000_add_album_flip_progress.sql", root),
    ),
  );
  await db.exec(migration);
  await db.query(
    `insert into memories(id,user_id,image_url,created_at,target_language,translation_language,teaching_locale)
    values($1::uuid,$2::uuid,$2::uuid::text||'/'||$1::uuid::text||'.jpg','2020-01-01','en','es','en-US'),
      ($3::uuid,$2::uuid,$2::uuid::text||'/'||$3::uuid::text||'.jpg','2020-01-01','ja','zh-Hans','ja-JP'),
      ($4::uuid,$5::uuid,$5::uuid::text||'/'||$4::uuid::text||'.jpg','2020-01-01','en','zh-Hans','en-US')`,
    [spanishTranslation, alice, japanese, foreign, bob],
  );
  for (const memory of [spanishTranslation, japanese, foreign]) {
    await db.query(
      `insert into memory_sentences(id,memory_id,target_text,translation_text,is_favorite)
      values($1,$2,$3,$4,true)`,
      [
        sid(memory),
        memory,
        memory === japanese ? "湖です。" : "A lake.",
        "A translation.",
      ],
    );
  }
  await db.exec(
    `insert into sentence_study_progress(user_id,sentence_id,correct_count)
      select m.user_id,s.id,4 from memory_sentences s join memories m on m.id=s.memory_id;
    insert into study_scene_sentences select id from memory_sentences;
    insert into storage.objects(bucket_id,name) select 'memories',image_url from memories;`,
  );
  await login(db);
  return db;
}
async function login(db: PGlite, user = alice) {
  await db.exec(
    `reset role; set role authenticated; set test.user_id='${user}'; set test.anonymous='false';`,
  );
}
async function value(db: PGlite, sql: string, params: unknown[] = []) {
  return (await db.query<{ result: any }>(`select ${sql} as result`, params))
    .rows[0].result;
}
const patch = (db: PGlite, p: unknown) =>
  value(db, "update_learning_preferences_v1($1::jsonb)", [JSON.stringify(p)]);
const event = (memory: string) => ({
  id: crypto.randomUUID(),
  memory_id: memory,
  sentence_id: sid(memory),
  feedback: "familiar",
  occurred_at: "2020-01-02T00:00:00Z",
  time_zone: "Asia/Shanghai",
});

Deno.test("multilingual DB: exact backfill, mixed-language reads, old REST isolation and immutable projections", async (t) => {
  const db = await setup();
  try {
    await t.step(
      "backfill is byte-for-byte and stable IDs, favorites, credits, progress survive",
      async () => {
        const dto = await value(db, "get_memory_v2($1)", [legacy]);
        deepStrictEqual(dto.context, {
          schemaVersion: 2,
          targetLanguage: "en",
          translationLanguage: "zh-Hans",
          teachingLocale: "en-US",
        });
        strictEqual(dto.schemaVersion, 2);
        strictEqual(dto.sentences[0].targetText, "  A lake.\n");
        strictEqual(dto.sentences[0].translationText, "  A translation.\n");
        strictEqual(dto.sentences[0].id, sid(legacy));
        strictEqual(dto.sentences[0].isFavorite, true);
        strictEqual(
          await value(
            db,
            "(select available_generations from profiles where id=auth.uid())",
          ),
          10,
        );
        strictEqual(
          await value(
            db,
            "(select correct_count from sentence_study_progress where sentence_id=$1)",
            [sid(legacy)],
          ),
          4,
        );
      },
    );
    await t.step(
      "restrictive policy beats broad baseline policy for list, joins/count, mutations and associated rows",
      async () => {
        strictEqual(await value(db, "(select count(*) from memories)"), 1);
        strictEqual(
          await value(
            db,
            "(select count(*) from memory_sentences s join memories m on m.id=s.memory_id)",
          ),
          1,
        );
        strictEqual(
          await value(db, "(select count(*) from sentence_study_progress)"),
          1,
        );
        strictEqual(
          await value(db, "(select count(*) from study_scene_sentences)"),
          1,
        );
        strictEqual(
          (await db.query("delete from memories where id=$1 returning id", [
            japanese,
          ])).rows.length,
          0,
        );
        strictEqual(
          (await db.query(
            "update memory_sentences set is_favorite=false where id=$1 returning id",
            [sid(spanishTranslation)],
          )).rows.length,
          0,
        );
        await rejects(() =>
          db.query("insert into study_scene_sentences values($1)", [
            sid(japanese),
          ])
        );
        await rejects(() =>
          db.query(
            "insert into memories(id,user_id,target_language,translation_language,teaching_locale) values($1,$2,'ja','zh-Hans','ja-JP')",
            [crypto.randomUUID(), alice],
          )
        );
      },
    );
    await t.step(
      "new pagination includes all owned languages, stable tie-breaks and strict cursor validation",
      async () => {
        const page = await value(db, "list_memories_v2(null,null,null,2)");
        deepStrictEqual(page.memories.map((m: any) => m.id), [
          japanese,
          spanishTranslation,
        ]);
        const next = await value(db, "list_memories_v2(null,$1,$2,2)", [
          page.nextCursor.createdAt,
          page.nextCursor.id,
        ]);
        deepStrictEqual(next.memories.map((m: any) => m.id), [legacy]);
        strictEqual(next.nextCursor, null);
        const en = await value(db, "list_memories_v2('en')");
        strictEqual(en.memories.length, 2);
        strictEqual(await value(db, "get_memory_v2($1)", [foreign]), null);
        await rejects(() => value(db, "list_memories_v2('de')"));
        await rejects(() => value(db, "list_memories_v2(null,now(),null,2)"));
        await rejects(() => value(db, "list_memories_v2(null,null,null,101)"));
        await rejects(() =>
          value(db, "list_memories_v2(null,'infinity',$1,2)", [legacy])
        );
      },
    );
    await t.step(
      "favorites are owned and independent of current selection and generation flags",
      async () => {
        await value(db, "set_sentence_favorite_v2($1,false)", [sid(japanese)]);
        const dto = await value(db, "get_memory_v2($1)", [japanese]);
        strictEqual(dto.sentences[0].isFavorite, false);
        await rejects(() =>
          value(db, "set_sentence_favorite_v2($1,true)", [sid(foreign)])
        );
        await rejects(() =>
          value(db, "set_sentence_favorite_v2($1,null)", [sid(legacy)])
        );
      },
    );
    await t.step(
      "content cannot be reparented, rewritten, or overwritten by stale old snapshots",
      async () => {
        await rejects(
          () =>
            db.query(
              "update memory_sentences set english='different' where id=$1",
              [sid(legacy)],
            ),
          /content_projection_mismatch/,
        );
        await rejects(
          () =>
            db.query(
              "update memory_sentences set english='different',target_text='different' where id=$1",
              [sid(legacy)],
            ),
          /immutable_content/,
        );
        await rejects(
          () =>
            db.query("update memories set user_id=$1 where id=$2", [
              bob,
              legacy,
            ]),
          /immutable_content/,
        );
        await rejects(
          () =>
            db.query(
              "update memories set image_url='replacement.jpg' where id=$1",
              [legacy],
            ),
          /immutable_content/,
        );
        await rejects(
          () =>
            db.query(
              "update memory_sentences set learning_topic_ids=array['changed'] where id=$1",
              [sid(legacy)],
            ),
          /immutable_content/,
        );
        await rejects(() =>
          db.query(
            `insert into memory_sentences(id,memory_id,english,chinese)
        values($1,$2,'changed','changed') on conflict(id) do update set english=excluded.english,chinese=excluded.chinese`,
            [sid(legacy), legacy],
          )
        );
        await db.exec("reset role");
        const projections = (await db.query(
          "select english,chinese from memory_sentences where memory_id=$1",
          [spanishTranslation],
        )).rows[0];
        deepStrictEqual(projections, { english: null, chinese: null });
        await rejects(
          () =>
            db.query(
              "update memory_sentences set target_text='server rewrite' where id=$1",
              [sid(japanese)],
            ),
          /immutable_content/,
        );
        await login(db);
        const copy = crypto.randomUUID();
        await db.query(
          "insert into memory_sentences(id,memory_id,english,chinese) values($1,$2,'Legacy import','Translation')",
          [copy, legacy],
        );
        strictEqual(
          await value(
            db,
            "(select target_text from memory_sentences where id=$1)",
            [copy],
          ),
          "Legacy import",
        );
      },
    );
    await t.step(
      "job snapshots, including pending jobs without memories, cannot expose nonlegacy languages",
      async () => {
        await db.exec("reset role");
        const base = {
          schemaVersion: 1,
          catalogVersion: 1,
          targetLanguage: "en",
          translationLanguage: "zh-Hans",
          teachingLocale: "en-US",
          generationFormat: "dual_tabs_v1",
        };
        for (const table of ["generation_jobs", "guest_generation_jobs"]) {
          for (
            const spec of [null, base, { ...base, translationLanguage: "es" }, {
              ...base,
              schemaVersion: 99,
            }]
          ) {
            await db.query(
              `insert into ${table}(id,user_id,generation_spec) values($1,$2,$3::jsonb)`,
              [crypto.randomUUID(), alice, JSON.stringify(spec)],
            );
          }
          await db.query(
            `insert into ${table}(id,user_id,request_schema_version) values($1,$2,99)`,
            [crypto.randomUUID(), alice],
          );
          await db.query(`insert into ${table}(id,user_id,request_schema_version,generation_spec) values($1,$2,3,$3::jsonb)`,
            [crypto.randomUUID(),alice,JSON.stringify(base)]);
        }
        await login(db);
        strictEqual(
          await value(db, "(select count(*) from generation_jobs)"),
          2,
        );
        strictEqual(
          await value(db, "(select count(*) from guest_generation_jobs)"),
          2,
        );
      },
    );
    await t.step(
      "associated expression provenance and server-only caches are protected despite broad baseline policies",
      async () => {
        await db.exec("reset role");
        const good = crypto.randomUUID(),
          mixed = crypto.randomUUID(),
          other = crypto.randomUUID();
        await db.query(
          "insert into study_topic_expressions values($1,$2,'legacy'),($3,$2,'mixed'),($4,$5,'other')",
          [good, alice, mixed, other, bob],
        );
        await db.query(
          "insert into study_topic_expression_examples values($1,$2),($3,$2),($3,$4),($5,$6)",
          [good, sid(legacy), mixed, sid(japanese), other, sid(foreign)],
        );
        await db.query(
          "insert into study_topic_expression_sets values($1,'legacy'),($1,'mixed'),($2,'other')",
          [alice, bob],
        );
        await db.query("insert into generation_enrichment_jobs values($1)", [
          japanese,
        ]);
        await db.query("insert into guest_sentence_embeddings values($1)", [
          sid(japanese),
        ]);
        await db.query("insert into sentence_explanations values($1)", [alice]);
        await login(db);
        deepStrictEqual(
          (await db.query("select id from study_topic_expressions")).rows,
          [{ id: good }],
        );
        deepStrictEqual(
          (await db.query("select topic_key from study_topic_expression_sets"))
            .rows,
          [{ topic_key: "legacy" }],
        );
        deepStrictEqual(
          (await db.query(
            "select expression_id from study_topic_expression_examples",
          )).rows,
          [{ expression_id: good }],
        );
        for (
          const table of [
            "generation_enrichment_jobs",
            "guest_sentence_embeddings",
            "sentence_explanations",
          ]
        ) {
          strictEqual(await value(db, `(select count(*) from ${table})`), 0);
        }
        await rejects(() =>
          db.query(
            "insert into study_topic_expressions values($1,$2,'injected')",
            [crypto.randomUUID(), alice],
          )
        );
      },
    );
  } finally {
    await db.close();
  }
});

Deno.test("multilingual DB: CAS preferences preserve other languages, legacy English projection and atomicity", async (t) => {
  const db = await setup();
  try {
    await t.step(
      "upgrade does not invent a selection or derive explanation from UI",
      async () => {
        const prefs = await value(db, "get_learning_preferences_v1()");
        strictEqual(prefs.selection, null);
        deepStrictEqual(prefs.languages, [{
          targetLanguage: "en",
          level: "beginner",
          levelRevision: 1,
          speechVoice: "Mia",
          voiceRevision: 1,
        }]);
      },
    );
    const selection = {
      mode: "legacyEnglish",
      targetLanguage: "en",
      translationLanguage: "zh-Hans",
      explanationLanguage: "en",
      expectedRevision: 0,
    };
    await t.step(
      "explicit legacyEnglish import and standard combination CAS",
      async () => {
        strictEqual((await patch(db, { selection })).selection.revision, 1);
        await rejects(
          () => patch(db, { selection }),
          /preference_revision_conflict/,
        );
        const standard = {
          mode: "standard",
          targetLanguage: "ja",
          translationLanguage: "en",
          explanationLanguage: "en",
          expectedRevision: 1,
        };
        const result = await patch(db, {
          selection: standard,
          language: {
            targetLanguage: "ja",
            level: "starter",
            expectedLevelRevision: 0,
          },
        });
        strictEqual(result.selection.revision, 2);
        strictEqual(
          result.languages.find((p: any) => p.targetLanguage === "ja")
            .levelRevision,
          1,
        );
        await rejects(() =>
          patch(db, {
            selection: {
              ...standard,
              targetLanguage: "en",
              expectedRevision: 2,
            },
          })
        );
        await rejects(() =>
          patch(db, {
            selection: {
              ...standard,
              explanationLanguage: "fr",
              expectedRevision: 2,
            },
          })
        );
      },
    );
    await t.step("a conflict rolls back the entire grouped patch", async () => {
      const before = await value(db, "get_learning_preferences_v1()");
      await rejects(() =>
        patch(db, {
          selection: { ...selection, expectedRevision: 2 },
          language: {
            targetLanguage: "ja",
            level: "advanced",
            expectedLevelRevision: 0,
          },
        }), /preference_revision_conflict/);
      deepStrictEqual(await value(db, "get_learning_preferences_v1()"), before);
    });
    await t.step(
      "per-field CAS does not overwrite other languages or independent voice edits",
      async () => {
        await patch(db, {
          language: {
            targetLanguage: "en",
            level: "advanced",
            expectedLevelRevision: 1,
          },
        });
        await patch(db, {
          language: {
            targetLanguage: "en",
            speechVoice: "Dean",
            expectedVoiceRevision: 1,
          },
        });
        await patch(db, {
          language: {
            targetLanguage: "es",
            level: "intermediate",
            expectedLevelRevision: 0,
          },
        });
        let prefs = await value(db, "get_learning_preferences_v1()");
        strictEqual(prefs.selection.targetLanguage, "ja");
        deepStrictEqual(
          prefs.languages.find((p: any) => p.targetLanguage === "en"),
          {
            targetLanguage: "en",
            level: "advanced",
            levelRevision: 2,
            speechVoice: "Dean",
            voiceRevision: 2,
          },
        );
        strictEqual(
          await value(
            db,
            "(select english_level from profiles where id=auth.uid())",
          ),
          "高级",
        );
        await db.query(
          "update profiles set english_level=$1,speech_voice='Chloe' where id=$2",
          ["启蒙", alice],
        );
        prefs = await value(db, "get_learning_preferences_v1()");
        strictEqual(
          prefs.languages.find((p: any) => p.targetLanguage === "en")
            .levelRevision,
          3,
        );
        strictEqual(
          prefs.languages.find((p: any) => p.targetLanguage === "en")
            .voiceRevision,
          3,
        );
        strictEqual(
          prefs.languages.find((p: any) => p.targetLanguage === "es").level,
          "intermediate",
        );
        strictEqual(prefs.selection.revision, 2);
        await rejects(
          () =>
            patch(db, {
              language: {
                targetLanguage: "en",
                level: "beginner",
                expectedLevelRevision: 2,
              },
            }),
          /preference_revision_conflict/,
        );
        await patch(db, {
          language: {
            targetLanguage: "en",
            level: "starter",
            expectedLevelRevision: 3,
          },
        });
        strictEqual(
          (await value(db, "get_learning_preferences_v1()")).languages.find((
            p: any,
          ) => p.targetLanguage === "en").levelRevision,
          4,
        );
      },
    );
    await t.step(
      "malformed patches cannot bypass revisions; unknown voices stay disabled",
      async () => {
        for (
          const invalid of [null, {}, { selection: null }, { ownerID: bob }, {
            language: {
              targetLanguage: "ja",
              level: null,
              expectedLevelRevision: 1,
            },
          }, {
            language: {
              targetLanguage: "ja",
              level: "starter",
              expectedLevelRevision: null,
            },
          }, {
            language: {
              targetLanguage: "ja",
              level: "starter",
              expectedLevelRevision: "1",
            },
          }, {
            language: {
              targetLanguage: "ja",
              speechVoice: "Mia",
              expectedVoiceRevision: 0,
            },
          }, {
            language: {
              targetLanguage: "en",
              level: "starter",
              expectedLevelRevision: 4,
              expectedVoiceRevision: 3,
            },
          }]
        ) await rejects(() => patch(db, invalid));
        await rejects(() => db.exec("select * from user_language_preferences"));
        await login(db, bob);
        const prefs = await value(db, "get_learning_preferences_v1()");
        strictEqual(prefs.selection, null);
        strictEqual(prefs.languages[0].level, null);
      },
    );
  } finally {
    await db.close();
  }
});

Deno.test("multilingual DB: Storage guards, deletion outbox, flip isolation and capability/EXECUTE restrictions", async (t) => {
  const db = await setup();
  try {
    await t.step(
      "nonlegacy referenced Storage objects cannot be deleted, renamed or overwritten",
      async () => {
        strictEqual(
          (await db.query(
            "delete from storage.objects where name=$1 returning id",
            [`${alice}/${japanese}.jpg`],
          )).rows.length,
          0,
        );
        strictEqual(
          (await db.query(
            "update storage.objects set name='replaced' where name=$1 returning id",
            [`${alice}/${japanese}.jpg`],
          )).rows.length,
          0,
        );
        await rejects(() =>
          db.query(
            "insert into storage.objects(bucket_id,name) values('memories',$1) on conflict(bucket_id,name) do update set name=excluded.name",
            [`${alice}/${japanese}.jpg`],
          )
        );
        await rejects(() =>
          db.query("update storage.objects set name=$1 where name=$2", [
            `${alice}/${japanese}.jpg`,
            `${alice}/${legacy}.jpg`,
          ])
        );
      },
    );
    await t.step(
      "flip writes/read across languages are versioned, independent of study and idempotent",
      async () => {
        const events = [
          event(legacy),
          event(japanese),
          event(spanishTranslation),
          event(foreign),
        ];
        strictEqual(
          (await db.query("select * from sync_album_flip_feedback($1::jsonb)", [
            JSON.stringify(events),
          ])).rows.length,
          1,
        );
        strictEqual(
          (await db.query(
            "select * from sync_album_flip_feedback_v2($1::jsonb)",
            [JSON.stringify(events)],
          )).rows.length,
          3,
        );
        strictEqual(
          (await db.query(
            "select * from sync_album_flip_feedback_v2($1::jsonb)",
            [JSON.stringify(events)],
          )).rows.length,
          3,
        );
        strictEqual(
          (await db.query("select * from album_flip_progress")).rows.length,
          1,
        );
        strictEqual(
          (await db.query("select * from get_album_flip_progress_v2()")).rows
            .length,
          3,
        );
        strictEqual(
          (await db.query("select * from get_album_flip_progress_v2('ja')"))
            .rows.length,
          1,
        );
        await rejects(() =>
          db.query(
            "select * from sync_album_flip_feedback_internal_v1($1::jsonb)",
            [JSON.stringify(events)],
          )
        );
        strictEqual(
          await value(
            db,
            "(select correct_count from sentence_study_progress where sentence_id=$1)",
            [sid(legacy)],
          ),
          4,
        );
      },
    );
    await t.step(
      "delete removes owned content once, queues cleanup, never touches a foreign account",
      async () => {
        const operation = crypto.randomUUID();
        const result = await value(db, "delete_memory_v2($1,$2)", [
          japanese,
          operation,
        ]);
        deepStrictEqual(result, {
          memoryID: japanese,
          operationID: operation,
          deleted: true,
        });
        deepStrictEqual(
          await value(db, "delete_memory_v2($1,$2)", [japanese, operation]),
          result,
        );
        await value(db, "delete_memory_v2($1,$2)", [
          japanese,
          crypto.randomUUID(),
        ]);
        await rejects(
          () =>
            value(db, "delete_memory_v2($1,$2)", [
              spanishTranslation,
              operation,
            ]),
          /operation_context_mismatch/,
        );
        await rejects(
          () =>
            value(db, "delete_memory_v2($1,$2)", [
              foreign,
              crypto.randomUUID(),
            ]),
          /memory_not_found/,
        );
        strictEqual(await value(db, "get_memory_v2($1)", [japanese]), null);
        await rejects(() =>
          db.exec("select * from memory_image_cleanup_jobs_v2")
        );
        await db.exec("reset role");
        strictEqual(
          await value(
            db,
            "(select count(*) from memory_image_cleanup_jobs_v2)",
          ),
          1,
        );
        strictEqual(
          await value(
            db,
            "(select count(*) from storage.objects where name=$1)",
            [`${alice}/${japanese}.jpg`],
          ),
          1,
        );
        strictEqual(
          await value(
            db,
            "(select count(*) from album_flip_progress where memory_id=$1)",
            [japanese],
          ),
          0,
        );
        strictEqual(
          await value(
            db,
            "(select count(*) from sentence_study_progress where sentence_id=$1)",
            [sid(japanese)],
          ),
          0,
        );
        await login(db);
      },
    );
    await t.step(
      "only legacy generation is enabled, disabling generation never prevents reads",
      async () => {
        const capabilities = await value(db, "get_language_capabilities_v1()");
        strictEqual(capabilities.catalogVersion, 1);
        strictEqual(capabilities.combinations.length, 10);
        deepStrictEqual(
          capabilities.combinations.filter((p: any) => p.canGenerate).map((
            p: any,
          ) => [p.targetLanguage, p.translationLanguage]),
          [["en", "zh-Hans"]],
        );
        ok(capabilities.combinations.every((p: any) => p.canRead));
        await rejects(() => value(db, "get_language_capabilities_v1(99)"));
        await rejects(() =>
          db.exec("update language_capabilities_v1 set can_generate=true")
        );
        ok(await value(db, "get_memory_v2($1)", [spanishTranslation]));
      },
    );
    await t.step(
      "anonymous/missing auth and untrusted internal calls are rejected",
      async () => {
        const publicFunctions = [
          "get_memory_v2(uuid)",
          "list_memories_v2(text,timestamptz,uuid,integer)",
          "set_sentence_favorite_v2(uuid,boolean)",
          "delete_memory_v2(uuid,uuid)",
          "get_learning_preferences_v1()",
          "update_learning_preferences_v1(jsonb)",
          "get_language_capabilities_v1(integer)",
          "get_album_flip_progress_v2(text)",
          "sync_album_flip_feedback_v2(jsonb)",
        ];
        for (const fn of publicFunctions) {
          strictEqual(
            await value(db, "has_function_privilege('anon',$1,'EXECUTE')", [
              fn,
            ]),
            false,
          );
          strictEqual(
            await value(
              db,
              "has_function_privilege('authenticated',$1,'EXECUTE')",
              [fn],
            ),
            true,
          );
        }
        const createdFunctions = [
          ...migration.matchAll(/create function public\.([a-z0-9_]+)\(/g),
        ].map((m) => m[1]);
        await db.exec("reset role");
        const configs = await db.query<
          { proname: string; proconfig: string[] }
        >(
          "select proname,proconfig from pg_proc where pronamespace='public'::regnamespace and proname=any($1::text[])",
          [createdFunctions],
        );
        strictEqual(configs.rows.length, createdFunctions.length);
        for (const fn of configs.rows) {
          ok(
            fn.proconfig.includes("search_path=pg_catalog, public, pg_temp"),
            fn.proname,
          );
        }
        await login(db);
        await rejects(() => value(db, "memory_content_dto_v2($1)", [foreign]));
        await db.exec("set test.anonymous='true'");
        strictEqual(
          (await value(db, "get_language_capabilities_v1()")).combinations
            .length,
          10,
        );
        await rejects(
          () => value(db, "get_memory_v2($1)", [legacy]),
          /Sign in required/,
        );
        await rejects(
          () => value(db, "get_learning_preferences_v1()"),
          /Sign in required/,
        );
        await db.exec("set test.anonymous='false'; set test.user_id=''");
        await rejects(
          () => value(db, "list_memories_v2()"),
          /Sign in required/,
        );
      },
    );
    await t.step(
      "account removal clears preferences and receipts but preserves durable image cleanup",
      async () => {
        await db.exec("reset role");
        await db.query("delete from auth.users where id=$1", [alice]);
        for (
          const table of [
            "user_language_preferences",
            "user_learning_preferences",
            "memory_deletion_receipts_v2",
          ]
        ) {
          strictEqual(
            await value(
              db,
              `(select count(*) from ${table} where user_id=$1)`,
              [alice],
            ),
            0,
          );
        }
        ok(await value(db,"(select count(*)>0 from memory_image_cleanup_jobs_v2 where user_id=$1)",[alice]));
      },
    );
  } finally {
    await db.close();
  }
});

Deno.test("multilingual DB: legacy missing images remain decodable without spurious cleanup",async()=>{
  const db=await setup();
  const memory=crypto.randomUUID();
  try {
    await db.exec("reset role");
    await db.query("insert into memories(id,user_id,image_url) values($1,$2,null)",[memory,alice]);
    await login(db);
    strictEqual((await value(db,"get_memory_v2($1)",[memory])).imagePath,"");
    await value(db,"delete_memory_v2($1,$2)",[memory,crypto.randomUUID()]);
    await db.exec("reset role");
    strictEqual(await value(db,"(select count(*) from memory_image_cleanup_jobs_v2)"),0);
  } finally {await db.close();}
});

Deno.test("multilingual DB: image outbox leases, reference safety, retries and account-deletion durability", async () => {
  const db=await setup();
  const path=`${alice}/${japanese}.jpg`;
  const claim=async()=> (await db.query<any>("select * from claim_memory_image_cleanup_v2(10)")).rows;
  try {
    for (const role of ["authenticated","anon"]) {
      await db.exec(`reset role; set role ${role}`);
      await rejects(()=>claim(),/permission denied/);
      await rejects(()=>value(db,"authorize_memory_image_cleanup_v2($1,$2)",[crypto.randomUUID(),crypto.randomUUID()]),/permission denied/);
      await rejects(()=>value(db,"finish_memory_image_cleanup_v2($1,$2,true)",[crypto.randomUUID(),crypto.randomUUID()]),/permission denied/);
    }
    await login(db);
    // An existing shared reference must prevent Storage deletion, even cross-owner.
    await db.exec("reset role");
    const shared=crypto.randomUUID();
    await db.query("insert into memories(id,user_id,image_url) values($1,$2,$3)",[shared,bob,path]);
    await login(db);
    await value(db,"delete_memory_v2($1,$2)",[japanese,crypto.randomUUID()]);
    await db.exec("reset role; set role service_role");
    const [first]=await claim();
    strictEqual(first.attempts,1);
    strictEqual((await claim()).length,0);
    strictEqual(await value(db,"authorize_memory_image_cleanup_v2($1,$2)",[first.id,first.lease_id]),false);
    strictEqual(await value(db,"finish_memory_image_cleanup_v2($1,$2,false,'reference_exists')",[first.id,first.lease_id]),true);
    strictEqual((await claim()).length,0);
    await db.exec("reset role");
    await db.query("delete from memories where id=$1",[shared]);
    await rejects(()=>db.query("insert into memories(id,user_id,image_url) values($1,$2,$3)",[crypto.randomUUID(),alice,path]),/retired_memory_image_path/);
    await login(db);
    strictEqual(await value(db,"legacy_storage_mutation_allowed_v1('memories',$1)",[path]),false);
    await rejects(()=>db.query("insert into storage.objects(bucket_id,name) values('memories',$1)",[path]),/row-level security/);
    await db.exec("reset role");
    await db.query("update memory_image_cleanup_jobs_v2 set next_attempt_at=now()-interval '1 second' where id=$1",[first.id]);
    await db.exec("set role service_role");
    const second=(await claim()).find(j=>j.id===first.id);
    strictEqual(second.attempts,2);
    ok(second.lease_id!==first.lease_id);
    strictEqual(await value(db,"finish_memory_image_cleanup_v2($1,$2,true)",[first.id,first.lease_id]),false);
    strictEqual(await value(db,"authorize_memory_image_cleanup_v2($1,$2)",[second.id,second.lease_id]),true);
    // Simulated crash after Storage removal: an expired lease can be reclaimed.
    await db.query("update memory_image_cleanup_jobs_v2 set lease_until=now()-interval '1 second' where id=$1",[second.id]);
    const third=(await claim()).find(j=>j.id===first.id);
    strictEqual(await value(db,"authorize_memory_image_cleanup_v2($1,$2)",[second.id,second.lease_id]),false);
    strictEqual(await value(db,"finish_memory_image_cleanup_v2($1,$2,true)",[third.id,third.lease_id]),true);
    strictEqual(await value(db,"finish_memory_image_cleanup_v2($1,$2,true)",[third.id,third.lease_id]),false);
    strictEqual((await claim()).length,0);
    await db.exec("reset role");
    await db.query("delete from auth.users where id=$1",[alice]);
    await db.exec("set role service_role");
    const accountJobs=await claim();
    ok(accountJobs.some(j=>j.memory_id===legacy));
    for (const job of accountJobs) strictEqual(await value(db,"authorize_memory_image_cleanup_v2($1,$2)",[job.id,job.lease_id]),true);
    await db.exec("reset role");
    for (const bad of [`${bob}/${legacy}.jpg`,`${alice}/../${legacy}.jpg`,`https://example.invalid/${legacy}.jpg`]) {
      await db.query("insert into memory_image_cleanup_jobs_v2(user_id,memory_id,image_path) values($1,$2,$3)",[alice,crypto.randomUUID(),bad]);
    }
    await db.exec("set role service_role");
    for (const job of await claim()) strictEqual(await value(db,"authorize_memory_image_cleanup_v2($1,$2)",[job.id,job.lease_id]),false);
  } finally {await db.close();}
});

Deno.test("multilingual DB: learning material is bounded, typed, non-executable and reconstructs exact text", async () => {
  const db = await setup();
  try {
    await db.exec("reset role");
    const textDigest = await value(
      db,
      "encode(sha256(convert_to('湖です。','UTF8')),'hex')",
    );
    const material = {
      schemaVersion: 1,
      policyVersion: 1,
      textDigest,
      segments: [{
        id: "s1",
        surface: "湖",
        reading: "みずうみ",
        kind: "word",
        canBlank: true,
      }, { id: "s2", surface: "です。", kind: "phrase", canBlank: false }],
    };
    await db.query(
      "update memory_sentences set learning_material=$1::jsonb where id=$2",
      [JSON.stringify(material), sid(japanese)],
    );
    for (
      const invalid of [
        { ...material, schemaVersion: 99 },
        { ...material, prompt: "execute this" },
        { ...material, segments: [{ id: "x", surface: "rewritten" }] },
        { ...material, textDigest: "0".repeat(64) },
        {
          ...material,
          segments: [{
            id: "x",
            surface: "湖",
            kind: "arbitrary",
            canBlank: true,
          }, { id: "x", surface: "です。" }],
        },
        { ...material, segments: [] },
        { ...material, segments: [{ id: "x", surface: "x".repeat(40000) }] },
      ]
    ) {
      await rejects(() =>
        db.query(
          "update memory_sentences set learning_material=$1::jsonb where id=$2",
          [JSON.stringify(invalid), sid(japanese)],
        )
      );
    }
    await login(db);
    deepStrictEqual(
      (await value(db, "get_memory_v2($1)", [japanese])).sentences[0]
        .learningMaterial,
      material,
    );
  } finally {
    await db.close();
  }
});
