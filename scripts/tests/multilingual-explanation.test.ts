import { deepStrictEqual, strictEqual, notStrictEqual, throws, ok } from "node:assert"
import { createExplanationV2Handler, type ExplanationDependencies } from "../../supabase/functions/explain-sentence-v2/handler.ts"
import { fingerprint, legacyFingerprint, validateExplanation, validateInput, explanationPrompt,
  type ExplanationInput, type ExplanationSource, type SentenceExplanation } from "../../supabase/functions/explain-sentence-v2/content.ts"
import { generateExplanation } from "../../supabase/functions/explain-sentence-v2/model.ts"
import { teachingLocales } from "../../supabase/functions/_shared/assistance-input.ts"

const sentenceID = "00000000-0000-4000-8000-000000000001"
const source: ExplanationSource = { targetText: "Bonjour tout le monde.", translationText: "Hello everyone.",
  targetLanguage: "fr", translationLanguage: "en", teachingLocale: "fr-FR", contentVersion: 1, contentSchemaVersion: 2 }
const input: ExplanationInput = { ...source, sentenceID, explanationLanguage: "en", exampleTranslationLanguage: "en", generate: true }
function content(i: ExplanationInput = input): SentenceExplanation {
  return { version: 3, targetLanguage: i.targetLanguage, explanationLanguage: i.explanationLanguage,
    exampleTranslationLanguage: i.exampleTranslationLanguage, points: [{ title: "Bonjour", explanation: "A greeting.",
      example: { targetText: "Bonjour Marie.", translationText: "Hello Marie." } }] }
}
function request(body = {}, headers = { Authorization: "Bearer fixture" }) {
  return new Request("https://fixture.test/explanation", { method: "POST", headers,
    body: JSON.stringify({ sentenceID, explanationLanguage: "en", ...body }) })
}
function setup(overrides: Partial<ExplanationDependencies> = {}) {
  const calls = { generated: [] as ExplanationInput[], claims: [] as { owner: string; key: string; generate: boolean }[], finish: 0, release: 0 }
  const deps: ExplanationDependencies = { authenticate: async () => ({ id: "owner-a", anonymous: false }),
    source: async (owner, id) => owner === "owner-a" && id === sentenceID ? source : null,
    claim: async (owner, key, generate) => { calls.claims.push({ owner, key, generate }); return generate ? { state: "claimed", claimID: "lease" } : { state: "missing" } },
    generate: async i => { calls.generated.push(i); return content(i) },
    finish: async () => { calls.finish++; return true },
    release: async () => { calls.release++ }, ...overrides }
  return { run: createExplanationV2Handler(deps), calls }
}
Deno.test("explanation v2 defaults to cache only, does not reserve lease or generate", async () => {
  const { run, calls } = setup()
  const response = await run(request())
  strictEqual(response.status, 200)
  strictEqual((await response.json()).explanation, null)
  strictEqual(calls.generated.length, 0)
  ok(calls.claims.every(c => !c.generate))
})
Deno.test("explanation v2 authoritative source defeats spoofed client text and language, checks ownership", async () => {
  const { run, calls } = setup()
  const response = await run(request({ generate: true, source: { ...source, targetLanguage: "ja", targetText: "spoof" }, targetText: "spoof" }))
  strictEqual(response.status, 200)
  strictEqual(calls.generated[0].targetText, source.targetText)
  strictEqual(calls.generated[0].targetLanguage, "fr")
  strictEqual((await response.json()).explanation.version, 3)
  strictEqual((await setup({ source: async () => null }).run(request({ generate: true }))).status, 404)
  strictEqual((await setup({ authenticate: async () => null }).run(request())).status, 401)
})
Deno.test("explanation v2 supports ten combinations and the English legacy exception, rejects others", () => {
  let combinations = 0
  for (const target of ["en", "es", "ja", "fr"] as const) for (const support of ["zh-Hans", "en", "es", "ja", "fr"] as const) {
    const i = { ...input, targetLanguage: target, translationLanguage: "zh-Hans" as const,
      teachingLocale: teachingLocales[target], explanationLanguage: support, exampleTranslationLanguage: support }
    if (target === "en" || support === "zh-Hans" || support === "en") { validateInput(i); combinations++ }
    else throws(() => validateInput(i), /unsupported_explanation_language/)
  }
  strictEqual(combinations, 11)
  throws(()=>validateInput({...input,translationLanguage:"fr"}),/invalid_source_languages/)
})
Deno.test("explanation v2 fingerprints every semantic dimension, never generate or owner data supplied by client", async () => {
  const key = await fingerprint(input)
  strictEqual(key, await fingerprint({ ...input, generate: false }))
  for (const patch of [{ targetText: "changed" }, { translationText: "changed" }, { contentVersion: 2 }, { contentSchemaVersion: 1 as const },
    { targetLanguage: "ja" as const }, { translationLanguage: "ja" as const }, { teachingLocale: "es-419" as const },
    { explanationLanguage: "zh-Hans" as const }, { exampleTranslationLanguage: "zh-Hans" as const }]) {
    notStrictEqual(await fingerprint({ ...input, ...patch }), key)
  }
})
Deno.test("explanation v2 adapts old English/Chinese semantics only, never relabels Chinese examples as English", async () => {
  const english: ExplanationSource = { ...source, targetText: "Take a break.", translationText: "休息一下。", targetLanguage: "en",
    translationLanguage: "zh-Hans", teachingLocale: "en-US" }
  const legacy = { version: 2, points: [{ title: "break", explanation: "A pause.", example: { english: "I need a break.", chinese: "我需要休息。" } }] }
  const oldKey = await legacyFingerprint({ ...input, ...english, exampleTranslationLanguage: "zh-Hans" })
  ok(oldKey)
  const { run, calls } = setup({ source: async () => english, claim: async (_owner, key) => key === oldKey
    ? { state: "ready", content: legacy } : { state: "missing" } })
  const adapted = await (await run(request({ exampleTranslationLanguage: "zh-Hans", generate: true }))).json()
  strictEqual(adapted.explanation.exampleTranslationLanguage, "zh-Hans")
  deepStrictEqual(adapted.explanation.points[0].example, { targetText: "I need a break.", translationText: "我需要休息。" })
  strictEqual(calls.generated.length, 0)
  strictEqual((await (await run(request())).json()).explanation, null)
  strictEqual(await legacyFingerprint({ ...input, ...english }), null)
})
Deno.test("explanation v2 validates cached and generated descriptors and releases failed leases", async () => {
  const invalid = content({ ...input, explanationLanguage: "ja" })
  const cached = setup({ claim: async () => ({ state: "ready", content: invalid }) })
  strictEqual((await cached.run(request())).status, 502)
  const generated = setup({ generate: async () => invalid })
  strictEqual((await generated.run(request({ generate: true }))).status, 502)
  strictEqual(generated.calls.release, 1); strictEqual(generated.calls.finish, 0)
  const expired = setup({ finish: async () => false })
  strictEqual((await expired.run(request({ generate: true }))).status, 502)
  strictEqual(expired.calls.release, 1)
  throws(() => validateExplanation({ ...content(), points: [] }, input))
  throws(() => validateExplanation({ ...content(), points: [content().points[0], content().points[0]] }, input))
})
Deno.test("explanation v2 rechecks deletion, maps busy/rate limits, and bounds untrusted guest input", async () => {
  let reads = 0
  const changed = setup({ source: async () => ++reads === 1 ? source : null })
  strictEqual((await changed.run(request({ generate: true }))).status, 409)
  strictEqual(changed.calls.release, 1); strictEqual(changed.calls.finish, 0)
  for (const [state, status] of [["busy", 409], ["limited", 429]] as const) {
    const { run } = setup({ claim: async (_o, _k, generate) => ({ state: generate ? state : "missing" }) })
    strictEqual((await run(request({ generate: true }))).status, status)
    strictEqual((await run(request())).status, 200)
  }
  const guest = setup({ authenticate: async () => ({ id: "guest", anonymous: true }), source: async () => { throw new Error("must not read") } })
  strictEqual((await guest.run(request({ source, generate: true }))).status, 200)
  strictEqual((await guest.run(request({ source: { ...source, contentSchemaVersion: 99 } }))).status, 400)
  strictEqual((await guest.run(request({ english: "Take a break.", chinese: "休息一下。", generate: true }))).status, 200)
  strictEqual((await guest.run(request({ source: { ...source, targetText: "x".repeat(1001) } }))).status, 400)
  strictEqual((await guest.run(request({ generate: "true" }))).status, 400)
})
Deno.test("explanation v2 prompts are language-specific and model fallback rejects wrong-language schema", async () => {
  const prompt = explanationPrompt({ ...input, explanationLanguage: "zh-Hans", exampleTranslationLanguage: "zh-Hans" })
  ok(prompt.includes("Simplified Chinese")); ok(prompt.includes("fr-FR")); ok(prompt.includes("sentence data"))
  let calls = 0
  const result = await generateExplanation(input, [{ name: "mimo", url: "https://fixture.test", key: "fixture" },
    { name: "deepseek", url: "https://fixture.test", key: "fixture" }], async (_url, init) => {
      calls++
      const body = JSON.parse(String((init as RequestInit)?.body))
      strictEqual(JSON.parse(body.messages[1].content).targetText, source.targetText)
      return Response.json({ choices: [{ message: { content: JSON.stringify(calls === 1 ? { ...content(), targetLanguage: "en" } : content()) } }] })
    })
  deepStrictEqual(result, content()); strictEqual(calls, 2)
})
