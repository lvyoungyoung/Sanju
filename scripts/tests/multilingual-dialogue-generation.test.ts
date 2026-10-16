import { deepStrictEqual, notStrictEqual, ok, rejects, strictEqual, throws } from "node:assert"
import type { PGlite } from "npm:@electric-sql/pglite@0.5.8"
import { setupDialogueDatabase } from "./helpers/dialogue-database.ts"
import { generationFingerprint, prepareGenerationRequest, validateGenerationSpec, type GenerationSpec } from "../../supabase/functions/_shared/generation/spec.ts"
import { buildMultilingualPrompt, generationCompletionTokenBudget, parseMultilingualContent } from "../../supabase/functions/_shared/generation/content.ts"
import { readAssistanceJSON } from "../../supabase/functions/_shared/assistance-input.ts"
import { validateSentence, validateSentenceCollection, type MemoryContent, type SentenceContent } from "../../supabase/functions/_shared/content-contracts/memory.ts"
import { requestWithFallback } from "../../supabase/functions/_shared/generate-memory-v2/providers.ts"

const owner = "10000000-0000-4000-8000-000000000001", other = "10000000-0000-4000-8000-000000000002"
const spec: GenerationSpec = { schemaVersion: 1, catalogVersion: 1, targetLanguage: "en", translationLanguage: "zh-Hans",
  teachingLocale: "en-US", level: "starter", generationFormat: "dialogue_tabs_v1" }
const legacy: GenerationSpec = { ...spec, generationFormat: "dual_tabs_v1" }
const fp = "a".repeat(64)
const root = new URL("../../supabase/migrations/", import.meta.url)
const value = async (db: PGlite, sql: string, args: unknown[] = []) => (await db.query<{value: any}>(`select ${sql} as value`, args)).rows[0].value
const claim = (db: PGlite, id: string, anonymous = false, s = spec) => value(db,
  "claim_generation_job_v3($1,$2,$3,$4,$5::jsonb,$6,'{\"version\":1}')", [owner, id, anonymous,
    anonymous ? `${owner}/guest/${id}.jpg` : null, JSON.stringify(s), fp])
const finalize = (db: PGlite, m: MemoryContent, id: string, anonymous = false) => value(db,
  "finalize_generation_job_v3($1,$2,$3,$4,$5::jsonb,'deepseek')", [owner, id, anonymous, fp, JSON.stringify(m)])
const recover = (db: PGlite, id: string, anonymous = false) => value(db,
  "recover_generation_job_v2($1,$2,$3,$4)", [owner, id, anonymous, fp])
const importMemory = (db: PGlite, m: MemoryContent, guest: string | null = owner) => value(db,
  "import_guest_memory_v1($1,$2,$3::jsonb)", [other, guest, JSON.stringify({ ...m, imagePath: "" })])
function memory(dialogue = true, id = crypto.randomUUID()): MemoryContent {
  return { schemaVersion: 2, id, imagePath: `${owner}/${id}.jpg`, createdAt: "2026-10-16T00:00:00Z",
    context: { schemaVersion: 2, targetLanguage: "en", translationLanguage: "zh-Hans", teachingLocale: "en-US" }, tags: ["pets_and_animals"],
    sentences: Array.from({ length: dialogue ? 12 : 6 }, (_, i) => ({ id: crypto.randomUUID(), contentVersion: 1,
      targetText: i % 2 ? "Its ears are small." : "This is a cat.", translationText: "A translated utterance.", isFavorite: false,
      presentationGroup: i < (dialogue ? 6 : 3) ? "what_i_see" : "what_i_say",
      ...(dialogue ? { dialogue: { index: Math.floor((i % 6) / 2) as 0 | 1 | 2, turn: i % 2 as 0 | 1 } } : {}) })) }
}
function malformed(): MemoryContent[] {
  const mutations: ((m: any) => void)[] = [
    m => m.sentences.pop(),
    m => delete m.sentences[0].dialogue,
    m => m.sentences[0].dialogue = null,
    m => m.sentences[1].dialogue.turn = 0,
    m => m.sentences[1].dialogue.index = 1,
    m => m.sentences[1].presentationGroup = "what_i_say",
    m => m.sentences[1].dialogue.index = 3,
    m => m.sentences[1].dialogue.index = "0",
    m => m.sentences[1].dialogue.turn = true,
    m => m.sentences[1].dialogue.extra = "ignored?",
    m => m.sentences[1].dialogue = [],
    m => m.sentences.forEach((s: any) => delete s.dialogue),
    m => m.sentences = m.sentences.slice(0, 6),
  ]
  return mutations.map(mutate => { const m = memory(); mutate(m); return m })
}

Deno.test("dialogue contract: strict pairs, per-turn difficulty, stable legacy fingerprint and fallback", async () => {
  deepStrictEqual(validateGenerationSpec(spec), spec)
  notStrictEqual(await generationFingerprint(spec, new Uint8Array([1])), await generationFingerprint(legacy, new Uint8Array([1])))
  const prompt = buildMultilingualPrompt(spec)
  for (const text of ["12 flat", "Each B must naturally respond", "Do not make every pair question-and-answer", "objective exchanges",
    "gentle self-deprecating humor", "each individual utterance", "photo tags", "dialogue"]) ok(prompt.includes(text), text)
  ok(!prompt.includes("The last sentence must be a question"))
  const m = memory()
  const parsed = await parseMultilingualContent(JSON.stringify(m), spec)
  strictEqual(parsed?.sentences.length, 12)
  deepStrictEqual(parsed?.sentences.map(s => s.dialogue), m.sentences.map(s => s.dialogue))
  strictEqual(new Set(parsed?.sentences.map(s => s.id)).size, 12)
  const reverse = await parseMultilingualContent(JSON.stringify({ ...m, sentences: [...m.sentences].reverse() }), spec)
  deepStrictEqual(reverse?.sentences.map(s => [s.presentationGroup, s.dialogue]), parsed?.sentences.map(s => [s.presentationGroup, s.dialogue]))
  for (const invalid of malformed()) {
    strictEqual(await parseMultilingualContent(JSON.stringify(invalid), spec), null)
    throws(() => validateSentenceCollection(invalid.sentences))
  }
  const duplicateID = memory(); duplicateID.sentences[1].id = duplicateID.sentences[0].id
  throws(() => validateSentenceCollection(duplicateID.sentences), /duplicate_sentence_id/)
  await rejects(() => validateSentence({ ...m.sentences[0], dialogue: { index: 0, turn: "0" } }, m.context))
  strictEqual(await parseMultilingualContent(JSON.stringify(m), legacy), null)
  strictEqual(await parseMultilingualContent(JSON.stringify(memory(false)), spec), null)
  strictEqual((await parseMultilingualContent(JSON.stringify(memory(false)), legacy))?.sentences.length, 6)
  const tooLong = memory(); tooLong.sentences[0].targetText = "This sentence is much too long for starter English."
  strictEqual(await parseMultilingualContent(JSON.stringify(tooLong), spec), null)
  const prompts: string[] = []
  const fallback = await requestWithFallback({ imageBase64: "AA==", promptText: prompt, generationFormat: "dual_tabs_v1",
    mimoBaseURL: "https://unused.invalid", kimiBaseURL: "https://unused.invalid", mimoApiKey: "test", kimiApiKey: "test",
    maxCompletionTokens: 8192, parseContent: raw => parseMultilingualContent(raw, spec), fetcher: async (_url, init) => {
      const body = JSON.parse(String((init as RequestInit)?.body)); prompts.push(body.messages[1].content[1].text)
      return Response.json({ choices: [{ message: { content: JSON.stringify(prompts.length === 1 ? malformed()[3] : m) } }] })
    } })
  strictEqual(fallback.ok, true)
  deepStrictEqual(prompts, [prompt, prompt])
})

Deno.test("dialogue budgets: all providers receive expanded limits and reject truncated output", async () => {
  strictEqual(generationCompletionTokenBudget(legacy), undefined)
  strictEqual(generationCompletionTokenBudget({ ...legacy, targetLanguage: "fr", teachingLocale: "fr-FR" }), 12288)
  for (const [language, locale, text] of [["en", "en-US", "This is a cat."], ["fr", "fr-FR", "Le chat est ici."],
    ["es", "es-419", "El gato está aquí."], ["ja", "ja-JP", "ねこがいます。"]] as const) {
    const course: GenerationSpec = { ...spec, targetLanguage: language, teachingLocale: locale }
    const m = memory()
    const raw = JSON.stringify({ ...m, sentences: m.sentences.map(s => ({ ...s, targetText: text,
      ...(language === "en" ? {} : { learningMaterial: { schemaVersion: 1, policyVersion: 1,
        segments: [{ id: "s1", surface: text.slice(0, -1), kind: "phrase", canBlank: true },
          { id: "s2", surface: text.slice(-1), kind: "punctuation", canBlank: false }] } }) })) })
    const budget = generationCompletionTokenBudget(course)
    strictEqual(budget, language === "en" ? 8192 : 24576)
    for (const allTruncated of [false, true]) {
      const requests: any[] = []
      const result: Awaited<ReturnType<typeof requestWithFallback<SentenceContent>>> = await requestWithFallback<SentenceContent>({ imageBase64: "AA==", promptText: buildMultilingualPrompt(course), generationFormat: "dual_tabs_v1",
        mimoBaseURL: "https://unused.invalid/mimo", kimiBaseURL: "https://unused.invalid/kimi", mimoApiKey: "test", kimiApiKey: "test",
        deepseek: { baseURL: "https://unused.invalid/deepseek", apiKey: "test" }, maxCompletionTokens: budget,
        parseContent: content => parseMultilingualContent(content, course), fetcher: async (_url, init) => {
          requests.push(JSON.parse(String((init as RequestInit)?.body)))
          // Even valid JSON with a length stop must not be accepted as complete output.
          return Response.json({ choices: [{ finish_reason: allTruncated || requests.length < 3 ? "length" : "stop", message: { content: raw } }] })
        } })
      strictEqual(result.ok, !allTruncated)
      strictEqual(requests.length, 3)
      strictEqual(requests[0].max_tokens, budget)
      strictEqual(requests[1].max_completion_tokens, budget)
      strictEqual(requests[2].max_completion_tokens, budget)
      ok(requests.every(r => r.messages[1].content[1].text === buildMultilingualPrompt(course)))
      if (result.ok) {
        strictEqual(result.sentences.length, 12)
        if (language !== "en") ok(result.sentences.every(s => s.learningMaterial?.textDigest.length === 64))
      }
    }
  }
})

Deno.test("dialogue request bounds: image limits unchanged, fingerprint binds format and original bytes", async () => {
  const bytes = new Uint8Array(10 * 1024 * 1024)
  const request = { generationSpec: spec, clientRequestID: crypto.randomUUID() }
  const prepared = await prepareGenerationRequest(request, false, bytes)
  strictEqual(prepared.spec.generationFormat, "dialogue_tabs_v1")
  strictEqual(prepared.fingerprint, await generationFingerprint(spec, bytes))
  await rejects(() => prepareGenerationRequest(request, false, new Uint8Array(bytes.length + 1)), /invalid_image/)
  await rejects(() => prepareGenerationRequest(request, false, new Uint8Array()), /invalid_image/)
  const original = new Uint8Array([1, 2, 3])
  // The old canonical payload is deliberately unchanged for pending job recovery.
  const { sha256 } = await import("../../supabase/functions/_shared/content-contracts/memory.ts")
  strictEqual(await generationFingerprint(legacy, original), await sha256(JSON.stringify({ requestSchemaVersion: 3,
    generationSpec: legacy, imageDigest: await sha256(original) })))
  const json = JSON.stringify({ memories: Array.from({ length: 25 }, () => memory()) })
  const size = new TextEncoder().encode(json).length
  const makeRequest = () => new Request("https://unused.invalid", { method: "POST", body: json })
  strictEqual((await readAssistanceJSON(makeRequest(), size)).memories instanceof Array, true)
  await rejects(() => readAssistanceJSON(makeRequest(), size - 1), /request_too_large/)
})

Deno.test("dialogue DB: migration preserves receipts/history and validates atomic generation/import/recovery", async t => {
  const db = await setupDialogueDatabase()
  try {
    await db.exec(await Deno.readTextFile(new URL("20261016000000_remove_sentence_metadata.sql", root)))
    const old = memory(false), deleted = memory(false), pendingID = crypto.randomUUID(), oldGuestID = crypto.randomUUID()
    const oldGuest = memory(false, oldGuestID); oldGuest.imagePath = `${owner}/guest/${oldGuestID}.jpg`
    await importMemory(db, old); await importMemory(db, deleted)
    const insertAt = (position: number) => db.query(`insert into memory_sentences
      (id,memory_id,sort_order,target_text,translation_text,presentation_group,is_favorite)
      values($1,$2,$3,'A cat.','A cat.','what_i_see',false)`, [crypto.randomUUID(), old.id, position])
    await rejects(() => insertAt(6), /memory_sentences_sort_order_check/)
    const oldIdentity = await value(db, "immutable_memory_identity_v1($1::jsonb)", [JSON.stringify(old)])
    const receipts = (await db.query("select * from guest_memory_import_receipts_v1 order by memory_id")).rows
    await db.query("delete from memories where id=$1", [deleted.id])
    await db.query("update memory_sentences set is_favorite=true where id=$1", [old.sentences[0].id])
    await db.query("insert into sentence_study_progress values($1,$2,7)", [other, old.sentences[0].id])
    await claim(db, pendingID, false, legacy)
    await claim(db, oldGuestID, true, legacy); await finalize(db, oldGuest, oldGuestID, true)
    const oldRecovered = await recover(db, oldGuestID, true)
    await db.exec(await Deno.readTextFile(new URL("20261016001000_dialogue_generation.sql", root)))

    await t.step("sort positions cover 0..11 and direct authenticated legacy favorites retain grants", async () => {
      for (const position of [-1, 12]) await rejects(() => insertAt(position), /memory_sentences_sort_order_check/)
      for (const signature of ["valid_sentence_dialogue_v1(jsonb)", "valid_learning_material_v1(jsonb,text)",
        "is_legacy_content_v1(text,text,text)", "set_sentence_favorite_v2(uuid,boolean)"]) {
        strictEqual(await value(db, "has_function_privilege('authenticated',$1,'EXECUTE')", [signature]), true)
      }
      strictEqual(await value(db, "has_function_privilege('authenticated','valid_sentence_collection_v1(jsonb,text)','EXECUTE')"), false)
      await db.query("select set_config('test.user_id',$1,false)", [other])
      await db.exec("set role authenticated")
      try {
        strictEqual((await db.query("update memory_sentences set is_favorite=false where id=$1 returning id", [old.sentences[0].id])).rows.length, 1)
        strictEqual((await db.query("update memory_sentences set is_favorite=true where id=$1 returning id", [old.sentences[0].id])).rows.length, 1)
      } finally { await db.exec("reset role") }
    })

    await t.step("old singles, pending jobs, completed guests and deleted import receipts remain exact", async () => {
      deepStrictEqual((await db.query("select * from guest_memory_import_receipts_v1 order by memory_id")).rows, receipts)
      deepStrictEqual(await value(db, "immutable_memory_identity_v1($1::jsonb)", [JSON.stringify(old)]), oldIdentity)
      deepStrictEqual(await value(db, "immutable_memory_identity_v1($1::jsonb)", [JSON.stringify({ ...old,
        sentences: old.sentences.map(s => ({ ...s, dialogue: null })) })]), oldIdentity)
      deepStrictEqual(await recover(db, oldGuestID, true), oldRecovered)
      strictEqual((await importMemory(db, old)).alreadyImported, true)
      strictEqual((await importMemory(db, deleted)).alreadyImported, true)
      strictEqual(await value(db, "(select count(*) from memories where id=$1)", [deleted.id]), 0)
      const restored = await value(db, "memory_content_dto_v2($1)", [old.id])
      ok(restored.sentences.every((s: any) => !("dialogue" in s)))
      strictEqual(restored.sentences[0].isFavorite, true)
      strictEqual(await value(db, "(select correct_count from sentence_study_progress where sentence_id=$1)", [old.sentences[0].id]), 7)
      await rejects(() => claim(db, pendingID), /request_context_mismatch/)
      strictEqual((await finalize(db, memory(false), pendingID)).memory.sentences.length, 6)
      const three = memory(false); three.sentences = three.sentences.slice(0, 3)
      strictEqual((await importMemory(db, three)).imported, true)
    })

    await t.step("service-only privileges and both specification formats", async () => {
      for (const s of [spec, legacy]) strictEqual(await value(db, "valid_generation_spec_v3($1::jsonb)", [JSON.stringify(s)]), true)
      strictEqual(await value(db, "valid_generation_spec_v3($1::jsonb)", [JSON.stringify({ ...spec, generationFormat: "bad" })]), false)
      for (const signature of ["finalize_generation_job_v3(uuid,uuid,boolean,text,jsonb,text)", "import_guest_memory_v1(uuid,uuid,jsonb)",
        "claim_generation_job_v3(uuid,uuid,boolean,text,jsonb,text,jsonb)"]) {
        for (const role of ["anon", "authenticated", "service_role"]) strictEqual(await value(db,
          "has_function_privilege($1,$2,'EXECUTE')", [role, signature]), role === "service_role")
      }
    })

    for (const anonymous of [false, true]) await t.step(`${anonymous ? "anonymous" : "authenticated"}: rollback, debit once, replay and recovery`, async () => {
      const id = crypto.randomUUID(), m = memory(true, anonymous ? id : crypto.randomUUID())
      if (anonymous) m.imagePath = `${owner}/guest/${id}.jpg`
      await claim(db, id, anonymous)
      if (anonymous) await rejects(() => db.query("update guest_generation_jobs set status='completed',result_content=$1::jsonb where id=$2",
        [JSON.stringify({ ...m, sentences: m.sentences.slice(1) }), id]), /request_context_mismatch/)
      const before = await value(db, "(select available_generations from profiles where id=$1)", [owner])
      const transactions = await value(db, "(select count(*) from generation_transactions)")
      for (const invalid of malformed()) {
        invalid.id = m.id; invalid.imagePath = m.imagePath
        await rejects(() => finalize(db, invalid, id, anonymous), /invalid_content/)
        await rejects(() => importMemory(db, invalid), /invalid_content/)
      }
      const duplicate = structuredClone(m); duplicate.sentences[1].id = duplicate.sentences[0].id
      await rejects(() => finalize(db, duplicate, id, anonymous), /invalid_content/)
      strictEqual(await value(db, "(select available_generations from profiles where id=$1)", [owner]), before)
      strictEqual((await recover(db, id, anonymous)).status, "pending")
      const first = await finalize(db, m, id, anonymous)
      strictEqual(first.remainingCredits, before - 1)
      deepStrictEqual(first.memory.sentences, m.sentences)
      deepStrictEqual(first.memory.tags, m.tags)
      deepStrictEqual(await finalize(db, m, id, anonymous), first)
      deepStrictEqual(await recover(db, id, anonymous), first)
      strictEqual(await value(db, "(select count(*) from generation_transactions)"), transactions + 1)
      if (anonymous) {
        strictEqual(first.memory.imagePath, "")
        strictEqual(first.guestImagePath, m.imagePath)
        await rejects(() => importMemory(db, first.memory, other), /content_conflict/)
        strictEqual((await importMemory(db, first.memory)).alreadyImported, false)
        strictEqual((await importMemory(db, first.memory)).alreadyImported, true)
        deepStrictEqual((await value(db, "memory_content_dto_v2($1)", [m.id])).sentences, m.sentences)
        const changed = structuredClone(first.memory)
        ;[changed.sentences[0].dialogue, changed.sentences[1].dialogue] = [changed.sentences[1].dialogue, changed.sentences[0].dialogue]
        await rejects(() => importMemory(db, changed), /content_conflict/)
        await rejects(() => db.query("update guest_generation_jobs set result_content='{}' where id=$1", [id]), /immutable_generation_result/)
        await db.query("update guest_generation_jobs set status='acknowledged' where id=$1", [id])
        strictEqual((await recover(db, id, true)).status, "acknowledged")
        strictEqual(await value(db, "(select available_generations from profiles where id=$1)", [other]), 10)
      }
      deepStrictEqual((await db.query<{sort_order: number}>("select sort_order from memory_sentences where memory_id=$1 order by sort_order", [m.id])).rows.map(s => s.sort_order),
        Array.from({ length: 12 }, (_, i) => i))
      const user = anonymous ? other : owner
      await db.query("select set_config('test.user_id',$1,false)", [user])
      await db.exec("set role authenticated")
      await value(db, "set_sentence_favorite_v2($1,true)", [m.sentences[0].id])
      strictEqual((await db.query("update memory_sentences set is_favorite=false where id=$1 returning id", [m.sentences[0].id])).rows.length, 1)
      strictEqual((await db.query("update memory_sentences set is_favorite=true where id=$1 returning id", [m.sentences[0].id])).rows.length, 1)
      if (!anonymous) strictEqual((await db.query("update memory_sentences set is_favorite=false where id=$1 returning id", [old.sentences[0].id])).rows.length, 0)
      const page = await value(db, "list_memories_v2('en')")
      const restored = page.memories.find((item: any) => item.id === m.id)
      strictEqual(restored.sentences[0].isFavorite, true)
      deepStrictEqual(restored.sentences[0].dialogue, m.sentences[0].dialogue)
      await db.exec("reset role")
      await db.query("insert into sentence_study_progress values($1,$2,4)", [user, m.sentences[0].id])
      strictEqual(await value(db, "(select correct_count from sentence_study_progress where sentence_id=$1)", [m.sentences[0].id]), 4)
      await rejects(() => db.query("update memory_sentences set dialogue=null where id=$1", [m.sentences[0].id]), /immutable_content/)
      await rejects(() => db.query("delete from memory_sentences where id=$1", [m.sentences[0].id]), /invalid_dialogue_collection/)
      strictEqual(await value(db, "(select count(*) from memory_sentences where memory_id=$1)", [m.id]), 12)
      // Deleting the memory as a whole still cascades; receipts prevent resurrection.
      if (anonymous) {
        await db.query("delete from memories where id=$1", [m.id])
        strictEqual((await importMemory(db, first.memory)).alreadyImported, true)
        strictEqual(await value(db, "(select count(*) from memories where id=$1)", [m.id]), 0)
      }
    })
    await t.step("non-English 12-turn material persists without legacy projections", async () => {
      const course: GenerationSpec = { ...spec, targetLanguage: "fr", teachingLocale: "fr-FR" }
      await db.exec("update language_capabilities_v1 set can_generate=true where target_language='fr'")
      const m = memory(), id = crypto.randomUUID()
      const parsed = await parseMultilingualContent(JSON.stringify({ ...m, sentences: m.sentences.map(s => ({ ...s,
        targetText: "Le chat est ici.", learningMaterial: { schemaVersion: 1, policyVersion: 1, segments: [
          { id: "s1", surface: "Le chat est ici", kind: "phrase", canBlank: true },
          { id: "s2", surface: ".", kind: "punctuation", canBlank: false }] } })) }), course)
      ok(parsed)
      m.context = { ...m.context, targetLanguage: "fr", teachingLocale: "fr-FR" }; m.sentences = parsed.sentences
      await claim(db, id, false, course)
      deepStrictEqual((await finalize(db, m, id)).memory.sentences, m.sentences)
      strictEqual(await value(db, "(select count(*) from memory_sentences where memory_id=$1 and english is null and chinese is null)", [m.id]), 12)
      await db.query("select set_config('test.user_id',$1,false)", [owner])
      await value(db, "set_sentence_favorite_v2($1,true)", [m.sentences[0].id])
      const restored = await value(db, "get_memory_v2($1)", [m.id])
      deepStrictEqual(restored.sentences[0].learningMaterial, m.sentences[0].learningMaterial)
      strictEqual(restored.sentences[0].isFavorite, true)
    })
  } finally { await db.close() }
})
