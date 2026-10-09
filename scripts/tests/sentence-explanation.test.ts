import { deepStrictEqual, strictEqual, throws, ok } from "node:assert"
import { createExplanationHandler, type ExplanationDependencies, type ExplanationInput } from "../../supabase/functions/explain-sentence/handler.ts"
import { EXPLANATION_VERSION, type SentenceExplanation, validateExplanation, explanationPrompt } from "../../supabase/functions/explain-sentence/content.ts"
import { generateExplanation } from "../../supabase/functions/explain-sentence/model.ts"

const content: SentenceExplanation = {
  version: 2,
  points: [
    { title: "a little break", explanation: "短暂休息，语气自然。", example: {
      english: "Let's take a little break.", chinese: "我们休息一小会儿吧。",
    } },
    { title: "need", explanation: "表示需要某物或做某事。", example: {
      english: "I need a warm cup of tea.", chinese: "我需要一杯热茶。",
    } },
  ],
}
const input: ExplanationInput = {
  sentenceID: "00000000-0000-4000-8000-000000000001", english: "I need a little break.", chinese: "我需要休息一下。", language: "zh", generate: true,
}
function request(data: unknown = input) {
  return new Request("https://example.invalid/explain", {
    method: "POST", headers: { Authorization: "Bearer token" }, body: JSON.stringify(data),
  })
}
function dependencies(overrides: Partial<ExplanationDependencies> = {}): ExplanationDependencies {
  return {
    authenticate: () => Promise.resolve({ id: "owner", anonymous: false }),
    source: () => Promise.resolve({ english: input.english, chinese: input.chinese }),
    claim: () => Promise.resolve({ state: "claimed", claimID: "claim" }),
    generate: () => Promise.resolve(content), finish: () => Promise.resolve(true), release: () => Promise.resolve(),
    ...overrides,
  }
}

Deno.test("each key expression requires an explanation and one translated example", () => {
  deepStrictEqual(validateExplanation(content), content)
  const point = content.points[0]
  for (const invalid of [null, {}, { ...content, version: 1 }, { ...content, points: [] },
    { ...content, points: Array(5).fill(point) },
    { ...content, points: [point, point] },
    { ...content, points: [{ ...point, title: " " }] },
    { ...content, points: [{ ...point, explanation: "x".repeat(801) }] },
    { ...content, points: [{ ...point, example: undefined }] },
    { ...content, points: [{ ...point, example: { english: "", chinese: "中文" } }] },
    { ...content, points: [{ ...point, example: { english: "An example.", chinese: " " } }] },
    { ...content, points: [{ ...point, example: { english: "x".repeat(301), chinese: "中文" } }] },
    { ...content, points: [point, { ...content.points[1], example: point.example }] }]) {
    throws(() => validateExplanation(invalid))
  }
  deepStrictEqual(validateExplanation({ ...content, examples: [], exercise: {} }), content)
})

Deno.test("prompt only requests words or phrases with their own examples", () => {
  for (const language of ["zh", "en"] as const) {
    const prompt = explanationPrompt(language)
    ok(prompt.includes("Each point's title must be the word or phrase itself"))
    ok(prompt.includes("exactly one new, natural English example"))
    ok(prompt.includes('"version":2'))
    ok(prompt.includes('"example":'))
    strictEqual(prompt.includes('"examples":'), false)
    strictEqual(prompt.includes('"exercise":'), false)
  }
})

Deno.test("cache lookup and saved explanations never invoke the model", async () => {
  for (const cached of [null, content]) {
    const handler = createExplanationHandler(dependencies({
      claim: (_owner, _hash, generate) => { strictEqual(generate, false); return Promise.resolve(cached ? { state: "ready", content: cached } : { state: "missing" }) },
      generate: () => { throw new Error("Must not generate") },
      finish: () => { throw new Error("Must not save") },
    }))
    const result = await handler(request({ ...input, generate: false }))
    strictEqual(result.status, 200)
    deepStrictEqual((await result.json()).explanation, cached)
  }
})

Deno.test("authenticated source is authoritative and missing ownership blocks generation", async () => {
  let called = false
  const handler = createExplanationHandler(dependencies({ generate: (value) => {
    strictEqual(value.english, input.english); called = true; return Promise.resolve(content)
  } }))
  strictEqual((await handler(request({ ...input, english: "tampered" }))).status, 200)
  strictEqual(called, true)
  const missing = createExplanationHandler(dependencies({ source: () => Promise.resolve(null), claim: () => { throw new Error("Must not claim") } }))
  strictEqual((await missing(request())).status, 404)
})

Deno.test("anonymous users can explain local sentences without a signed-in account", async () => {
  const handler = createExplanationHandler(dependencies({
    authenticate: () => Promise.resolve({ id: "guest", anonymous: true }),
    source: () => { throw new Error("Anonymous sentences are local") },
    claim: (owner, hash) => { strictEqual(owner, "guest"); strictEqual(hash.length, 64); return Promise.resolve({ state: "claimed", claimID: "claim" }) },
  }))
  strictEqual((await handler(request())).status, 200)
})

Deno.test("fingerprints distinguish source changes and explanation languages", async () => {
  const hashes = new Set<string>()
  const handler = createExplanationHandler(dependencies({
    authenticate: () => Promise.resolve({ id: "guest", anonymous: true }),
    claim: (_owner, hash) => { hashes.add(hash); return Promise.resolve({ state: "missing" }) },
  }))
  for (const value of [input, { ...input, language: "en" }, { ...input, english: "A new sentence." }]) {
    await handler(request({ ...value, generate: false }))
  }
  strictEqual(hashes.size, 3)
})

Deno.test("v2 cache fingerprints never reuse the previous explanation format", async () => {
  const handler = createExplanationHandler(dependencies({
    claim: async (_owner, fingerprint) => {
      const hash = async (version: number) => {
        const bytes = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(
          JSON.stringify([version, input.english, input.chinese, input.language]),
        ))
        return Array.from(new Uint8Array(bytes), (b) => b.toString(16).padStart(2, "0")).join("")
      }
      strictEqual(fingerprint, await hash(EXPLANATION_VERSION))
      strictEqual(fingerprint === await hash(1), false)
      return { state: "missing" }
    },
    generate: () => { throw new Error("Opening must not regenerate") },
  }))
  strictEqual((await handler(request({ ...input, generate: false }))).status, 200)
})

Deno.test("busy and quota responses do not invoke providers or publish results", async () => {
  for (const [state, status] of [["busy", 409], ["limited", 429]] as const) {
    const handler = createExplanationHandler(dependencies({
      claim: () => Promise.resolve({ state }), generate: () => { throw new Error("Must not generate") },
    }))
    strictEqual((await handler(request())).status, status)
  }
})

Deno.test("invalid model results and save failures release the lease and never return partial content", async () => {
  for (const invalid of [true, false]) {
    let released = false
    let saved = false
    const handler = createExplanationHandler(dependencies({
      generate: () => Promise.resolve(invalid ? { ...content, points: [] } : content),
      finish: () => { saved = true; return Promise.resolve(false) },
      release: () => { released = true; return Promise.resolve() },
    }))
    const result = await handler(request())
    strictEqual(result.status, 502)
    strictEqual(saved, !invalid)
    strictEqual(released, true)
    strictEqual((await result.json()).explanation, undefined)
  }
})

Deno.test("successful content is saved before being returned and the lease is not released", async () => {
  let finished = false
  const handler = createExplanationHandler(dependencies({
    finish: (_owner, _hash, _claim, value) => { deepStrictEqual(value, content); finished = true; return Promise.resolve(true) },
    release: () => { throw new Error("Must not release completed claim") },
  }))
  const result = await handler(request())
  strictEqual(finished, true)
  deepStrictEqual((await result.json()).explanation, content)
})

Deno.test("input, token and body bounds are validated without reaching the database", async () => {
  const handler = createExplanationHandler(dependencies({ authenticate: () => { throw new Error("Must not authenticate") } }))
  strictEqual((await handler(new Request("https://example.invalid"))).status, 405)
  strictEqual((await handler(new Request("https://example.invalid", { method: "POST" }))).status, 401)
  for (const value of [null, {}, { ...input, sentenceID: "bad" }, { ...input, generate: "true" }, { ...input, language: "fr" },
    { ...input, english: "x".repeat(1001) }, { ...input, padding: "x".repeat(9000) }]) {
    strictEqual((await handler(request(value))).status, 400)
  }
})

Deno.test("provider fallback rejects invalid JSON and uses server-side credentials", async () => {
  const calls: string[] = []
  const fetcher = (async (url: string | URL | Request, init?: RequestInit) => {
    calls.push(String(url))
    const body = JSON.parse(String(init?.body))
    strictEqual(body.messages[1].content, JSON.stringify({ english: input.english, chinese: input.chinese }))
    strictEqual(body.thinking.type, "disabled")
    if (calls.length === 1) return Response.json({ choices: [{ message: { content: "{}" } }] })
    strictEqual(new Headers(init?.headers).get("api-key"), "test-secret")
    return Response.json({ choices: [{ message: { content: "```json\n" + JSON.stringify(content) + "\n```" } }] })
  }) as typeof fetch
  deepStrictEqual(await generateExplanation(input, [
    { name: "deepseek", url: "https://first.invalid", key: "test-secret" },
    { name: "mimo", url: "https://second.invalid", key: "test-secret" },
  ], fetcher), content)
  strictEqual(calls.length, 2)
  ok(explanationPrompt("zh").includes("Simplified Chinese"))
  ok(explanationPrompt("en").includes("in English"))
})

Deno.test("database cache, leases and budgets are separate from generation and study progress", async () => {
  const sql = await Deno.readTextFile("supabase/migrations/20261009001000_add_sentence_explanations.sql")
  ok(sql.includes("for update"))
  ok(sql.includes("claim_id = p_claim_id"))
  ok(sql.includes("lease_until > now()"))
  ok(sql.includes("minute_count < 8"))
  ok(sql.includes("day_count < 50"))
  ok(sql.includes("on delete cascade"))
  ok(sql.includes("from public, anon, authenticated"))
  strictEqual(/\b(update|insert into) public\.(profiles|sentence_study_progress|generation_transactions)\b/i.test(sql), false)
  const workflow = await Deno.readTextFile(".github/workflows/backend-functions.yml")
  ok(workflow.includes("- explain-sentence"))
  ok(workflow.includes("scripts/tests/sentence-explanation.test.ts"))
})
