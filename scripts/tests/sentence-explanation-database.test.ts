import { PGlite } from "npm:@electric-sql/pglite@0.5.8"
import { deepStrictEqual, strictEqual, rejects, ok } from "node:assert"

Deno.test("sentence explanation migration: cache, lease fencing, quotas, permissions and deletion", async () => {
  const db = new PGlite()
  try {
    await db.exec(`
      create role anon; create role authenticated; create role service_role;
      create schema auth;
      create table auth.users(id uuid primary key);
      insert into auth.users values
        ('00000000-0000-4000-8000-000000000001'),
        ('00000000-0000-4000-8000-000000000002');
    `)
    await db.exec(await Deno.readTextFile("supabase/migrations/20261009001000_add_sentence_explanations.sql"))
    const owner = "00000000-0000-4000-8000-000000000001"
    const other = "00000000-0000-4000-8000-000000000002"
    const hash = "a".repeat(64)
    async function claim(user = owner, fingerprint = hash, generate = true) {
      const result = await db.query<{ value: { state: string; claimID?: string; content?: unknown } }>(
        "select public.claim_sentence_explanation($1, $2, $3) as value", [user, fingerprint, generate],
      )
      return result.rows[0].value
    }
    async function finish(id: string, content: unknown = { version: 1, points: [] }) {
      const result = await db.query<{ value: boolean }>(
        "select public.finish_sentence_explanation($1, $2, $3, $4::jsonb) as value", [owner, hash, id, JSON.stringify(content)],
      )
      return result.rows[0].value
    }
    async function count(table: string) {
      return (await db.query<{ count: number }>(`select count(*)::integer as count from public.${table}`)).rows[0].count
    }

    deepStrictEqual(await claim(owner, hash, false), { state: "missing" })
    strictEqual(await count("sentence_explanations"), 0)
    strictEqual(await count("sentence_explanation_limits"), 0)

    const first = await claim()
    strictEqual(first.state, "claimed")
    ok(first.claimID)
    strictEqual((await claim()).state, "busy")
    strictEqual(await finish(crypto.randomUUID()), false)
    await db.query("update public.sentence_explanations set lease_until = now() - interval '1 second' where user_id = $1", [owner])
    strictEqual(await finish(first.claimID!), false)
    const replacement = await claim()
    strictEqual(replacement.state, "claimed")
    strictEqual(await finish(first.claimID!), false)
    const complete = { version: 1, points: [{ title: "break", explanation: "休息" }] }
    strictEqual(await finish(replacement.claimID!, complete), true)
    deepStrictEqual(await claim(), { state: "ready", content: complete })
    deepStrictEqual(await claim(owner, hash, false), { state: "ready", content: complete })
    strictEqual((await db.query<{ minute_count: number }>("select minute_count from public.sentence_explanation_limits where user_id = $1", [owner])).rows[0].minute_count, 2)
    strictEqual((await claim(other, hash, false)).state, "missing")

    for (let index = 0; index < 8; index++) {
      strictEqual((await claim(other, index.toString(16).padStart(64, "0"))).state, "claimed")
    }
    const rowCount = await count("sentence_explanations")
    strictEqual((await claim(other, "b".repeat(64))).state, "limited")
    strictEqual(await count("sentence_explanations"), rowCount, "Quota rejections must not accumulate empty cache rows")
    await db.query("update public.sentence_explanation_limits set minute_started_at = now() - interval '2 minutes' where user_id = $1", [other])
    strictEqual((await claim(other, "b".repeat(64))).state, "claimed")
    await db.query("update public.sentence_explanation_limits set day_count = 50, minute_started_at = now() - interval '2 minutes' where user_id = $1", [other])
    strictEqual((await claim(other, "c".repeat(64))).state, "limited")
    await db.query("update public.sentence_explanation_limits set request_day = current_date - 1, minute_started_at = now() - interval '2 minutes' where user_id = $1", [other])
    strictEqual((await claim(other, "c".repeat(64))).state, "claimed")

    for (const role of ["anon", "authenticated"]) {
      await db.exec(`set role ${role}`)
      await rejects(() => db.query("select * from public.sentence_explanations"), /permission denied/)
      await rejects(() => claim(), /permission denied/)
      await db.exec("reset role")
    }
    await db.exec("set role service_role")
    strictEqual((await claim()).state, "ready")
    await db.exec("reset role")

    await db.query("delete from auth.users where id = $1", [owner])
    strictEqual((await claim(owner, hash, false)).state, "missing")
    strictEqual((await db.query<{ count: number }>("select count(*)::integer as count from public.sentence_explanation_limits where user_id = $1", [owner])).rows[0].count, 0)
  } finally {
    await db.close()
  }
})
