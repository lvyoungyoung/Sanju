import { deepStrictEqual, strictEqual } from "node:assert";
import { PGlite } from "npm:@electric-sql/pglite@0.5.8";

const migrationDirectory = new URL(
  "../../supabase/migrations/",
  import.meta.url,
);
const migration = await readMigration(
  "20260920000000_review_custom_study_scene_matches.sql",
);
const originalMatching = await readMigration(
  "20260811006000_add_semantic_study_scene_matching.sql",
);
const topicMatching = await readMigration(
  "20260901000000_replace_scene_hint_with_learning_topics.sql",
);
const sceneCreation = await readMigration(
  "20260822010000_add_study_scene_cover_memory.sql",
);
const guestPromotion = await readMigration(
  "20260812000000_stage_anonymous_sentence_embeddings.sql",
);
const model = "qwen3.7-text-embedding";
const owner = "10000000-0000-0000-0000-000000000001";
const otherOwner = "10000000-0000-0000-0000-000000000002";

// Use PostgreSQL itself, not a JS reimplementation of the matching rules.
// The minimal fixture schema excludes unrelated auth/network/generation services.
const schema = `
  create role anon;
  create role authenticated;
  create role service_role;
  create schema auth;
  create function auth.uid() returns uuid language sql stable as
    $$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
  create table auth.users (id uuid primary key);
  create table public.memories (
    id uuid primary key, user_id uuid not null references auth.users(id),
    image_url text, created_at timestamptz not null default now()
  );
  create table public.memory_sentences (
    id uuid primary key, memory_id uuid not null references public.memories(id),
    english text not null default 'Test sentence', chinese text not null default 'Translation',
    sort_order integer not null default 0, is_favorite boolean not null default false,
    learning_topic_ids text[] not null default '{}'
  );
  create table public.study_scenes (
    id uuid primary key default gen_random_uuid(), user_id uuid not null references auth.users(id),
    name text not null, learning_topic_id text, created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    constraint study_scenes_user_id_name_key unique (user_id, name)
  );
  create table public.study_scene_sentences (
    scene_id uuid not null references public.study_scenes(id) on delete cascade,
    sentence_id uuid not null references public.memory_sentences(id) on delete cascade,
    match_score integer not null check (match_score between 1 and 100),
    match_source text not null default 'automatic', created_at timestamptz not null default now(),
    primary key (scene_id, sentence_id)
  );
  create table public.sentence_embeddings (
    sentence_id uuid primary key references public.memory_sentences(id) on delete cascade,
    user_id uuid not null references auth.users(id), embedding real[] not null,
    model text not null, updated_at timestamptz not null default now()
  );
  create table public.study_scene_embeddings (
    scene_id uuid primary key references public.study_scenes(id) on delete cascade,
    user_id uuid not null references auth.users(id), embedding real[] not null,
    model text not null, updated_at timestamptz not null default now()
  );
  create table public.sentence_study_progress (
    id uuid primary key default gen_random_uuid(), user_id uuid not null references auth.users(id),
    sentence_id uuid not null references public.memory_sentences(id), study_scope text not null,
    correct_count integer not null default 0, last_studied_on date, next_review_at timestamptz
  );
`;

async function readMigration(name: string) {
  return await Deno.readTextFile(new URL(name, migrationDirectory));
}

function functionSQL(source: string, name: string) {
  const match = source.match(
    new RegExp(
      `create (?:or replace )?function public\\.${name}\\([\\s\\S]*?\\$\\$;`,
      "i",
    ),
  );
  if (!match) throw new Error(`Missing source function: ${name}`);
  return match[0];
}

// A unit vector whose cosine with the theme [1, 0, ...] is the requested score.
function vector(score: number) {
  return [score, Math.sqrt(1 - score * score), ...Array(1022).fill(0)];
}

Deno.test("custom themes require cached AI approval", async (t) => {
  const db = new PGlite();
  try {
    await db.exec(schema);
    await db.exec(
      functionSQL(originalMatching, "cosine_similarity_real_arrays"),
    );
    await db.exec(
      functionSQL(originalMatching, "jsonb_to_embedding_real_array"),
    );
    await db.exec(
      functionSQL(sceneCreation, "get_study_scene_summary_for_owner"),
    );
    await db.exec(
      functionSQL(sceneCreation, "create_study_scene_with_embedding"),
    );
    await db.exec(topicMatching.slice(
      topicMatching.indexOf(
        "create or replace function public.refresh_learning_topic_study_scene_matches_for_owner",
      ),
      topicMatching.indexOf(
        "-- Semantic scenes must never remove exact topic links",
      ),
    ));
    // Install the previous signatures first to catch CREATE OR REPLACE regressions.
    await db.exec(
      functionSQL(
        topicMatching,
        "refresh_semantic_study_scene_matches_for_owner",
      ),
    );
    await db.exec(
      functionSQL(
        topicMatching,
        "refresh_semantic_study_scene_matches_for_sentence",
      ),
    );
    await db.exec(guestPromotion);
    await db.exec(migration);

    async function reset() {
      await db.exec("truncate auth.users cascade");
      await db.query("insert into auth.users values ($1), ($2)", [
        owner,
        otherOwner,
      ]);
    }

    async function scene(
      options: {
        user?: string;
        topic?: string;
        embedded?: boolean;
        embeddingModel?: string;
      } = {},
    ) {
      const id = crypto.randomUUID();
      const user = options.user ?? owner;
      await db.query(
        "insert into study_scenes (id, user_id, name, learning_topic_id) values ($1, $2, $3, $4)",
        [id, user, `Theme ${id.slice(0, 8)}`, options.topic ?? null],
      );
      if (options.embedded !== false) {
        await db.query(
          "insert into study_scene_embeddings (scene_id, user_id, embedding, model) values ($1, $2, $3, $4)",
          [id, user, vector(1), options.embeddingModel ?? model],
        );
      }
      return id;
    }

    async function sentence(
      score: number,
      options: {
        user?: string;
        embeddingOwner?: string;
        embeddingModel?: string;
        topic?: string;
        favorite?: boolean;
        embedded?: boolean;
      } = {},
    ) {
      const id = crypto.randomUUID();
      const memoryID = crypto.randomUUID();
      const user = options.user ?? owner;
      await db.query("insert into memories (id, user_id) values ($1, $2)", [
        memoryID,
        user,
      ]);
      await db.query(
        "insert into memory_sentences (id, memory_id, learning_topic_ids, is_favorite) values ($1, $2, $3, $4)",
        [
          id,
          memoryID,
          options.topic ? [options.topic] : [],
          options.favorite ?? false,
        ],
      );
      if (options.embedded !== false) {
        await db.query(
          "insert into sentence_embeddings (sentence_id, user_id, embedding, model) values ($1, $2, $3, $4)",
          [
            id,
            options.embeddingOwner ?? user,
            vector(score),
            options.embeddingModel ?? model,
          ],
        );
      }
      return id;
    }

    async function refresh(
      sceneID: string,
      user = owner,
      threshold: number | null = null,
    ) {
      return await db.query(
        "select refresh_semantic_study_scene_matches_for_owner($1, $2, $3)",
        [sceneID, user, threshold],
      );
    }

    async function matchNew(sentenceID: string, user = owner) {
      return await db.query(
        "select refresh_semantic_study_scene_matches_for_sentence($1, $2)",
        [sentenceID, user],
      );
    }

    async function links(sceneID: string) {
      const result = await db.query<{ sentence_id: string }>(
        "select sentence_id from study_scene_sentences where scene_id = $1 order by sentence_id",
        [sceneID],
      );
      return result.rows.map((row) => row.sentence_id);
    }

    async function expectLinks(sceneID: string, expected: string[]) {
      deepStrictEqual(await links(sceneID), expected.toSorted());
    }

    async function claim(sceneID: string | null = null, user = owner) {
      return (await db.query<any>(
        "select * from claim_study_scene_sentence_reviews($1, $2)",
        [user, sceneID],
      )).rows;
    }
    async function complete(rows: any[], keep: boolean, user = owner) {
      const decisions = rows.map((row) => ({
        ...row,
        keep,
        reason: keep ? "Direct evidence" : "Too generic",
      }));
      return (await db.query<any>(
        "select complete_study_scene_sentence_reviews($1, $2::jsonb) as count",
        [user, JSON.stringify(decisions)],
      )).rows[0].count;
    }

    await t.step(
      "similarity supplies candidates but never directly approves a sentence",
      async () => {
        await reset();
        const topic = await scene();
        const candidate = await sentence(0.45);
        await sentence(0.41);
        await refresh(topic);
        await expectLinks(topic, []);
        const claims = await claim(topic);
        deepStrictEqual(claims.map((row) => row.sentence_id), [candidate]);
        await complete(claims, true);
        await expectLinks(topic, [candidate]);
      },
    );

    await t.step(
      "high similarity is still rejected without positive AI review",
      async () => {
        await reset();
        const topic = await scene();
        await sentence(0.99);
        await refresh(topic);
        await complete(await claim(topic), false);
        await expectLinks(topic, []);
      },
    );

    await t.step(
      "creation preserves the RPC response contract while awaiting review",
      async () => {
        await reset();
        await sentence(0.80);
        const result = await db.query<any>(
          "select * from create_study_scene_with_embedding($1, $2, $3::jsonb, $4)",
          [owner, "Beach holiday", JSON.stringify(vector(1)), model],
        );
        strictEqual(result.rows[0].total_count, 0);
        strictEqual(result.rows[0].cover_memory_id, null);
        strictEqual((await claim(result.rows[0].id)).length, 1);
      },
    );

    await t.step(
      "accepted and rejected decisions are cached across refreshes",
      async () => {
        await reset();
        const topic = await scene();
        const accepted = await sentence(0.60);
        const rejected = await sentence(0.90);
        await refresh(topic);
        const claims = await claim(topic);
        await complete(
          claims.filter((row) => row.sentence_id === accepted),
          true,
        );
        await complete(
          claims.filter((row) => row.sentence_id === rejected),
          false,
        );
        await refresh(topic);
        await matchNew(accepted);
        await matchNew(rejected);
        strictEqual((await claim(topic)).length, 0);
        await expectLinks(topic, [accepted]);
      },
    );

    await t.step(
      "new best candidates do not displace already approved sentences",
      async () => {
        await reset();
        const topic = await scene();
        const approved = await sentence(0.50, { favorite: true });
        await matchNew(approved);
        await complete(await claim(topic), true);
        await db.query(
          "insert into sentence_study_progress (user_id, sentence_id, study_scope, correct_count) values ($1, $2, $3, 4)",
          [owner, approved, `scene:${topic}`],
        );
        await matchNew(await sentence(0.99));
        await complete(await claim(topic), false);
        await expectLinks(topic, [approved]);
        const rows = await db.query<any>(
          "select is_favorite, correct_count from memory_sentences join sentence_study_progress on sentence_id = memory_sentences.id where sentence_id = $1",
          [approved],
        );
        strictEqual(rows.rows[0].is_favorite, true);
        strictEqual(rows.rows[0].correct_count, 4);
      },
    );

    await t.step(
      "failed batches back off; retry uses a new lease and never falls back to semantic approval",
      async () => {
        await reset();
        const topic = await scene();
        await matchNew(await sentence(0.80));
        const first = await claim(topic);
        await db.query(
          "select defer_study_scene_sentence_reviews($1, $2::jsonb)",
          [owner, JSON.stringify(first)],
        );
        await expectLinks(topic, []);
        strictEqual((await claim(topic)).length, 0);
        const status = await db.query<any>(
          "select * from get_study_scene_review_status($1, $2)",
          [owner, topic],
        );
        strictEqual(status.rows[0].pending_count, 1);
        strictEqual(status.rows[0].retry_after_seconds >= 28, true);
        await db.exec(
          "update study_scene_sentence_reviews set retry_at = now() - interval '1 minute'",
        );
        const retried = await claim(topic);
        strictEqual(first[0].lease_token === retried[0].lease_token, false);
        strictEqual(await complete(first, true), 0);
        strictEqual(await complete(retried, true), 1);
      },
    );

    await t.step(
      "only one active batch per user and at most twenty candidates per batch",
      async () => {
        await reset();
        const topic = await scene();
        for (let index = 0; index < 23; index++) await sentence(0.60);
        await refresh(topic);
        const batch = await claim(topic);
        strictEqual(batch.length, 20);
        strictEqual((await claim(topic)).length, 0);
        await complete(batch, false);
        strictEqual((await claim(topic)).length, 3);
      },
    );

    await t.step("an interrupted worker lease expires safely", async () => {
      await reset();
      const topic = await scene();
      await matchNew(await sentence(0.80));
      const previous = await claim(topic);
      await db.exec(
        "update study_scene_sentence_reviews set lease_until = now() - interval '1 second'",
      );
      strictEqual(await complete(previous, true), 0);
      const next = await claim(topic);
      strictEqual(next.length, 1);
      strictEqual(await complete(previous, true), 0);
      strictEqual(await complete(next, true), 1);
    });

    await t.step(
      "content changes invalidate cached decisions and stale in-flight replies",
      async () => {
        await reset();
        const topic = await scene();
        const item = await sentence(0.80);
        await refresh(topic);
        const previous = await claim(topic);
        await db.query(
          "update memory_sentences set english = 'A different sentence' where id = $1",
          [item],
        );
        strictEqual(await complete(previous, true), 0);
        await expectLinks(topic, []);
        const next = await claim(topic);
        strictEqual(next[0].input_hash === previous[0].input_hash, false);
        await complete(next, true);
        await db.query(
          "update memory_sentences set chinese = 'Changed translation' where id = $1",
          [item],
        );
        await matchNew(item);
        await expectLinks(topic, []);
        strictEqual((await claim(topic)).length, 1);
      },
    );

    await t.step(
      "theme deletion and stale replies cannot recreate links",
      async () => {
        await reset();
        const topic = await scene();
        await matchNew(await sentence(0.80));
        const claims = await claim(topic);
        await db.query("delete from study_scenes where id = $1", [topic]);
        strictEqual(await complete(claims, true), 0);
        await expectLinks(topic, []);
      },
    );

    await t.step(
      "category topics bypass review and keep exact matches",
      async () => {
        await reset();
        const topic = await scene({ topic: "food_and_cooking" });
        const item = await sentence(0.10, { topic: "food_and_cooking" });
        await refresh(topic);
        await matchNew(item);
        await expectLinks(topic, [item]);
        strictEqual((await claim(topic)).length, 0);
      },
    );

    await t.step(
      "wrong owner, missing embeddings and mismatched models cannot enter the queue",
      async () => {
        await reset();
        const topic = await scene();
        const missing = await scene({ embedded: false });
        const valid = await sentence(0.60);
        const other = await sentence(0.99, { user: otherOwner });
        await sentence(0.99, { user: otherOwner, embeddingOwner: owner });
        await sentence(0.99, { embeddingModel: "another-model" });
        await sentence(0.99, { embedded: false });
        await refresh(topic);
        await refresh(missing);
        await matchNew(other, owner);
        strictEqual((await claim(topic, otherOwner)).length, 0);
        const batch = await claim(topic);
        deepStrictEqual(batch.map((row) => row.sentence_id), [valid]);
        strictEqual(await complete(batch, true, otherOwner), 0);
        strictEqual(await complete(batch, true), 1);
      },
    );

    await t.step("zero and NaN vectors are not review candidates", async () => {
      await reset();
      const topic = await scene();
      const item = await sentence(0.90);
      for (const value of ["0", "'NaN'"]) {
        await db.query(
          `update sentence_embeddings set embedding = array_fill(${value}::real, array[1024]) where sentence_id = $1`,
          [item],
        );
        await refresh(topic);
        await matchNew(item);
        strictEqual((await claim(topic)).length, 0);
      }
    });

    await t.step(
      "anonymous imports queue review instead of bypassing it",
      async () => {
        await reset();
        const topic = await scene();
        const id = crypto.randomUUID();
        const memoryID = crypto.randomUUID();
        await db.query(
          "insert into guest_sentence_embeddings (sentence_id, guest_user_id, guest_job_id, embedding, model) values ($1, $2, $3, $4, $5)",
          [id, otherOwner, crypto.randomUUID(), vector(0.70), model],
        );
        await db.query("insert into memories (id, user_id) values ($1, $2)", [
          memoryID,
          owner,
        ]);
        await db.query(
          "insert into memory_sentences (id, memory_id) values ($1, $2)",
          [id, memoryID],
        );
        await expectLinks(topic, []);
        await complete(await claim(topic), true);
        await expectLinks(topic, [id]);
      },
    );

    await t.step(
      "legacy unreviewed links are requeued without deleting study history",
      async () => {
        await reset();
        const topic = await scene();
        await scene({ embedded: false });
        const category = await scene({ topic: "food_and_cooking" });
        const item = await sentence(0.70, {
          favorite: true,
          topic: "food_and_cooking",
        });
        await db.query(
          "insert into study_scene_sentences (scene_id, sentence_id, match_score, match_source) values ($1, $2, 70, 'semantic')",
          [topic, item],
        );
        await db.query(
          "insert into sentence_study_progress (user_id, sentence_id, study_scope, correct_count) values ($1, $2, $3, 5)",
          [owner, item, `scene:${topic}`],
        );
        await db.exec(
          migration.slice(
            migration.indexOf("-- Remove unverified legacy links"),
            migration.indexOf("revoke all on function"),
          ),
        );
        await expectLinks(topic, []);
        await expectLinks(category, [item]);
        strictEqual((await claim(topic)).length, 1);
        strictEqual(
          (await db.query<any>(
            "select correct_count from sentence_study_progress where sentence_id = $1",
            [item],
          )).rows[0].correct_count,
          5,
        );
      },
    );

    await t.step(
      "untrusted roles cannot invoke review RPCs or read review rows",
      async () => {
        for (const role of ["anon", "authenticated"]) {
          for (
            const signature of [
              "claim_study_scene_sentence_reviews(uuid,uuid)",
              "complete_study_scene_sentence_reviews(uuid,jsonb)",
              "defer_study_scene_sentence_reviews(uuid,jsonb)",
              "get_study_scene_review_status(uuid,uuid)",
            ]
          ) {
            const result = await db.query<any>(
              "select has_function_privilege($1, $2, 'EXECUTE') as allowed",
              [role, signature],
            );
            strictEqual(result.rows[0].allowed, false);
          }
          const result = await db.query<any>(
            "select has_table_privilege($1, 'study_scene_sentence_reviews', 'SELECT') as allowed",
            [role],
          );
          strictEqual(result.rows[0].allowed, false);
        }
      },
    );
  } finally {
    await db.close();
  }
});
