import { deepStrictEqual, rejects, strictEqual } from "node:assert";
import { PGlite } from "npm:@electric-sql/pglite@0.5.8";

const root = new URL("../../supabase/migrations/", import.meta.url);
const owner = "10000000-0000-0000-0000-000000000001";
const guest = "10000000-0000-0000-0000-000000000002";
const vector = [1, ...Array(1023).fill(0)];
const payload = (count = 6) =>
  Array.from({ length: count }, () => ({
    id: crypto.randomUUID(),
    english: "The lake is calm.",
    chinese: "湖面很平静。",
    expression_purpose: "Describing a calm lake.",
  }));
function functionSQL(source: string, name: string) {
  const match = source.match(
    new RegExp(
      `create or replace function public\\.${name}\\([\\s\\S]*?\\$\\$;`,
    ),
  );
  if (!match) throw new Error(name);
  return match[0];
}

Deno.test("durable generation enrichment preserves transactions, leases and guest migration", async (t) => {
  const db = new PGlite();
  try {
    await db.exec(`
      create role anon; create role authenticated; create role service_role;
      create schema auth; create table auth.users(id uuid primary key);
      insert into auth.users values ('${owner}'),('${guest}');
      create table profiles(id uuid primary key references auth.users(id) on delete cascade, available_generations int);
      insert into profiles values ('${owner}',100),('${guest}',100);
      create table memories(id uuid primary key, user_id uuid references profiles(id) on delete cascade,
        image_url text, created_at timestamptz, provider text, tags text[]);
      create table memory_sentences(id uuid primary key, memory_id uuid references memories(id) on delete cascade,
        sort_order int, english text not null, chinese text, learning_topic_ids text[], presentation_group text, is_favorite boolean);
      create table generation_transactions(user_id uuid, delta int, balance_after int, reason text, note text);
      create table generation_jobs(client_request_id uuid primary key, user_id uuid, status text,
        memory_id uuid references memories(id) on delete set null, image_path text, provider text,
        remaining_credits int, error_message text, updated_at timestamptz, completed_at timestamptz, failed_at timestamptz);
      create table guest_generation_jobs(id uuid primary key, user_id uuid, status text, completed_at timestamptz,
        provider text, sentences jsonb, tags text[], remaining_credits int, error_message text);
      create function learning_topic_ids_from_json(jsonb) returns text[] language sql as $$ select '{}'::text[] $$;
      create table sentence_embeddings(sentence_id uuid primary key references memory_sentences(id) on delete cascade,
        user_id uuid, embedding real[], model text, expression_purpose text, purpose_embedding real[], updated_at timestamptz);
      create table matched_sentences(sentence_id uuid primary key references memory_sentences(id) on delete cascade, user_id uuid);
      create table match_control(fail boolean); insert into match_control values(false);
      create function refresh_semantic_study_scene_matches_for_sentence(p_sentence_id uuid,p_user_id uuid)
      returns int language plpgsql as $$ begin
        if (select fail from match_control) then raise exception 'matching temporarily unavailable'; end if;
        insert into matched_sentences values(p_sentence_id,p_user_id) on conflict(sentence_id) do nothing;
        return 1;
      end $$;
    `);
    await db.exec(
      functionSQL(
        await Deno.readTextFile(
          new URL("20260811006000_add_semantic_study_scene_matching.sql", root),
        ),
        "jsonb_to_embedding_real_array",
      ),
    );
    await db.exec(
      await Deno.readTextFile(
        new URL("20260812000000_stage_anonymous_sentence_embeddings.sql", root),
      ),
    );
    await db.exec(
      "alter table guest_sentence_embeddings alter column embedding drop not null, add column expression_purpose text, add column purpose_embedding real[]",
    );
    const late = await Deno.readTextFile(
      new URL("20260923001000_match_sentence_or_expression_purpose.sql", root),
    );
    for (
      const name of [
        "promote_guest_sentence_embedding_for_id",
        "promote_guest_sentence_embedding",
        "promote_late_guest_sentence_embedding",
      ]
    ) {
      await db.exec(functionSQL(late, name));
    }
    await db.exec(
      `create trigger promote_late_guest_sentence_embedding after insert or update on guest_sentence_embeddings
      for each row execute function promote_late_guest_sentence_embedding()`,
    );
    await db.exec(
      await Deno.readTextFile(
        new URL("20260925001000_defer_generation_enrichment.sql", root),
      ),
    );
    await db.exec(
      functionSQL(
        await Deno.readTextFile(
          new URL("20260920001000_use_photo_life_scenes.sql", root),
        ),
        "learning_topic_ids_from_json",
      ),
    );
    await db.exec(
      await Deno.readTextFile(
        new URL("20260926001000_defer_sentence_metadata.sql", root),
      ),
    );
    await db.exec(`create trigger match_sentence_to_semantic_study_scenes
      after insert or update of learning_topic_ids on memory_sentences
      for each row execute function match_sentence_to_semantic_study_scenes()`);
    const balance = async () =>
      (await db.query<any>(
        "select available_generations from profiles where id=$1",
        [owner],
      )).rows[0].available_generations;
    const count = async (table: string) =>
      (await db.query<any>(`select count(*)::int as n from ${table}`)).rows[0]
        .n;
    const finish = (
      memoryID: string,
      requestID: string | null,
      sentences = payload(),
    ) =>
      db.query<any>(
        "select finalize_authenticated_generation($1,$2,$3,'photo.jpg',now(),'mimo',$4::jsonb,'{}') as balance",
        [owner, memoryID, requestID, JSON.stringify(sentences)],
      );
    const claim = async (user: string | null = owner) =>
      (await db.query<any>("select * from claim_generation_enrichment($1)", [
        user,
      ])).rows[0];
    const rows = (job: any) =>
      job.sentences.map((s: any) => ({
        sentence_id: s.id,
        embedding: vector,
        purpose_embedding: vector,
      }));
    const complete = async (job: any, values = rows(job)) =>
      (await db.query<any>(
        "select complete_generation_enrichment($1,$2,$3::jsonb) as done",
        [job.id, job.lease_token, JSON.stringify(values)],
      )).rows[0].done;
    const metadata = (job: any) =>
      job.sentences.map((s: any) => ({
        sentence_id: s.id,
        learning_topic_ids: ["natural_scenery"],
        expression_purpose: "Describing a calm lake.",
      }));
    const checkpoint = async (job: any, value = metadata(job)) =>
      (await db.query<any>(
        "select save_generation_enrichment_metadata($1,$2,$3::jsonb) as saved",
        [job.id, job.lease_token, JSON.stringify(value)],
      )).rows[0].saved;

    await t.step(
      "result and debit commit before indexing; replay cannot debit or enqueue twice",
      async () => {
        const memory = crypto.randomUUID(), request = crypto.randomUUID();
        await finish(memory, request);
        strictEqual(await balance(), 99);
        strictEqual(await count("sentence_embeddings"), 0);
        strictEqual(await count("matched_sentences"), 0);
        strictEqual(await count("generation_enrichment_jobs"), 1);
        await finish(crypto.randomUUID(), request);
        strictEqual(await balance(), 99);
        strictEqual(await count("generation_enrichment_jobs"), 1);
        const job = await claim();
        strictEqual(job.memory_id, memory);
        strictEqual(await claim(), undefined);
        strictEqual(await complete(job), true);
        strictEqual(await complete(job), false);
        strictEqual(await count("sentence_embeddings"), 6);
        strictEqual(await count("matched_sentences"), 6);
        strictEqual(await balance(), 99);
      },
    );
    await t.step(
      "failure to enqueue rolls back memory, sentences, debit and generation job",
      async () => {
        await db.exec(
          "alter table generation_enrichment_jobs add constraint force_failure check (false) not valid",
        );
        const before = await balance(),
          memories = await count("memories"),
          transactions = await count("generation_transactions");
        await rejects(
          () => finish(crypto.randomUUID(), crypto.randomUUID()),
          /force_failure/,
        );
        strictEqual(await balance(), before);
        strictEqual(await count("memories"), memories);
        strictEqual(await count("generation_transactions"), transactions);
        await db.exec(
          "alter table generation_enrichment_jobs drop constraint force_failure",
        );
      },
    );
    await t.step(
      "invalid or incomplete vectors and matching errors leave a retryable job without partial writes",
      async () => {
        await finish(crypto.randomUUID(), null);
        const job = await claim(), before = await count("sentence_embeddings");
        await rejects(
          () => complete(job, rows(job).slice(1)),
          /Invalid indexing result/,
        );
        const bad = rows(job);
        bad[0].embedding = [1];
        await rejects(() => complete(job, bad), /Invalid indexing vectors/);
        const duplicates = rows(job);
        duplicates[1].sentence_id = duplicates[0].sentence_id;
        await rejects(
          () => complete(job, duplicates),
          /Invalid indexing result/,
        );
        await db.exec("update match_control set fail=true");
        await rejects(() => complete(job), /matching temporarily unavailable/);
        strictEqual(await count("sentence_embeddings"), before);
        await db.query(
          "select retry_generation_enrichment($1,$2,'provider failed')",
          [job.id, job.lease_token],
        );
        strictEqual(await claim(), undefined);
        await db.query(
          "update generation_enrichment_jobs set next_attempt_at=now()-interval '1 second' where id=$1",
          [job.id],
        );
        const retry = await claim();
        strictEqual(retry.attempts, 2);
        strictEqual(await complete(job), false);
        await db.exec("update match_control set fail=false");
        strictEqual(await complete(retry), true);
      },
    );
    await t.step(
      "expired leases can be reclaimed; stale worker cannot overwrite new worker",
      async () => {
        await finish(crypto.randomUUID(), null);
        const job = await claim();
        await db.query(
          "update generation_enrichment_jobs set lease_until=now()-interval '1 second' where id=$1",
          [job.id],
        );
        const next = await claim();
        strictEqual(next.id, job.id);
        strictEqual(next.lease_token === job.lease_token, false);
        strictEqual(await complete(job), false);
        await db.query("select retry_generation_enrichment($1,$2,'stale')", [
          job.id,
          job.lease_token,
        ]);
        strictEqual(await complete(next), true);
      },
    );
    await t.step(
      "metadata-free generation commits immediately; failed vectors retain checkpoint without another debit",
      async () => {
        const before = await balance(), memory = crypto.randomUUID();
        await finish(
          memory,
          null,
          payload().map((s) => ({
            ...s,
            expression_purpose: undefined,
          })) as any,
        );
        const job = await claim();
        strictEqual(await balance(), before - 1);
        await rejects(() => complete(job), /metadata required/);
        for (
          const invalid of [
            [],
            metadata(job).slice(1),
            metadata(job).map((m: any, i: number) =>
              i ? m : { ...m, sentence_id: crypto.randomUUID() }
            ),
            metadata(job).map((m: any, i: number) =>
              i ? m : { ...m, expression_purpose: "" }
            ),
            metadata(job).map((m: any, i: number) =>
              i ? m : { ...m, expression_purpose: "word ".repeat(31) }
            ),
            metadata(job).map((m: any, i: number) =>
              i ? m : { ...m, learning_topic_ids: ["invalid"] }
            ),
            metadata(job).map((m: any, i: number) =>
              i ? m : {
                ...m,
                learning_topic_ids: ["natural_scenery", "natural_scenery"],
              }
            ),
          ]
        ) await rejects(() => checkpoint(job, invalid));
        strictEqual(
          await checkpoint({ ...job, lease_token: crypto.randomUUID() }),
          false,
        );
        strictEqual(await checkpoint(job), true);
        strictEqual(await checkpoint(job), false);
        deepStrictEqual(
          (await db.query<any>(
            "select learning_topic_ids from memory_sentences where memory_id=$1",
            [memory],
          )).rows.map((s) => s.learning_topic_ids),
          Array.from({ length: 6 }, () => []),
        );
        const broken = rows(job);
        broken[0].purpose_embedding = [];
        await rejects(() => complete(job, broken), /Invalid indexing vectors/);
        await db.query(
          "select retry_generation_enrichment($1,$2,'vector failure')",
          [job.id, job.lease_token],
        );
        await db.query(
          "update generation_enrichment_jobs set next_attempt_at=now() where id=$1",
          [job.id],
        );
        const retry = await claim();
        deepStrictEqual(retry.metadata, metadata(job));
        await db.exec("update match_control set fail=true");
        await rejects(
          () => complete(retry),
          /matching temporarily unavailable/,
        );
        deepStrictEqual(
          (await db.query<any>(
            "select learning_topic_ids from memory_sentences where memory_id=$1",
            [memory],
          )).rows.map((s) => s.learning_topic_ids),
          Array.from({ length: 6 }, () => []),
        );
        await db.exec("update match_control set fail=false");
        strictEqual(await complete(retry), true);
        strictEqual(await balance(), before - 1);
        for (const s of job.sentences) {
          // A stale local sync cannot erase server-produced categories.
          await db.query(
            "update memory_sentences set learning_topic_ids='{}', is_favorite=true where id=$1",
            [s.id],
          );
          const saved =
            (await db.query<any>("select * from memory_sentences where id=$1", [
              s.id,
            ])).rows[0];
          deepStrictEqual(saved.learning_topic_ids, ["natural_scenery"]);
          strictEqual(saved.english, s.english);
          strictEqual(saved.is_favorite, true);
        }
      },
    );
    await t.step(
      "anonymous vectors survive login both before and after indexing",
      async () => {
        for (const loginFirst of [false, true]) {
          const guestJob = crypto.randomUUID(),
            memory = crypto.randomUUID(),
            sentences = payload(3);
          await db.query(
            "insert into guest_generation_jobs(id,user_id,status) values($1,$2,'pending')",
            [guestJob, guest],
          );
          const sql =
            "select finalize_guest_generation($1,$2,now(),'mimo',$3::jsonb,'{}')";
          await db.query(sql, [guest, guestJob, JSON.stringify(sentences)]);
          await db.query(sql, [guest, guestJob, JSON.stringify(payload(3))]);
          strictEqual(
            await claim(),
            undefined,
            "owner cannot claim anonymous pending work",
          );
          const job = await claim(guest);
          deepStrictEqual(job.sentences, sentences);
          strictEqual(await checkpoint(job), true);
          // Cleanup of the recoverable photo/job must not discard queued vectors.
          if (!loginFirst) {
            await db.query("delete from guest_generation_jobs where id=$1", [
              guestJob,
            ]);
          }
          const migrate = async () => {
            await db.query("insert into memories(id,user_id) values($1,$2)", [
              memory,
              owner,
            ]);
            for (const s of sentences) {
              await db.query(
                "insert into memory_sentences(id,memory_id,english) values($1,$2,$3)",
                [s.id, memory, s.english],
              );
            }
          };
          if (loginFirst) await migrate();
          strictEqual(await complete(job), true);
          if (loginFirst) {
            const recovered = (await db.query<any>(
              "select * from guest_generation_jobs where id=$1",
              [guestJob],
            )).rows[0];
            strictEqual(recovered.status, "completed");
            deepStrictEqual(
              recovered.sentences.map((s: any) => s.id),
              sentences.map((s) => s.id),
            );
            deepStrictEqual(
              recovered.sentences.map((s: any) => s.english),
              sentences.map((s) => s.english),
            );
            for (const s of recovered.sentences) {
              deepStrictEqual(s.learning_topic_ids, ["natural_scenery"]);
            }
          }
          if (!loginFirst) await migrate();
          for (const s of sentences) {
            const saved = (await db.query<any>(
              "select * from sentence_embeddings where sentence_id=$1",
              [s.id],
            )).rows[0];
            strictEqual(saved.user_id, owner);
            strictEqual(saved.expression_purpose, s.expression_purpose);
            strictEqual(saved.purpose_embedding.length, 1024);
            deepStrictEqual(saved.learning_topic_ids, ["natural_scenery"]);
            deepStrictEqual(
              (await db.query<any>(
                "select learning_topic_ids from memory_sentences where id=$1",
                [s.id],
              )).rows[0].learning_topic_ids,
              ["natural_scenery"],
            );
            strictEqual(
              (await db.query<any>(
                "select user_id from matched_sentences where sentence_id=$1",
                [s.id],
              )).rows[0].user_id,
              owner,
            );
          }
          strictEqual(await count("guest_sentence_embeddings"), 0);
        }
      },
    );
    await t.step(
      "legacy three-sentence requests and server-assigned IDs remain indexable",
      async () => {
        const memory = crypto.randomUUID();
        await finish(
          memory,
          null,
          payload(3).map((s) => ({
            ...s,
            id: undefined,
            expression_purpose: undefined,
          })) as any,
        );
        const job = await claim();
        strictEqual(job.sentences.length, 3);
        strictEqual(
          job.sentences.every((s: any) => typeof s.id === "string"),
          true,
        );
        strictEqual(await checkpoint(job), true);
        strictEqual(await complete(job), true);
      },
    );
    await t.step(
      "deleting a memory cancels pending work; deleted sentences are not recreated",
      async () => {
        const memory = crypto.randomUUID();
        await finish(memory, null);
        const job = await claim();
        await db.query("delete from memory_sentences where memory_id=$1", [
          memory,
        ]);
        strictEqual(await complete(job), true);
        const other = crypto.randomUUID();
        await finish(other, null);
        const cancelled = await claim();
        await db.query("delete from memories where id=$1", [other]);
        strictEqual(await complete(cancelled), false);
      },
    );
    await t.step(
      "users cannot inspect, claim or write the administrative queue",
      async () => {
        for (const role of ["anon", "authenticated"]) {
          for (
            const fn of [
              "claim_generation_enrichment(uuid)",
              "retry_generation_enrichment(uuid,uuid,text)",
              "complete_generation_enrichment(uuid,uuid,jsonb)",
              "save_generation_enrichment_metadata(uuid,uuid,jsonb)",
            ]
          ) {
            strictEqual(
              (await db.query<any>(
                "select has_function_privilege($1,$2,'EXECUTE') as allowed",
                [role, fn],
              )).rows[0].allowed,
              false,
            );
          }
          strictEqual(
            (await db.query<any>(
              "select has_table_privilege($1,'generation_enrichment_jobs','SELECT') as allowed",
              [role],
            )).rows[0].allowed,
            false,
          );
        }
      },
    );
    await t.step(
      "background concurrency is capped independently of generation requests",
      async () => {
        for (let i = 0; i < 9; i++) {
          await finish(crypto.randomUUID(), null, payload(3));
        }
        for (let i = 0; i < 8; i++) {
          strictEqual(Boolean(await claim(null)), true);
        }
        strictEqual(await claim(null), undefined);
      },
    );
  } finally {
    await db.close();
  }
});
