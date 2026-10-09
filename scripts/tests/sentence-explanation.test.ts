import { deepStrictEqual, strictEqual, throws, ok } from "node:assert"
import { createExplanationHandler, type ExplanationDependencies, type ExplanationInput } from "../../supabase/functions/explain-sentence/handler.ts"
import { type SentenceExplanation, validateExplanation, explanationPrompt } from "../../supabase/functions/explain-sentence/content.ts"
import { generateExplanation } from "../../supabase/functions/explain-sentence/model.ts"

const content: SentenceExplanation = {
  version: 1,
  points: [{ title: "a little break", explanation: "短暂休息，语气自然。" }],
  examples: [
    { english: "Let's take a little break.", chinese: "我们休息一小会儿吧。" },
    { english: "I need a little break from work.", chinese: "我需要暂时放下工作休息一下。" },
  ],
  exercise: { prompt: "选择合适的词。", sentence: "Let's ____ a little break.", options: ["take", "make", "do", "put"], answerIndex: 0, explanation: "take a break 是休息的固定搭配。" },
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

Deno.test("explanation strictly validates full content and exactly two examples", () => {
  deepStrictEqual(validateExplanation(content), content)
  for (const invalid of [null, {}, { ...content, version: 2 }, { ...content, points: [] },
    { ...content, examples: content.examples.slice(0, 1) },
    { ...content, examples: [content.examples[0], content.examples[0]] },
    { ...content, exercise: { ...content.exercise, answerIndex: 4 } },
    { ...content, exercise: { ...content.exercise, options: ["take", " Take ", "do", "put"] } },
    { ...content, exercise: { ...content.exercise, sentence: "No blank here." } },
    { ...content, exercise: { ...content.exercise, sentence: "____ and ____" } },
    { ...content, points: [{ title: "word", explanation: "x".repeat(801) }] }]) {
    throws(() => validateExplanation(invalid))
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
      generate: () => Promise.resolve(invalid ? { ...content, examples: [] } : content),
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
