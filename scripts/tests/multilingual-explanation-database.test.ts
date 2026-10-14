import { PGlite } from "npm:@electric-sql/pglite@0.5.8"
import { deepStrictEqual, strictEqual, rejects, ok } from "node:assert"

Deno.test("explanation v3 migration preserves legacy rows/finish, shares quota and fences owner/lease/source", async () => {
  const db = new PGlite()
  const owner = "00000000-0000-4000-8000-000000000001"
  const other = "00000000-0000-4000-8000-000000000002"
  const sentence = "00000000-0000-4000-8000-000000000003"
  const memory = "00000000-0000-4000-8000-000000000004"
  const key = "a".repeat(64)
  const content = { version: 3, targetLanguage: "fr", explanationLanguage: "en", exampleTranslationLanguage: "en",
    points: [{ title: "Bonjour", explanation: "A greeting.", example: { targetText: "Bonjour Marie.", translationText: "Hello Marie." } }] }
  try {
    await db.exec(`create role anon; create role authenticated; create role service_role;
      create schema auth; create table auth.users(id uuid primary key);
      insert into auth.users values ('${owner}'), ('${other}');
      create table public.memories(id uuid primary key, user_id uuid, target_language text, translation_language text,
        teaching_locale text, content_schema_version integer);
      create table public.memory_sentences(id uuid primary key, memory_id uuid, target_text text, translation_text text, content_version integer);
      insert into public.memories values('${memory}','${owner}','fr','en','fr-FR',2);
      insert into public.memory_sentences values('${sentence}','${memory}','Bonjour.','Hello.',1);`)
    for (const migration of ["20261009001000_add_sentence_explanations", "20261009002000_update_sentence_explanation_points"]) {
      await db.exec(await Deno.readTextFile(`supabase/migrations/${migration}.sql`))
    }
    await db.exec(`insert into public.sentence_explanations(user_id,fingerprint,content) values
      ('${owner}',repeat('1',64),'{"version":1,"points":[]}'),
      ('${owner}',repeat('2',64),'{"version":2,"points":[]}');`)
    await db.exec(await Deno.readTextFile("supabase/migrations/20261013004000_multilingual_explanations.sql"))
    async function scalar(sql: string, args: unknown[] = []) {
      return (await db.query<{ value: any }>(`select ${sql} as value`, args)).rows[0].value
    }
    const claim = (hash = key, generate = true, user = owner) => scalar("public.claim_sentence_explanation($1,$2,$3)", [user, hash, generate])
    const finish = (id: string, value: unknown = content, user = owner) => scalar("public.finish_sentence_explanation_v2($1,$2,$3,$4::jsonb)",
      [user, key, id, JSON.stringify(value)])
    deepStrictEqual((await claim("1".repeat(64), false)).content, { version: 1, points: [] })
    deepStrictEqual((await claim("2".repeat(64), false)).content, { version: 2, points: [] })
    strictEqual((await claim(key, false)).state, "missing")
    strictEqual(await scalar("(select count(*)::int from public.sentence_explanation_limits)"), 0)
    const first = await claim()
    ok(first.claimID)
    strictEqual((await claim()).state, "busy")
    strictEqual(await finish(first.claimID, content, other), false)
    strictEqual(await finish(crypto.randomUUID()), false)
    await rejects(() => finish(first.claimID, { version: 3, points: [] }), /Invalid explanation/)
    await rejects(() => finish(first.claimID, { ...content, explanationLanguage: "ja" }), /Invalid explanation/)
    await rejects(() => scalar("public.finish_sentence_explanation($1,$2,$3,$4::jsonb)", [owner, key, first.claimID, JSON.stringify(content)]), /Invalid explanation/)
    await db.query("update public.sentence_explanations set lease_until=now()-interval '1 second' where fingerprint=$1", [key])
    strictEqual(await finish(first.claimID), false)
    const next = await claim()
    strictEqual(await finish(first.claimID), false)
    strictEqual(await finish(next.claimID), true)
    deepStrictEqual((await claim()).content, content)
    strictEqual((await claim(key, false, other)).state, "missing")
    strictEqual(await scalar("(select minute_count from public.sentence_explanation_limits where user_id=$1)", [owner]), 2)
    for (let i = 0; i < 6; i++) strictEqual((await claim(i.toString(16).padStart(64, "0"))).state, "claimed")
    strictEqual((await claim("b".repeat(64))).state, "limited")
    const source = await scalar("public.sentence_explanation_source_v2($1,$2)", [owner, sentence])
    deepStrictEqual(source, { targetText: "Bonjour.", translationText: "Hello.", contentVersion: 1, contentSchemaVersion: 2,
      targetLanguage: "fr", translationLanguage: "en", teachingLocale: "fr-FR" })
    strictEqual(await scalar("public.sentence_explanation_source_v2($1,$2)", [other, sentence]), null)
    for (const role of ["anon", "authenticated"]) {
      await db.exec(`set role ${role}`)
      await rejects(() => scalar("public.sentence_explanation_source_v2($1,$2)", [owner, sentence]), /permission denied/)
      await rejects(() => finish(next.claimID), /permission denied/)
      await rejects(() => claim(), /permission denied/)
      await rejects(() => db.query("select * from public.sentence_explanations"), /permission denied/)
      await db.exec("reset role")
    }
    await db.exec("set role service_role")
    deepStrictEqual((await claim()).content, content)
    strictEqual((await scalar("public.sentence_explanation_source_v2($1,$2)", [owner, sentence])).targetLanguage, "fr")
    await db.exec("reset role")
    await db.query("delete from auth.users where id=$1", [owner])
    strictEqual((await claim(key, false)).state, "missing")
  } finally { await db.close() }
})
