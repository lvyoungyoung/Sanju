import { deepStrictEqual, rejects, strictEqual } from "node:assert";
import { PGlite } from "npm:@electric-sql/pglite@0.5.8";

const root = new URL("../../supabase/migrations/", import.meta.url);
const owner = "10000000-0000-0000-0000-000000000001";
const other = "10000000-0000-0000-0000-000000000002";
const requestID = "20000000-0000-0000-0000-000000000001";
const memoryID = "30000000-0000-0000-0000-000000000001";
const sentences = Array.from({ length: 6 }, (_, i) => ({
  id: `40000000-0000-0000-0000-${String(i + 1).padStart(12, "0")}`,
  english: "This is a test.",
  chinese: "测试句子",
  learning_topic_ids: [],
  presentation_group: i < 3 ? "what_i_see" : "what_i_say",
}));

Deno.test("generation claims and finalize transactions preserve terminal results and balances", async (t) => {
  const db = new PGlite();
  try {
    await db.exec(`
      create role anon; create role authenticated; create role service_role;
      create table profiles(id uuid primary key, available_generations integer not null);
      create table memories(id uuid primary key, user_id uuid references profiles(id), image_url text, created_at timestamptz, provider text, tags text[]);
      create table memory_sentences(id uuid primary key, memory_id uuid references memories(id) on delete cascade,
        sort_order integer, english text not null, chinese text not null, learning_topic_ids text[], presentation_group text, is_favorite boolean);
      create table generation_transactions(user_id uuid, delta integer, balance_after integer, reason text, note text);
      create table generation_jobs(id uuid primary key default gen_random_uuid(), client_request_id uuid unique not null,
        user_id uuid references profiles(id), status text default 'pending', memory_id uuid references memories(id) on delete set null,
        image_path text, provider text, mimo_failure_reason text, remaining_credits integer, error_message text,
        created_at timestamptz default now(), updated_at timestamptz, completed_at timestamptz, failed_at timestamptz);
      create table guest_generation_jobs(id uuid primary key, user_id uuid references profiles(id), status text default 'pending',
        image_path text, provider text, mimo_failure_reason text, sentences jsonb, tags text[], remaining_credits integer,
        created_at timestamptz default now(), completed_at timestamptz, acknowledged_at timestamptz, error_message text);
      create function learning_topic_ids_from_json(jsonb) returns text[] language sql as $$ select '{}'::text[] $$;
      insert into profiles values ('${owner}',10), ('${other}',10);
    `);
    const finalizeSource = await Deno.readTextFile(
      new URL(
        "20260901000000_replace_scene_hint_with_learning_topics.sql",
        root,
      ),
    );
    for (
      const name of [
        "finalize_authenticated_generation",
        "finalize_guest_generation",
      ]
    ) {
      const definition = finalizeSource.match(
        new RegExp(
          `create or replace function public\\.${name}\\([\\s\\S]*?\\$\\$;`,
        ),
      );
      if (!definition) throw new Error(name);
      await db.exec(definition[0]);
    }
    const migration = await Deno.readTextFile(
      new URL("20260921005000_claim_generation_jobs_atomically.sql", root),
    );
    await db.exec(migration);
    await db.exec(migration);

    const claim = async (id = requestID, anonymous = false, user = owner) =>
      (await db.query<{ result: string }>(
        "select claim_generation_job($1,$2,$3,$4) as result",
        [user, id, anonymous, anonymous ? `${user}/guest/${id}.jpg` : null],
      )).rows[0].result;
    const finish = async (
      id: string | null,
      mem = memoryID,
      payload = sentences,
    ) =>
      db.query<any>(
        "select finalize_authenticated_generation($1,$2,$3,'image.jpg',now(),'mimo',$4::jsonb,'{}') as balance",
        [owner, mem, id, JSON.stringify(payload)],
      );

    await t.step(
      "only one insert acquires a request; repeat claims cannot take it over",
      async () => {
        // PGlite serializes statements; the endpoint suite also overlaps HTTP handlers.
        const claims = await Promise.all(
          Array.from({ length: 8 }, () => claim()),
        );
        strictEqual(claims.filter((value) => value === "acquired").length, 1);
        strictEqual(claims.filter((value) => value === "pending").length, 7);
        await rejects(
          () => claim(requestID, false, other),
          /generation job not found/,
        );
        await rejects(
          () => db.exec(`update generation_jobs set user_id='${other}'`),
          /immutable/,
        );
      },
    );

    await t.step(
      "same request commits one memory, one debit and returns its original balance",
      async () => {
        strictEqual((await finish(requestID)).rows[0].balance, 9);
        strictEqual(await claim(), "completed");
        strictEqual(
          (await finish(requestID, crypto.randomUUID())).rows[0].balance,
          9,
        );
        strictEqual(
          (await db.query<any>("select count(*)::int as n from memories"))
            .rows[0].n,
          1,
        );
        strictEqual(
          (await db.query<any>(
            "select count(*)::int as n from memory_sentences",
          )).rows[0].n,
          6,
        );
        strictEqual(
          (await db.query<any>(
            "select count(*)::int as n from generation_transactions",
          )).rows[0].n,
          1,
        );
        const before =
          (await db.query<any>("select * from generation_jobs")).rows;
        for (
          const mutation of [
            "status='pending'",
            "status='failed'",
            `memory_id='${crypto.randomUUID()}'`,
            "remaining_credits=1",
            "image_path='wrong.jpg'",
          ]
        ) {
          await rejects(
            () => db.exec(`update generation_jobs set ${mutation}`),
            /immutable/,
          );
        }
        deepStrictEqual(
          (await db.query<any>("select * from generation_jobs")).rows,
          before,
        );
        await db.exec(
          "update generation_jobs set mimo_failure_reason='diagnostic only'",
        );
      },
    );

    await t.step(
      "anonymous results can be acknowledged but cannot be charged or rewritten twice",
      async () => {
        const id = crypto.randomUUID();
        strictEqual(await claim(id, true), "acquired");
        strictEqual(await claim(id, true), "pending");
        const sql =
          "select finalize_guest_generation($1,$2,now(),'mimo',$3::jsonb,'{}') as balance";
        const args = [owner, id, JSON.stringify(sentences)];
        strictEqual((await db.query<any>(sql, args)).rows[0].balance, 8);
        await db.query<any>(
          "update guest_generation_jobs set status='acknowledged', acknowledged_at=now() where id=$1",
          [id],
        );
        strictEqual(await claim(id, true), "acknowledged");
        strictEqual((await db.query<any>(sql, args)).rows[0].balance, 8);
        await rejects(
          () => db.exec("update guest_generation_jobs set status='failed'"),
          /immutable/,
        );
        await rejects(
          () => db.exec("update guest_generation_jobs set sentences='[]'"),
          /immutable/,
        );
        await rejects(() => claim(id, true, other), /generation job not found/);
      },
    );

    await t.step(
      "failed sentence insertion rolls back memory, debit and completion together",
      async () => {
        const id = crypto.randomUUID();
        strictEqual(await claim(id), "acquired");
        await rejects(() =>
          finish(
            id,
            crypto.randomUUID(),
            sentences.map((s) => ({
              ...s,
              id: crypto.randomUUID(),
              english: null as any,
            })),
          )
        );
        strictEqual(await claim(id), "pending");
        strictEqual(
          (await db.query<any>(
            "select available_generations from profiles where id=$1",
            [owner],
          )).rows[0].available_generations,
          8,
        );
        await db.query<any>(
          "update generation_jobs set status='failed' where client_request_id=$1 and status='pending'",
          [id],
        );
        strictEqual(await claim(id), "failed");
      },
    );

    await t.step(
      "legacy calls without request IDs keep working and memory deletion can clear the FK",
      async () => {
        const payload = sentences.slice(0, 3).map((s) => ({
          ...s,
          id: crypto.randomUUID(),
        }));
        strictEqual(
          (await finish(null, crypto.randomUUID(), payload)).rows[0].balance,
          7,
        );
        await db.query<any>("delete from memories where id=$1", [memoryID]);
        const job = (await db.query<any>(
          "select status,memory_id from generation_jobs where client_request_id=$1",
          [requestID],
        )).rows[0];
        deepStrictEqual(job, { status: "completed", memory_id: null });
        for (const role of ["anon", "authenticated"]) {
          strictEqual(
            (await db.query<any>(
              "select has_function_privilege($1,'claim_generation_job(uuid,uuid,boolean,text)','EXECUTE') as allowed",
              [role],
            )).rows[0].allowed,
            false,
          );
        }
        strictEqual(
          (await db.query<any>(
            "select has_function_privilege('service_role','claim_generation_job(uuid,uuid,boolean,text)','EXECUTE') as allowed",
          )).rows[0].allowed,
          true,
        );
      },
    );
  } finally {
    await db.close();
  }
});
