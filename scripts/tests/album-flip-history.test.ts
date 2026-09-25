import { deepStrictEqual, rejects, strictEqual } from "node:assert";
import { PGlite } from "npm:@electric-sql/pglite@0.5.8";

const migration = await Deno.readTextFile(new URL(
  "../../supabase/migrations/20260925000000_add_album_flip_progress.sql", import.meta.url,
));
const alice = "00000000-0000-0000-0000-000000000001";
const bob = "00000000-0000-0000-0000-000000000002";
const memory = "10000000-0000-0000-0000-000000000001";
const sentence = "20000000-0000-0000-0000-000000000001";
const otherSentence = "20000000-0000-0000-0000-000000000002";
let sequence = 0;
const event = (feedback: string, at: string, time_zone = "Asia/Shanghai") => ({
  id: `30000000-0000-0000-0000-${String(++sequence).padStart(12, "0")}`,
  memory_id: memory, sentence_id: sentence, feedback, occurred_at: at, time_zone,
});
type Progress = { familiarity_level: number; last_feedback: string; sentence_id: string };

async function setup() {
  const db = new PGlite();
  await db.exec(`
    create role anon; create role authenticated;
    create schema auth;
    create function auth.uid() returns uuid language sql as $$
      select nullif(current_setting('test.user_id', true), '')::uuid $$;
    create function auth.jwt() returns jsonb language sql as $$
      select jsonb_build_object('is_anonymous', coalesce(nullif(current_setting('test.anonymous', true), ''), 'false')::boolean) $$;
    create table auth.users(id uuid primary key);
    create table memories(id uuid primary key, user_id uuid references auth.users(id) on delete cascade);
    create table memory_sentences(id uuid primary key, memory_id uuid references memories(id) on delete cascade);
    create table sentence_study_progress(sentence_id uuid primary key, correct_count integer);
    insert into auth.users values ('${alice}'), ('${bob}');
    insert into memories values ('${memory}','${alice}'), ('10000000-0000-0000-0000-000000000002','${bob}');
    insert into memory_sentences values ('${sentence}','${memory}'), ('${otherSentence}','10000000-0000-0000-0000-000000000002');
    insert into sentence_study_progress values ('${sentence}',7);
    grant usage on schema public, auth to authenticated;
  `);
  await db.exec(migration);
  await db.exec(`set role authenticated; set test.user_id='${alice}';`);
  return db;
}
async function sync(db: PGlite, events: unknown) {
  return (await db.query<Progress>("select * from sync_album_flip_feedback($1::jsonb)", [JSON.stringify(events)])).rows;
}

Deno.test("album feedback is independent, idempotent, ordered and advances only across local days", async () => {
  const db = await setup();
  try {
    const first = event("familiar", "2020-01-01T10:00:00Z");
    strictEqual((await sync(db, [first]))[0].familiarity_level, 1);
    strictEqual((await sync(db, [first]))[0].familiarity_level, 1);
    strictEqual((await sync(db, [event("familiar", "2020-01-01T12:00:00Z")]))[0].familiarity_level, 1);
    // Shanghai midnight, still the same UTC day.
    strictEqual((await sync(db, [event("familiar", "2020-01-01T16:01:00Z")]))[0].familiarity_level, 2);
    const third = event("familiar", "2020-01-03T10:00:00Z");
    const fourth = event("familiar", "2020-01-04T10:00:00Z");
    strictEqual((await sync(db, [fourth, third]))[0].familiarity_level, 4);
    strictEqual((await sync(db, [first]))[0].familiarity_level, 4);
    strictEqual((await sync(db, [event("familiar", "2020-01-05T10:00:00Z")]))[0].familiarity_level, 4);
    const again = event("again", "2020-01-05T10:01:00Z");
    strictEqual((await sync(db, [again]))[0].familiarity_level, 0);
    strictEqual((await sync(db, [first]))[0].last_feedback, "again");
    strictEqual((await sync(db, [event("familiar", "2020-01-05T10:02:00Z")]))[0].familiarity_level, 1);
    strictEqual((await sync(db, [event("familiar", "2020-01-05T10:03:00Z")]))[0].familiarity_level, 1);
    await db.exec("reset role");
    strictEqual((await db.query<{ correct_count: number }>("select correct_count from sentence_study_progress")).rows[0].correct_count, 7);
  } finally { await db.close(); }
});

Deno.test("album history has owner RLS, no direct writes, anonymous denial and cascading cleanup", async () => {
  const db = await setup();
  try {
    const first = event("again", "2020-01-01T00:00:00Z");
    await sync(db, [first]);
    strictEqual((await db.query("select * from album_flip_progress")).rows.length, 1);
    await rejects(() => db.exec("update album_flip_progress set familiarity_level=4"));
    await rejects(() => db.exec("delete from album_flip_progress"));
    deepStrictEqual(await sync(db, [{ ...first, sentence_id: otherSentence }]), []);
    await db.exec(`set test.user_id='${bob}'`);
    deepStrictEqual((await db.query("select * from album_flip_progress")).rows, []);
    deepStrictEqual(await sync(db, [first]), []);
    await db.exec(`set test.user_id='${alice}'; set test.anonymous='true'`);
    deepStrictEqual((await db.query("select * from album_flip_progress")).rows, []);
    await rejects(() => sync(db, [first]), /Sign in required/);
    await db.exec("set test.anonymous='false'; set test.user_id=''");
    await rejects(() => sync(db, [first]), /Sign in required/);
    await db.exec("reset role");
    await db.exec(`delete from memory_sentences where id='${sentence}'`);
    strictEqual((await db.query("select * from album_flip_progress")).rows.length, 0);
  } finally { await db.close(); }
});

Deno.test("album feedback validates whole batches atomically and safely acknowledges deleted sentences", async () => {
  const db = await setup();
  try {
    const first = event("familiar", "2020-01-01T00:00:00Z");
    await rejects(() => sync(db, []));
    await rejects(() => sync(db, {}));
    await rejects(() => sync(db, Array(101).fill(first)));
    await rejects(() => sync(db, [first, event("bad", "2020-01-02T00:00:00Z")]));
    strictEqual((await db.query("select * from album_flip_progress")).rows.length, 0);
    await rejects(() => sync(db, [{ ...first, time_zone: "not-a-zone" }]));
    await rejects(() => sync(db, [{ ...first, occurred_at: "2999-01-01T00:00:00Z" }]));
    deepStrictEqual(await sync(db, [{ ...first, sentence_id: "20000000-0000-0000-0000-000000000099" }]), []);
    await sync(db, [first]);
    await db.exec("reset role");
    await db.exec(`delete from auth.users where id='${alice}'`);
    strictEqual((await db.query("select * from album_flip_progress")).rows.length, 0);
  } finally { await db.close(); }
});
