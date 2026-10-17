import { deepStrictEqual, notStrictEqual, rejects, strictEqual, throws } from "node:assert"
import type { PGlite } from "npm:@electric-sql/pglite@0.5.8"
import { setupDialogueDatabase } from "./helpers/dialogue-database.ts"
import { validateDialogue, validateSentence, validateSentenceCollection, type GenerationFormat, type MemoryContent } from "../../supabase/functions/_shared/content-contracts/memory.ts"
import { generationFingerprint, validateGenerationSpec, type GenerationSpec } from "../../supabase/functions/_shared/generation/spec.ts"
import { claimGeneration } from "../../supabase/functions/_shared/generation/adapter.ts"

const owner = "10000000-0000-4000-8000-000000000001", other = "10000000-0000-4000-8000-000000000002"
const spec: GenerationSpec = { schemaVersion: 1, catalogVersion: 1, targetLanguage: "en", translationLanguage: "zh-Hans",
  teachingLocale: "en-US", level: "beginner", generationFormat: "scenario_dialogue_v1" }
const fp = "b".repeat(64)
const root = new URL("../../supabase/migrations/", import.meta.url)
const migration = "20261017000000_scenario_dialogue_generation.sql"
const value = async (db: PGlite, sql: string, args: unknown[] = []) => (await db.query<{ value: any }>(`select ${sql} as value`, args)).rows[0].value
const claim = (db: PGlite, id: string, anonymous = false, format: GenerationFormat = "scenario_dialogue_v1") => value(db,
  "claim_generation_job_v3($1,$2,$3,$4,$5::jsonb,$6,$7::jsonb)", [owner, id, anonymous,
    anonymous ? `${owner}/guest/${id}.jpg` : null, JSON.stringify({ ...spec, generationFormat: format }), fp,
    JSON.stringify({ version: 1, ...(format === "dialogue_trio_v1" ? { dialogueMiddleGroup: "what_i_see" } : {}) })])
const finalize = (db: PGlite, m: MemoryContent, id: string, anonymous = false) => value(db,
  "finalize_generation_job_v3($1,$2,$3,$4,$5::jsonb,'deepseek')", [owner, id, anonymous, fp, JSON.stringify(m)])
const recover = (db: PGlite, id: string, anonymous = false) => value(db,
  "recover_generation_job_v2($1,$2,$3,$4)", [owner, id, anonymous, fp])
const importMemory = (db: PGlite, m: MemoryContent, guest: string | null = owner) => value(db,
  "import_guest_memory_v1($1,$2,$3::jsonb)", [other, guest, JSON.stringify({ ...m, imagePath: "" })])
const scenarioMemory = (count = 2, id = crypto.randomUUID()): MemoryContent => ({
  schemaVersion: 2, id, imagePath: `${owner}/${id}.jpg`, createdAt: "2026-10-17T00:00:00Z",
  context: { schemaVersion: 2, targetLanguage: "en", translationLanguage: "zh-Hans", teachingLocale: "en-US" },
  tags: ["food_and_drinks"], sentences: Array.from({ length: count * 3 }, (_, i) => ({
    id: crypto.randomUUID(), contentVersion: 1, isFavorite: false, presentationGroup: "what_i_say",
    targetText: ["What would you like to drink?", "A warm cup of tea sounds lovely.", "Let's sit by the window."][i % 3],
    translationText: ["你想喝点什么？", "来杯热茶就很不错。", "我们坐窗边吧。"][i % 3],
    dialogue: { index: Math.floor(i / 3) as 0 | 1 | 2, turn: i % 3 as 0 | 1 | 2,
      title: ["喝点什么", "忙里偷闲", "拿错咖啡"][Math.floor(i / 3)] },
  })),
})
function legacyMemory(format: GenerationFormat | "single3"): MemoryContent {
  const m = scenarioMemory(format === "dialogue_tabs_v1" ? 4 : format === "single3" ? 1 : 2)
  m.sentences = m.sentences.map((s, i) => {
    const { dialogue: _, ...rest } = s
    if (format === "dual_tabs_v1" || format === "single3") return { ...rest, presentationGroup: i < 3 ? "what_i_see" : "what_i_say" }
    return { ...rest, presentationGroup: i < (format === "dialogue_tabs_v1" ? 6 : 4) ? "what_i_see" : "what_i_say",
      dialogue: { index: Math.floor((i % 6) / 2) as 0 | 1 | 2, turn: i % 2 as 0 | 1 } }
  })
  return m
}
const badTitles: unknown[] = [null, 1, {}, "", " ", " x", "x ", "\u00a0x", "x\u3000", "\ufeffx", "x\n", "x\ty", "x\u007fy", "x\u0085y", "x".repeat(25), "😀".repeat(25)]
function malformed(): MemoryContent[] {
  const mutations: ((m: any) => void)[] = [
    m => m.sentences.pop(), m => m.sentences.push(structuredClone(m.sentences[0])),
    m => delete m.sentences[0].dialogue, m => delete m.sentences[0].dialogue.title,
    m => m.sentences[0].dialogue = null, m => m.sentences[0].dialogue = [],
    m => m.sentences[1].dialogue.turn = 0, m => m.sentences[2].dialogue.turn = 3,
    m => m.sentences[2].dialogue.turn = "2", m => m.sentences[0].dialogue.index = true,
    m => m.sentences[0].dialogue.extra = true,
    m => m.sentences.slice(3).forEach((s: any) => s.dialogue.index = 2),
    m => m.sentences[0].dialogue.title = "不一致",
    m => m.sentences.slice(3).forEach((s: any) => s.dialogue.title = m.sentences[0].dialogue.title),
    m => m.sentences[0].presentationGroup = "what_i_see",
    ...badTitles.map(title => (m: any) => m.sentences[0].dialogue.title = title),
  ]
  return mutations.map(mutate => { const m = scenarioMemory(); mutate(m); return m })
}
async function setup() {
  const db = await setupDialogueDatabase()
  for (const file of ["20261016000000_remove_sentence_metadata.sql", "20261016001000_dialogue_generation.sql", "20261016002000_dialogue_trio_generation.sql"])
    await db.exec(await Deno.readTextFile(new URL(file, root)))
  return db
}

Deno.test("scenario contracts: 2/3 named A-B-A groups, strict family isolation, Unicode and stable row IDs", async () => {
  deepStrictEqual(validateGenerationSpec(spec), spec)
  for (const count of [2, 3]) {
    const m = scenarioMemory(count)
    validateSentenceCollection(m.sentences)
    validateSentenceCollection(m.sentences, "scenario_dialogue_v1")
    validateSentenceCollection([...m.sentences].reverse(), "scenario_dialogue_v1")
    deepStrictEqual(await Promise.all(m.sentences.map(s => validateSentence(s, m.context))), m.sentences)
    for (const format of ["dual_tabs_v1", "dialogue_tabs_v1", "dialogue_trio_v1"] as const)
      throws(() => validateSentenceCollection(m.sentences, format), /invalid_dialogue/)
  }
  for (const m of malformed()) {
    throws(() => validateSentenceCollection(m.sentences))
    throws(() => validateSentenceCollection(m.sentences, "scenario_dialogue_v1"))
  }
  for (const title of ["x", "x".repeat(24), "😀".repeat(24), "你好 世界"])
    deepStrictEqual(validateDialogue({ index: 0, turn: 2, title }), { index: 0, turn: 2, title })
  throws(() => validateDialogue({ index: 0, turn: 2 }))
  const duplicate = scenarioMemory(); duplicate.sentences[1].id = duplicate.sentences[0].id
  throws(() => validateSentenceCollection(duplicate.sentences), /duplicate_sentence_id/)
  for (const format of ["dual_tabs_v1", "dialogue_tabs_v1", "dialogue_trio_v1", "single3"] as const) {
    const m = legacyMemory(format)
    validateSentenceCollection(m.sentences, format === "single3" ? undefined : format)
    throws(() => validateSentenceCollection(m.sentences, "scenario_dialogue_v1"))
    if (format !== "single3") notStrictEqual(await generationFingerprint(spec, new Uint8Array([1])),
      await generationFingerprint({ ...spec, generationFormat: format }, new Uint8Array([1])))
  }
})

Deno.test("scenario adapter: claims named prompt policy without trio middle sampling", async () => {
  let policy: unknown
  const client = { rpc: (_name: string, args: any) => {
    policy = args.p_generation_policy
    return Promise.resolve({ data: "acquired", error: null })
  } }
  strictEqual(await claimGeneration(client, { spec, requestID: crypto.randomUUID(), fingerprint: fp }, owner, false, null), "acquired")
  deepStrictEqual(policy, { version: 1, promptVersion: "scenario-dialogue-v1", materialPolicyVersion: 1, providerPolicyVersion: 1 })
})

Deno.test("scenario DB: real migration, anonymous/account finalize/recovery/import, rollback and old records", async t => {
  const db = await setup()
  try {
    // Create actual old rows, receipts and pending jobs before applying migration.
    const oldRecords: { m: MemoryContent; result: any; id: string; anonymous: boolean }[] = []
    const pending: { id: string; format: GenerationFormat }[] = []
    for (const format of ["dual_tabs_v1", "dialogue_tabs_v1", "dialogue_trio_v1"] as const) {
      for (const anonymous of [false, true]) {
        const id = crypto.randomUUID(), m = legacyMemory(format)
        if (anonymous) { m.id = id; m.imagePath = `${owner}/guest/${id}.jpg` }
        await claim(db, id, anonymous, format)
        const result = await finalize(db, m, id, anonymous)
        if (anonymous) await importMemory(db, result.memory)
        oldRecords.push({ m, result, id, anonymous })
      }
      const id = crypto.randomUUID(); await claim(db, id, false, format); pending.push({ id, format })
    }
    const singles = legacyMemory("single3"); await importMemory(db, singles)
    const receipts = (await db.query("select * from guest_memory_import_receipts_v1 order by memory_id")).rows
    const functions = ["valid_sentence_dialogue_v1(jsonb)", "valid_sentence_collection_v1(jsonb,text)",
      "valid_generation_spec_v3(jsonb)", "insert_memory_content_v2(uuid,jsonb,jsonb,text)",
      "claim_generation_job_v3(uuid,uuid,boolean,text,jsonb,text,jsonb)",
      "finalize_generation_job_v3(uuid,uuid,boolean,text,jsonb,text)", "import_guest_memory_v1(uuid,uuid,jsonb)",
      "protect_memory_content_v2()", "protect_dialogue_collection_v1()"]
    const privileges = async () => await Promise.all(functions.flatMap(fn => ["anon", "authenticated", "service_role"].map(role =>
      value(db, "has_function_privilege($1,$2,'EXECUTE')", [role, fn]))))
    const acl = await privileges()
    await db.exec(await Deno.readTextFile(new URL(migration, root)))
    await db.query("update profiles set available_generations=100 where id=$1", [owner])

    await t.step("preserves grants, receipts, old identities, results and pending jobs", async () => {
      deepStrictEqual(await privileges(), acl)
      deepStrictEqual((await db.query("select * from guest_memory_import_receipts_v1 order by memory_id")).rows, receipts)
      for (const r of oldRecords) {
        deepStrictEqual(await recover(db, r.id, r.anonymous), r.result)
        if (r.anonymous) strictEqual((await importMemory(db, r.result.memory)).alreadyImported, true)
      }
      for (const p of pending) strictEqual((await finalize(db, legacyMemory(p.format), p.id)).status, "completed")
      strictEqual((await importMemory(db, singles)).alreadyImported, true)
      strictEqual(await value(db, "(select dialogue_format from memories where id=$1)", [singles.id]), null)
    })
    await t.step("SQL and TS validators agree on malformed shape and Unicode title boundaries", async () => {
      for (const m of malformed()) {
        strictEqual(await value(db, "valid_sentence_collection_v1($1::jsonb)", [JSON.stringify(m.sentences)]), false)
        strictEqual(await value(db, "valid_sentence_collection_v1($1::jsonb,'scenario_dialogue_v1')", [JSON.stringify(m.sentences)]), false)
        await rejects(() => importMemory(db, m), /invalid_content/)
      }
      for (const title of [...badTitles, "x", "😀".repeat(24), "x".repeat(24), "你好 世界"]) {
        let valid = true
        try { validateDialogue({ index: 1, turn: 2, title }) } catch { valid = false }
        strictEqual(await value(db, "valid_sentence_dialogue_v1($1::jsonb)", [JSON.stringify({ index: 1, turn: 2, title })]), valid)
      }
      for (const format of ["dual_tabs_v1", "dialogue_tabs_v1", "dialogue_trio_v1"]) {
        strictEqual(await value(db, "valid_sentence_collection_v1($1::jsonb,$2)", [JSON.stringify(scenarioMemory().sentences), format]), false)
        strictEqual(await value(db, "valid_sentence_collection_v1($1::jsonb,'scenario_dialogue_v1')", [JSON.stringify(legacyMemory(format as GenerationFormat).sentences)]), false)
      }
    })
    for (const anonymous of [false, true]) for (const count of [2, 3]) {
      await t.step(`${anonymous ? "guest" : "account"} / ${count} scenarios: atomic write, debit once, stable recovery and import`, async () => {
        const id = crypto.randomUUID(), m = scenarioMemory(count, anonymous ? id : crypto.randomUUID())
        if (anonymous) m.imagePath = `${owner}/guest/${id}.jpg`
        strictEqual(await claim(db, id, anonymous), "acquired")
        strictEqual(await claim(db, id, anonymous), "pending")
        const balance = await value(db, "(select available_generations from profiles where id=$1)", [owner])
        const tx = await value(db, "(select count(*) from generation_transactions)")
        for (const invalid of [...malformed(), legacyMemory("dialogue_trio_v1")]) {
          invalid.id = m.id; invalid.imagePath = m.imagePath
          await rejects(() => finalize(db, invalid, id, anonymous), /invalid_content/)
        }
        const duplicate = structuredClone(m); duplicate.sentences[1].id = duplicate.sentences[0].id
        await rejects(() => finalize(db, duplicate, id, anonymous), /invalid_content/)
        strictEqual(await value(db, "(select count(*) from memories where id=$1)", [m.id]), 0)
        strictEqual(await value(db, "(select available_generations from profiles where id=$1)", [owner]), balance)
        strictEqual(await value(db, "(select count(*) from generation_transactions)"), tx)
        strictEqual((await recover(db, id, anonymous)).status, "pending")
        const result = await finalize(db, m, id, anonymous)
        deepStrictEqual(result.memory.sentences, m.sentences)
        deepStrictEqual(result.memory.tags, m.tags)
        strictEqual(result.remainingCredits, balance - 1)
        deepStrictEqual(await finalize(db, m, id, anonymous), result)
        deepStrictEqual(await recover(db, id, anonymous), result)
        strictEqual(await claim(db, id, anonymous), "completed")
        strictEqual(await value(db, "(select count(*) from generation_transactions)"), tx + 1)
        await rejects(() => claim(db, id, anonymous, "dialogue_trio_v1"), /request_context_mismatch/)
        if (anonymous) {
          await rejects(() => importMemory(db, result.memory, other), /content_conflict/)
          strictEqual((await importMemory(db, result.memory)).alreadyImported, false)
          strictEqual((await importMemory(db, result.memory)).alreadyImported, true)
          const changed = structuredClone(result.memory)
          changed.sentences.slice(0, 3).forEach((s: any) => s.dialogue.title = "换个标题")
          await rejects(() => importMemory(db, changed), /content_conflict/)
          await db.query("update guest_generation_jobs set status='acknowledged' where id=$1", [id])
          strictEqual((await recover(db, id, true)).status, "acknowledged")
          await rejects(() => db.query("update guest_generation_jobs set result_content=$1::jsonb where id=$2", [JSON.stringify(changed), id]), /immutable_generation_result/)
        }
        strictEqual(await value(db, "(select dialogue_format from memories where id=$1)", [m.id]), "scenario_dialogue_v1")
        strictEqual(await value(db, "(select scenario_count from memories where id=$1)", [m.id]), count)
        const restored = await value(db, "memory_content_dto_v2($1)", [m.id])
        deepStrictEqual(restored.sentences, m.sentences)
        strictEqual(await value(db, "(select count(*) from generation_transactions)"), tx + 1)
        await rejects(() => db.query("update memories set dialogue_format='dialogue_trio_v1' where id=$1", [m.id]), /immutable_content/)
        await rejects(() => db.query("update memory_sentences set dialogue=jsonb_set(dialogue,'{title}','\"changed\"') where id=$1", [m.sentences[0].id]), /immutable_content/)
        await rejects(() => db.query("delete from memory_sentences where id=$1", [m.sentences[0].id]), /invalid_dialogue_collection/)
        await rejects(() => db.query("update memories set scenario_count=$2 where id=$1", [m.id, count === 2 ? 3 : 2]), /immutable_content/)
        if (count === 3) {
          // Removing an entire last scenario would otherwise pass 6-row validation.
          await rejects(() => db.query("delete from memory_sentences where memory_id=$1 and dialogue->'index'='2'::jsonb", [m.id]), /invalid_dialogue_collection/)
        } else {
          // Appending an entire third scenario must also fail, even with valid turns.
          const extra = scenarioMemory(3).sentences.slice(6)
          await rejects(() => db.query(`insert into memory_sentences
            (id,memory_id,sort_order,target_text,translation_text,content_version,presentation_group,is_favorite,dialogue)
            select (s->>'id')::uuid,$1,ordinality+5,s->>'targetText',s->>'translationText',1,'what_i_say',false,s->'dialogue'
            from jsonb_array_elements($2::jsonb) with ordinality as rows(s,ordinality)`, [m.id, JSON.stringify(extra)]), /invalid_dialogue_collection/)
        }
        strictEqual(await value(db, "(select count(*) from memory_sentences where memory_id=$1)", [m.id]), count * 3)
        await db.query("select set_config('test.user_id',$1,false)", [anonymous ? other : owner])
        await db.exec("set role authenticated")
        try {
          strictEqual((await db.query("update memory_sentences set is_favorite=true where id=$1 returning id", [m.sentences[0].id])).rows.length, 1)
          strictEqual((await value(db, "get_memory_v2($1)", [m.id])).sentences[0].isFavorite, true)
        } finally { await db.exec("reset role") }
        await db.query("delete from memories where id=$1", [m.id])
        if (anonymous) {
          strictEqual((await importMemory(db, result.memory)).alreadyImported, true)
          strictEqual(await value(db, "(select count(*) from memories where id=$1)", [m.id]), 0)
        }
      })
    }
    await t.step("failed jobs remain terminal and cannot debit or reclaim", async () => {
      for (const anonymous of [false, true]) {
        const id = crypto.randomUUID(), table = anonymous ? "guest_generation_jobs" : "generation_jobs", key = anonymous ? "id" : "client_request_id"
        await claim(db, id, anonymous)
        const balance = await value(db, "(select available_generations from profiles where id=$1)", [owner])
        await db.query(`update ${table} set status='failed' where ${key}=$1`, [id])
        strictEqual(await claim(db, id, anonymous), "failed")
        await rejects(() => finalize(db, scenarioMemory(), id, anonymous), /generation_failed/)
        await rejects(() => db.query(`update ${table} set status='pending' where ${key}=$1`, [id]), /terminal state is immutable/)
        strictEqual(await value(db, "(select available_generations from profiles where id=$1)", [owner]), balance)
      }
    })
  } finally { await db.close() }
})
