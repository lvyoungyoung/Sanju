import { deepStrictEqual, rejects, strictEqual } from "node:assert";
import { PGlite } from "npm:@electric-sql/pglite@0.5.8";
import {
  SCENE_CATEGORIES,
  SCENE_CATEGORY_CATALOG_VERSION,
} from "../../supabase/functions/_shared/scene-categories.ts";

const migrations = new URL("../../supabase/migrations/", import.meta.url);
const read = (name: string) => Deno.readTextFile(new URL(name, migrations));
const owner = "10000000-0000-0000-0000-000000000001";
const other = "10000000-0000-0000-0000-000000000002";
const model = "test-model";
const vector = [1, ...Array(1023).fill(0)];
function definition(source: string, name: string) {
  const match = source.match(
    new RegExp(
      `create or replace function public\\.${name}\\([\\s\\S]*?\\$\\$;`,
    ),
  );
  if (!match) throw new Error(name);
  return match[0];
}

Deno.test("unified category migration validates storage, matching and atomic generation", async (t) => {
  const db = new PGlite();
  try {
    await db.exec(`
      create role anon; create role authenticated; create role service_role;
      create schema auth;
      create function auth.uid() returns uuid language sql stable as
        $$ select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
      create table profiles(id uuid primary key, available_generations integer);
      insert into profiles values ('${owner}',10), ('${other}',10);
      create table memories(id uuid primary key, user_id uuid, tags text[], image_url text, created_at timestamptz, provider text);
      create table memory_sentences(id uuid primary key, memory_id uuid references memories(id),
        english text, chinese text, sort_order integer, presentation_group text, is_favorite boolean,
        learning_topic_ids text[] constraint memory_sentences_learning_topic_ids_check
          check (learning_topic_ids <@ array['pet_life','natural_scenery']));
      create table study_scenes(id uuid primary key default gen_random_uuid(), user_id uuid, name text,
        learning_topic_id text, match_threshold double precision default 0.42,
        match_rule_version integer default 0, updated_at timestamptz,
        constraint study_scenes_user_id_name_key unique(user_id,name),
        constraint study_scenes_learning_topic_id_check check (learning_topic_id in ('pet_life','natural_scenery')));
      create table learning_topic_embeddings(topic_id text constraint learning_topic_embeddings_topic_id_check
        check (topic_id in ('pet_life','natural_scenery')), model text, catalog_version text, embedding real[],
        primary key(topic_id,model,catalog_version));
      create table study_scene_embeddings(scene_id uuid primary key, user_id uuid, model text, embedding real[]);
      create table sentence_embeddings(sentence_id uuid primary key, user_id uuid, model text,
        embedding real[], expression_purpose text, purpose_embedding real[], learning_topic_ids text[],
        updated_at timestamptz default now());
      create table guest_sentence_embeddings(sentence_id uuid primary key, guest_user_id uuid, guest_job_id uuid,
        model text, embedding real[], expression_purpose text, purpose_embedding real[], learning_topic_ids text[],
        updated_at timestamptz default now());
      create table study_scene_sentences(scene_id uuid, sentence_id uuid, match_score integer, match_source text,
        primary key(scene_id,sentence_id));
      create table sentence_study_progress(sentence_id uuid, correct_count integer);
      create table generation_jobs(client_request_id uuid primary key, user_id uuid, status text, updated_at timestamptz,
        memory_id uuid, image_path text, provider text, remaining_credits integer,
        error_message text, completed_at timestamptz, failed_at timestamptz);
      create table guest_generation_jobs(id uuid primary key, user_id uuid, status text, completed_at timestamptz,
        provider text, sentences jsonb, tags text[], remaining_credits integer, error_message text);
      create table generation_transactions(user_id uuid, delta integer, balance_after integer, reason text, note text);
      create table generation_enrichment_jobs(user_id uuid, memory_id uuid, guest_job_id uuid, sentences jsonb);
    `);
    await db.exec(
      definition(
        await read("20260811006000_add_semantic_study_scene_matching.sql"),
        "cosine_similarity_real_arrays",
      ),
    );
    const matching = await read(
      "20260923005000_unify_study_scene_category_matching.sql",
    );
    await db.exec(definition(matching, "study_scene_similarity_scores"));
    await db.exec(definition(matching, "semantic_study_scene_candidates"));
    await db.exec(
      definition(matching, "refresh_semantic_study_scene_matches_for_sentence"),
    );
    const metadataMigration = await read(
      "20260926001000_defer_sentence_metadata.sql",
    );
    const promotionMigration = await read(
      "20260923001000_match_sentence_or_expression_purpose.sql",
    );
    for (
      const name of [
        "preserve_enriched_sentence_categories",
        "promote_guest_sentence_embedding_for_id",
        "match_sentence_to_semantic_study_scenes",
      ]
    ) {
      await db.exec(definition(metadataMigration, name));
    }
    for (
      const name of [
        "promote_guest_sentence_embedding",
        "promote_late_guest_sentence_embedding",
      ]
    ) {
      await db.exec(definition(promotionMigration, name));
    }
    await db.exec(`
      create trigger preserve_enriched_sentence_categories
      before insert or update of learning_topic_ids on memory_sentences
      for each row execute function preserve_enriched_sentence_categories();
      create trigger promote_guest_sentence_embedding_after_memory_sentence_insert
      after insert on memory_sentences for each row execute function promote_guest_sentence_embedding();
      create trigger promote_late_guest_sentence_embedding
      after insert or update on guest_sentence_embeddings for each row execute function promote_late_guest_sentence_embedding();
      create trigger match_sentence_to_semantic_study_scenes
      after insert or update of learning_topic_ids on memory_sentences
      for each row execute function match_sentence_to_semantic_study_scenes();
    `);
    const oldMemory = crypto.randomUUID(), oldSentence = crypto.randomUUID();
    const retainedSentence = crypto.randomUUID(),
      catalogSentence = crypto.randomUUID();
    const stagedSentence = crypto.randomUUID(),
      unfinishedSentence = crypto.randomUUID();
    await db.query(
      "insert into memories values($1,$2,array['cities_and_architecture'],'photo.jpg',now(),'mimo')",
      [oldMemory, owner],
    );
    await db.query(
      "insert into memory_sentences(id,memory_id,english,chinese,is_favorite,learning_topic_ids) values($1,$2,'This is a cat.','这是一只猫。',true,array['pet_life'])",
      [oldSentence, oldMemory],
    );
    await db.query("insert into sentence_study_progress values($1,3)", [
      oldSentence,
    ]);
    await db.query(
      "insert into sentence_embeddings(sentence_id,user_id,model,embedding,expression_purpose,purpose_embedding,learning_topic_ids) values($1,$2,$3,$4,'Describing an animal.',$4,array['pet_life'])",
      [oldSentence, owner, model, [0, ...vector.slice(0, -1)]],
    );
    await db.query(
      "insert into memory_sentences(id,memory_id,english,is_favorite,learning_topic_ids) values($1,$2,'The lake is calm.',true,array['natural_scenery','pet_life']),($3,$2,'A moment to remember.',false,'{}')",
      [retainedSentence, oldMemory, catalogSentence],
    );
    await db.query(
      "insert into sentence_embeddings(sentence_id,user_id,model,embedding,expression_purpose,purpose_embedding,learning_topic_ids) values($1,$2,$3,$4,'Describing a calm lake.',$4,array['natural_scenery','pet_life'])",
      [retainedSentence, owner, model, [0, ...vector.slice(0, -1)]],
    );
    await db.query(
      "insert into guest_sentence_embeddings(sentence_id,guest_user_id,guest_job_id,model,embedding,expression_purpose,purpose_embedding,learning_topic_ids) values($1,$2,$3,$4,$5,'Describing a calm lake.',$5,array['pet_life','natural_scenery']),($6,$2,$3,$4,$5,'Describing a calm lake.',$5,null)",
      [
        stagedSentence,
        other,
        crypto.randomUUID(),
        model,
        vector,
        unfinishedSentence,
      ],
    );
    const vectorSnapshot = async () => ({
      authenticated: (await db.query(
        "select sentence_id,user_id,model,embedding,expression_purpose,purpose_embedding,updated_at from sentence_embeddings order by sentence_id",
      )).rows,
      guest: (await db.query(
        "select sentence_id,guest_user_id,guest_job_id,model,embedding,expression_purpose,purpose_embedding,updated_at from guest_sentence_embeddings order by sentence_id",
      )).rows,
    });
    const beforeVectors = await vectorSnapshot();
    await db.query(
      "insert into learning_topic_embeddings values('pet_life',$1,'photo-life-v1',$2)",
      [model, vector],
    );
    const migration = await read("20261009003000_unify_scene_categories.sql");
    await db.exec(migration);
    await db.exec(migration);

    await t.step(
      "canonical and staged categories are cleaned with real preservation and promotion triggers active",
      async () => {
        deepStrictEqual(await vectorSnapshot(), beforeVectors);
        const categories = async (table: string, sentence: string) =>
          (await db.query<any>(
            `select learning_topic_ids from ${table} where sentence_id=$1`,
            [sentence],
          )).rows[0].learning_topic_ids;
        deepStrictEqual(
          await categories("sentence_embeddings", oldSentence),
          [],
        );
        deepStrictEqual(
          await categories("sentence_embeddings", retainedSentence),
          ["natural_scenery"],
        );
        deepStrictEqual(
          await categories("guest_sentence_embeddings", stagedSentence),
          ["natural_scenery"],
        );
        strictEqual(
          await categories("guest_sentence_embeddings", unfinishedSentence),
          null,
        );
        deepStrictEqual(
          (await db.query<any>(
            "select learning_topic_ids from memory_sentences where id=$1",
            [retainedSentence],
          )).rows[0].learning_topic_ids,
          ["natural_scenery"],
        );
        // A stale client payload must not overwrite the cleaned canonical metadata.
        await db.query(
          "update memory_sentences set learning_topic_ids=array['cooking'] where id=$1",
          [oldSentence],
        );
        deepStrictEqual(
          (await db.query<any>(
            "select learning_topic_ids from memory_sentences where id=$1",
            [oldSentence],
          )).rows[0].learning_topic_ids,
          [],
        );
      },
    );

    await t.step(
      "new migration runs repeatedly without resetting content, favorites, progress or credits",
      async () => {
        deepStrictEqual(
          (await db.query<any>(
            "select english,is_favorite,learning_topic_ids from memory_sentences where id=$1",
            [oldSentence],
          )).rows[0],
          {
            english: "This is a cat.",
            is_favorite: true,
            learning_topic_ids: [],
          },
        );
        strictEqual(
          (await db.query<any>(
            "select correct_count from sentence_study_progress",
          )).rows[0].correct_count,
          3,
        );
        strictEqual(
          (await db.query<any>(
            "select available_generations from profiles where id=$1",
            [owner],
          )).rows[0].available_generations,
          10,
        );
        deepStrictEqual(
          (await db.query<any>("select tags from memories where id=$1", [
            oldMemory,
          ])).rows[0].tags,
          [],
        );
        strictEqual(
          (await db.query<any>(
            "select count(*)::int as n from learning_topic_embeddings",
          )).rows[0].n,
          0,
        );
      },
    );

    await t.step(
      "every category is accepted by both JSON and photo normalization and table checks",
      async () => {
        for (const [id] of SCENE_CATEGORIES) {
          deepStrictEqual(
            (await db.query<any>(
              "select learning_topic_ids_from_json($1::jsonb) as ids, normalize_memory_photo_categories($2::text[]) as tags",
              [JSON.stringify([id]), [id]],
            )).rows[0],
            { ids: [id], tags: [id] },
          );
          await db.query(
            "update memory_sentences set learning_topic_ids=$1 where id=$2",
            [[id], catalogSentence],
          );
          await db.query(
            "insert into learning_topic_embeddings values($1,$2,$3,$4)",
            [id, model, SCENE_CATEGORY_CATALOG_VERSION, vector],
          );
        }
        await rejects(
          () =>
            db.query(
              "update memory_sentences set learning_topic_ids=array['pet_life'] where id=$1",
              [catalogSentence],
            ),
          /check constraint/,
        );
        await rejects(
          () =>
            db.query(
              "update memory_sentences set learning_topic_ids=$1 where id=$2",
              [[
                SCENE_CATEGORIES[0][0],
                SCENE_CATEGORIES[1][0],
                SCENE_CATEGORIES[2][0],
              ], catalogSentence],
            ),
          /check constraint/,
        );
        await rejects(
          () =>
            db.query(
              "insert into learning_topic_embeddings values('unknown',$1,$2,$3)",
              [model, SCENE_CATEGORY_CATALOG_VERSION, vector],
            ),
          /check constraint/,
        );
        deepStrictEqual(
          (await db.query<any>(
            "select learning_topic_ids_from_json($1::jsonb) as ids",
            [JSON.stringify([
              null,
              7,
              {},
              " food_and_drinks ",
              "food_and_drinks",
              "cooking",
              "home_life",
            ])],
          )).rows[0].ids,
          ["food_and_drinks", "cooking"],
        );
        for (const value of [null, {}, 7, "food_and_drinks"]) {
          deepStrictEqual(
            (await db.query<any>(
              "select learning_topic_ids_from_json($1::jsonb) as ids",
              [JSON.stringify(value)],
            )).rows[0].ids,
            [],
          );
        }
        await db.exec(migration);
        strictEqual(
          (await db.query<any>(
            "select count(*)::int as n from learning_topic_embeddings",
          )).rows[0].n,
          25,
        );
      },
    );

    await t.step(
      "matching and preparation use the new catalog version and all 25 category vectors",
      async () => {
        const scene = crypto.randomUUID();
        await db.query(
          "insert into study_scenes(id,user_id,name) values($1,$2,'Animals')",
          [scene, owner],
        );
        await db.query(
          "insert into study_scene_embeddings values($1,$2,$3,$4)",
          [scene, owner, model, vector],
        );
        await db.query(
          "update memory_sentences set learning_topic_ids=array['pets_and_animals'] where id=$1",
          [catalogSentence],
        );
        await db.query(
          "insert into sentence_embeddings(sentence_id,user_id,model,embedding,expression_purpose,purpose_embedding,learning_topic_ids) values($1,$2,$3,$4,'Describing an animal.',$5,array['pets_and_animals'])",
          [catalogSentence, owner, model, [0, ...vector.slice(0, -1)], vector],
        );
        await db.query("select set_config('request.jwt.claim.sub',$1,false)", [
          owner,
        ]);
        strictEqual(
          (await db.query<any>(
            "select refresh_semantic_study_scene_matches_for_owner($1,$2) as n",
            [scene, owner],
          )).rows[0].n,
          1,
        );
        const settings = async () =>
          (await db.query<any>(
            "select get_study_scene_match_settings($1) as settings",
            [scene],
          )).rows[0].settings;
        strictEqual((await settings()).needs_preparation, false);
        const scores = (await db.query<any>(
          "select * from study_scene_similarity_scores($1,$2,$3)",
          [scene, owner, catalogSentence],
        )).rows;
        strictEqual(scores[0].category_topic_id, "pets_and_animals");
        await db.query(
          "delete from learning_topic_embeddings where topic_id='objects_and_details'",
        );
        strictEqual((await settings()).needs_preparation, true);
        await db.query("select set_config('request.jwt.claim.sub',$1,false)", [
          other,
        ]);
        await rejects(settings, /Study scene not found/);
      },
    );

    await t.step(
      "authenticated and anonymous finalization preserve new classifications and debit exactly once",
      async () => {
        const finalizers = await read(
          "20261009000000_add_photo_scene_categories.sql",
        );
        for (
          const name of [
            "finalize_authenticated_generation",
            "finalize_guest_generation",
          ]
        ) await db.exec(definition(finalizers, name));
        const sentences = SCENE_CATEGORIES.slice(0, 6).map(([id], i) => ({
          id: crypto.randomUUID(),
          english: "A moment to remember.",
          chinese: "一个值得记住的时刻。",
          learning_topic_ids: [id],
          presentation_group: i < 3 ? "what_i_see" : "what_i_say",
          expression_purpose: "Describing a moment.",
          is_favorite: false,
        }));
        const memoryID = crypto.randomUUID(), requestID = crypto.randomUUID();
        const finish = () =>
          db.query<any>(
            "select finalize_authenticated_generation($1,$2,$3,'new.jpg',now(),'deepseek',$4::jsonb,$5::text[]) as balance",
            [owner, memoryID, requestID, JSON.stringify(sentences), [
              "cooking",
              "work_life",
            ]],
          );
        strictEqual((await finish()).rows[0].balance, 9);
        strictEqual((await finish()).rows[0].balance, 9);
        deepStrictEqual(
          (await db.query<any>(
            "select learning_topic_ids from memory_sentences where memory_id=$1 order by sort_order",
            [memoryID],
          )).rows.map((r) => r.learning_topic_ids),
          sentences.map((s) => s.learning_topic_ids),
        );
        deepStrictEqual(
          (await db.query<any>("select tags from memories where id=$1", [
            memoryID,
          ])).rows[0].tags,
          ["cooking", "work_life"],
        );
        const guestID = crypto.randomUUID();
        await db.query(
          "insert into guest_generation_jobs(id,user_id,status) values($1,$2,'pending')",
          [guestID, other],
        );
        const finishGuest = () =>
          db.query<any>(
            "select finalize_guest_generation($1,$2,now(),'deepseek',$3::jsonb,$4::text[]) as balance",
            [other, guestID, JSON.stringify(sentences), [
              "family_time",
              "flowers_and_plants",
            ]],
          );
        strictEqual((await finishGuest()).rows[0].balance, 9);
        strictEqual((await finishGuest()).rows[0].balance, 9);
        const guest = (await db.query<any>(
          "select sentences,tags from guest_generation_jobs where id=$1",
          [guestID],
        )).rows[0];
        deepStrictEqual(guest.sentences, sentences);
        deepStrictEqual(guest.tags, ["family_time", "flowers_and_plants"]);
        strictEqual(
          (await db.query<any>(
            "select count(*)::int as n from generation_transactions",
          )).rows[0].n,
          2,
        );
        strictEqual(
          (await db.query<any>(
            "select count(*)::int as n from generation_enrichment_jobs",
          )).rows[0].n,
          2,
        );
      },
    );

    await t.step(
      "late guest-vector promotion cannot restore retired categories after migration",
      async () => {
        // Simulate a delayed worker publishing categories from before deployment.
        await db.query(
          "update guest_sentence_embeddings set learning_topic_ids=array['pet_life','natural_scenery'] where sentence_id=$1",
          [stagedSentence],
        );
        await db.query(
          "insert into memory_sentences(id,memory_id,english,learning_topic_ids) values($1,$2,'The lake is calm.',array['natural_scenery'])",
          [stagedSentence, oldMemory],
        );
        deepStrictEqual(
          (await db.query<any>(
            "select learning_topic_ids from memory_sentences where id=$1",
            [stagedSentence],
          )).rows[0].learning_topic_ids,
          ["natural_scenery"],
        );
        const promoted = (await db.query<any>(
          "select user_id,embedding,purpose_embedding,expression_purpose from sentence_embeddings where sentence_id=$1",
          [stagedSentence],
        )).rows[0];
        deepStrictEqual(promoted, {
          user_id: owner,
          embedding: vector,
          purpose_embedding: vector,
          expression_purpose: "Describing a calm lake.",
        });
        strictEqual(
          (await db.query<any>(
            "select count(*)::int as n from guest_sentence_embeddings where sentence_id=$1",
            [stagedSentence],
          )).rows[0].n,
          0,
        );
        await db.exec(migration);
        deepStrictEqual(
          (await db.query<any>(
            "select learning_topic_ids from sentence_embeddings where sentence_id=$1",
            [stagedSentence],
          )).rows[0].learning_topic_ids,
          ["natural_scenery"],
        );
      },
    );

    await t.step(
      "normalization remains a service-only write helper",
      async () => {
        for (const role of ["anon", "authenticated"]) {
          strictEqual(
            (await db.query<any>(
              "select has_function_privilege($1,'preserve_enriched_sentence_categories()','EXECUTE') as allowed",
              [role],
            )).rows[0].allowed,
            false,
          );
        }
        for (
          const fn of [
            "normalize_scene_category_ids(text[],integer)",
            "normalize_memory_photo_categories(text[])",
            "learning_topic_ids_from_json(jsonb)",
          ]
        ) {
          for (const role of ["anon", "authenticated", "service_role"]) {
            strictEqual(
              (await db.query<any>(
                "select has_function_privilege($1,$2,'EXECUTE') as allowed",
                [role, fn],
              )).rows[0].allowed,
              role === "service_role",
            );
          }
        }
      },
    );
  } finally {
    await db.close();
  }
});
