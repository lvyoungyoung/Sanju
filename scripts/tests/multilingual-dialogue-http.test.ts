import { deepStrictEqual, ok, strictEqual } from "node:assert"
import { handleGenerationRequest } from "../../supabase/functions/_shared/generate-memory-v2/handler.ts"
import { GenerationTiming } from "../../supabase/functions/_shared/generation-timing.ts"
import { generationCompletionTokenBudget } from "../../supabase/functions/_shared/generation/content.ts"
import type { GenerationSpec } from "../../supabase/functions/_shared/generation/spec.ts"

Deno.test("dialogue HTTP: real V3 handler, recovery and 25-memory guest import use offline transports", async () => {
  const owner = "10000000-0000-4000-8000-000000000001"
  const spec: GenerationSpec = { schemaVersion: 1, catalogVersion: 1, targetLanguage: "en", translationLanguage: "zh-Hans",
    teachingLocale: "en-US", level: "starter", generationFormat: "dialogue_tabs_v1" }
  const originalFetch = globalThis.fetch, originalGet = Deno.env.get, originalServe = Deno.serve
  const originalInterval = globalThis.setInterval, originalTimeout = globalThis.setTimeout
  const intervals: ReturnType<typeof setInterval>[] = [], timers: ReturnType<typeof setTimeout>[] = []
  const env: Record<string, string> = { SUPABASE_URL: "https://db.invalid", SUPABASE_ANON_KEY: "anon", SUPABASE_SERVICE_ROLE_KEY: "service",
    MIMO_API_KEY: "test", MIMO_BASE_URL: "https://model.invalid/mimo", KIMI_API_KEY: "test", KIMI_BASE_URL: "https://model.invalid/kimi",
    IMAGE_MODERATION_ENABLED: "false" }
  const completed = new Map<string, any>(), calls: { name: string; body: any }[] = [], models: any[] = []
  let activeSpec = spec
  let captured: (req: Request) => Promise<Response>
  try {
    // Supabase's browser-compatible auth client creates refresh timers even for
    // local service-key doubles. Dispose those without disabling leak checks.
    globalThis.setInterval = ((...args: Parameters<typeof setInterval>) => {
      const timer = originalInterval(...args); intervals.push(timer); return timer
    }) as typeof setInterval
    globalThis.setTimeout = ((...args: Parameters<typeof setTimeout>) => {
      const timer = originalTimeout(...args); timers.push(timer); return timer
    }) as typeof setTimeout
    Deno.env.get = (name: string) => env[name]
    Deno.serve = ((callback: typeof captured) => { captured = callback }) as unknown as typeof Deno.serve
    globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = new URL(String(input)), body = typeof init?.body === "string" ? JSON.parse(init.body) : null
      if (url.pathname === "/auth/v1/user") return Response.json({ id: owner, is_anonymous: new Headers(init?.headers).get("Authorization") === "Bearer guest" })
      if (url.pathname === "/rest/v1/profiles") return Response.json({ available_generations: 10, generation_banned_until: null })
      if (url.pathname.startsWith("/storage/v1/object/")) return Response.json({ Key: "stored" })
      if (url.hostname === "model.invalid") {
        models.push(body)
        const isDialogue = activeSpec.generationFormat === "dialogue_tabs_v1"
        return Response.json({ choices: [{ finish_reason: "stop", message: { content: JSON.stringify({ tags: ["pets_and_animals"],
          sentences: Array.from({ length: isDialogue ? 12 : 6 }, (_, i) => ({ targetText: "This is a cat.", translationText: "A cat.",
            presentationGroup: i < (isDialogue ? 6 : 3) ? "what_i_see" : "what_i_say",
            ...(isDialogue ? { dialogue: { index: Math.floor(i % 6 / 2), turn: i % 2 } } : {}) })) }) } }] })
      }
      const name = url.pathname.split("/").at(-1)!
      calls.push({ name, body })
      if (name === "try_acquire_generation_slot") return Response.json(true)
      if (name === "release_generation_slot") return Response.json(null)
      if (name === "recover_generation_job_v2") return Response.json(completed.get(body.p_request_id) ?? { status: "not_found" })
      if (name === "claim_generation_job_v3") return Response.json("acquired")
      if (name === "finalize_generation_job_v3") {
        const result = { status: "completed", remainingCredits: 9, generationSpec: activeSpec, memory: body.p_memory }
        if (body.p_is_anonymous) result.memory.imagePath = ""
        completed.set(body.p_request_id, result)
        return Response.json(result)
      }
      if (name === "import_guest_memory_v1") return Response.json({ id: body.p_memory.id, imported: true })
      throw new Error(`Unexpected offline request: ${url}`)
    }) as typeof fetch
    await import("../../supabase/functions/import-guest-memories-v1/index.ts")
    const importHandler = captured!
    await import("../../supabase/functions/recover-generation-v2/index.ts")
    const recoveryHandler = captured!
    for (const anonymous of [false, true]) {
      for (const format of ["dialogue_tabs_v1", "dual_tabs_v1"] as const) {
        activeSpec = { ...spec, generationFormat: format }
        const id = crypto.randomUUID()
        const body = { imageBase64: "AA==", generationSpec: activeSpec, ...(anonymous ? { guestJobID: id } : { clientRequestID: id }) }
        const request = () => new Request("https://unused.invalid", { method: "POST", headers: { Authorization: anonymous ? "Bearer guest" : "Bearer account" }, body: JSON.stringify(body) })
        const response = await handleGenerationRequest(request(), new GenerationTiming(), 3)
        strictEqual(response.status, 200)
        const result = await response.json()
        const expected = format === "dialogue_tabs_v1" ? 12 : 6
        strictEqual(result.memory.sentences.length, expected)
        deepStrictEqual(result.generationSpec, activeSpec)
        strictEqual(models.at(-1).max_completion_tokens, generationCompletionTokenBudget(activeSpec) ?? 4096)
        const before = models.length
        deepStrictEqual(await (await handleGenerationRequest(request(), new GenerationTiming(), 3)).json(), result)
        deepStrictEqual(await (await recoveryHandler(request())).json(), result)
        strictEqual(models.length, before)
        const claim = calls.find(c => c.name === "claim_generation_job_v3" && c.body.p_request_id === id)!
        strictEqual(claim.body.p_generation_policy.promptVersion, format === "dialogue_tabs_v1" ? "dialogue-v1" : "multilingual-v1")
        strictEqual(claim.body.p_request_fingerprint.length, 64)
        if (anonymous && format === "dialogue_tabs_v1") {
          const memories = Array.from({ length: 25 }, () => ({ ...structuredClone(result.memory), id: crypto.randomUUID() }))
          const makeImport = (payload: unknown) => new Request("https://unused.invalid", { method: "POST", headers: { Authorization: "Bearer account" }, body: JSON.stringify(payload) })
          let beforeImport = calls.filter(c => c.name === "import_guest_memory_v1").length
          const imported = await importHandler(makeImport({ memories, guestAccessToken: "guest" }))
          strictEqual(imported.status, 200)
          strictEqual((await imported.json()).results.length, 25)
          const imports = calls.filter(c => c.name === "import_guest_memory_v1").slice(beforeImport)
          strictEqual(imports.length, 25)
          deepStrictEqual(imports[0].body.p_memory.sentences, result.memory.sentences)
          strictEqual(imports[0].body.p_guest_user_id, owner)
          beforeImport += 25
          const invalid = structuredClone(memories)
          invalid[24].sentences[1].dialogue.turn = 0
          strictEqual((await importHandler(makeImport({ memories: invalid }))).status, 400)
          strictEqual((await importHandler(makeImport({ memories: [...memories, memories[0]] }))).status, 400)
          strictEqual(calls.filter(c => c.name === "import_guest_memory_v1").length, beforeImport)
          // Optional envelope padding checks the import-specific limit, not the shared 6 MiB default.
          strictEqual((await importHandler(makeImport({ memories: [memories[0]], padding: "x".repeat(6 * 1024 * 1024) }))).status, 200)
          const beforeOversize = calls.filter(c => c.name === "import_guest_memory_v1").length
          strictEqual((await importHandler(makeImport({ memories: [memories[0]], padding: "x".repeat(16 * 1024 * 1024) }))).status, 400)
          strictEqual(calls.filter(c => c.name === "import_guest_memory_v1").length, beforeOversize)
        }
      }
    }
    ok(calls.filter(c => c.name === "finalize_generation_job_v3").length === 4)
  } finally {
    for (const interval of intervals) clearInterval(interval)
    for (const timer of timers) clearTimeout(timer)
    globalThis.setInterval = originalInterval; globalThis.setTimeout = originalTimeout
    globalThis.fetch = originalFetch; Deno.env.get = originalGet; Deno.serve = originalServe
  }
})
