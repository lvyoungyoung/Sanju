import { deepStrictEqual, strictEqual, throws, ok } from "node:assert"
import { createSpeechV2Handler, type SpeechDependencies } from "../../supabase/functions/synthesize-speech-v2/handler.ts"
import { candidateDescriptor, englishDescriptor, profiles, providerRequest, validateSpeechInput } from "../../supabase/functions/synthesize-speech-v2/speech.ts"

const pcm = new Uint8Array([0, 0, 1, 0])
function request(descriptor = englishDescriptor(), extra = {}) {
  return new Request("https://local.test/speech", { method: "POST", headers: { Authorization: "Bearer fixture" },
    body: JSON.stringify({ text: "Bonjour.", language: descriptor.language, teachingLocale: descriptor.teachingLocale, descriptor, ...extra }) })
}
function setup(overrides: Partial<SpeechDependencies> = {}) {
  const calls = { budget: 0, provider: 0, body: {} as any }
  const deps: SpeechDependencies = {
    providers: { mimo: { url: "https://fixture.test/mimo", apiKey: "fixture" }, openai: { url: "https://fixture.test/tts", apiKey: "fixture" } },
    authenticate: async () => "owner-a",
    consumeBudget: async () => { calls.budget++; return true },
    fetcher: async (_url, init) => {
      calls.provider++; calls.body = JSON.parse(String((init as RequestInit)?.body))
      return calls.body.model === "mimo-v2.5-tts"
        ? new Response('data: {"choices":[{"delta":{"audio":{"data":"AAABAA=="}}}]}\n\ndata: [DONE]\n\n')
        : new Response(pcm, { headers: { "Content-Type": "application/octet-stream" } })
    }, ...overrides,
  }
  return { calls, run: createSpeechV2Handler(deps) }
}
Deno.test("speech v2 catalog restricts MiMo to English and candidate languages remain gated without budget use", async () => {
  strictEqual(profiles.filter(p => p.provider === "mimo").length, 4)
  ok(profiles.filter(p => p.provider === "mimo").every(p => p.language === "en"))
  const { run, calls } = setup()
  for (const language of ["es", "ja", "fr"] as const) {
    const response = await run(request(candidateDescriptor(language)))
    strictEqual(response.status, 503)
    strictEqual((await response.json()).code, "speech_voice_not_validated")
  }
  strictEqual(calls.budget, 0); strictEqual(calls.provider, 0)
})
Deno.test("speech v2 rejects all effective descriptor mismatches before budget or provider calls", async () => {
  const { run, calls } = setup()
  const descriptor = englishDescriptor()
  for (const key of Object.keys(descriptor)) {
    const value = (descriptor as any)[key]
    const changed = { ...descriptor, [key]: typeof value === "number" ? value + 1 : `${value}-wrong` }
    strictEqual((await run(request(descriptor, { descriptor: changed }))).status, 400, key)
  }
  strictEqual((await run(request(descriptor, { language: "ja" }))).status, 400)
  strictEqual((await run(request(descriptor, { teachingLocale: "es-419" }))).status, 400)
  strictEqual(calls.budget, 0); strictEqual(calls.provider, 0)
})
Deno.test("speech v2 sends descriptor before any audio and completes English using the unchanged v1 provider request", async () => {
  const { run, calls } = setup()
  const descriptor = englishDescriptor("Dean")
  const response = await run(request(descriptor))
  strictEqual(response.status, 200)
  const events = (await response.text()).trim().split("\n").map(s => JSON.parse(s))
  deepStrictEqual(events[0], { type: "descriptor", descriptor })
  deepStrictEqual(events.map(e => e.type), ["descriptor", "audio", "done"])
  strictEqual(calls.body.audio.voice, "Dean")
  strictEqual(calls.body.messages[1].content, "Bonjour.")
  strictEqual(calls.budget, 1)
})
Deno.test("speech v2 needs both exact revision release gate and provider configuration", async () => {
  const descriptor = candidateDescriptor("ja")
  const wrong = setup({ validatedProfiles: new Set([`${descriptor.profileID}@2`]) })
  strictEqual((await wrong.run(request(descriptor))).status, 503)
  const missing = setup({ validatedProfiles: new Set([`${descriptor.profileID}@1`]), providers: {} })
  const response = await missing.run(request(descriptor))
  strictEqual((await response.json()).code, "speech_provider_not_configured")
  strictEqual(missing.calls.budget, 0)
})
Deno.test("speech v2 configured candidate adapter retains text, accent instructions and real PCM format", async () => {
  for (const language of ["es", "ja", "fr"] as const) {
    const descriptor = candidateDescriptor(language)
    const { run, calls } = setup({ validatedProfiles: new Set([`${descriptor.profileID}@1`]) })
    const response = await run(request(descriptor, { text: "  exact text  " }))
    const events = (await response.text()).trim().split("\n").map(s => JSON.parse(s))
    deepStrictEqual(events[0].descriptor, descriptor)
    deepStrictEqual(events.map(e => e.type), ["descriptor", "audio", "done"])
    strictEqual(calls.body.input, "  exact text  ")
    strictEqual(calls.body.response_format, "pcm")
    strictEqual(calls.body.stream_format, "audio")
    ok(calls.body.instructions.includes({ es: "Mexican", ja: "Japanese", fr: "France" }[language]))
  }
})
Deno.test("speech v2 truncated and odd streams fail without a done event or a second provider", async () => {
  for (const descriptor of [englishDescriptor(), candidateDescriptor("fr")]) {
    let calls = 0
    const { run } = setup({ validatedProfiles: new Set([`${descriptor.profileID}@1`]), fetcher: async () => {
      calls++
      return descriptor.provider === "mimo"
        ? new Response('data: {"choices":[{"delta":{"audio":{"data":"AAAA"}}}]}\n\n')
        : new Response(new Uint8Array([0]), { headers: { "Content-Type": "audio/pcm" } })
    } })
    const response = await run(request(descriptor))
    const events = (await response.text()).trim().split("\n").map(s => JSON.parse(s))
    strictEqual(events.at(-1).type, "error")
    ok(!events.some(e => e.type === "done")); strictEqual(calls, 1)
  }
})
Deno.test("speech v2 rejects unauthorized, limited and mislabelled audio responses", async () => {
  strictEqual((await setup({ authenticate: async () => null }).run(request())).status, 401)
  strictEqual((await setup({ consumeBudget: async () => false }).run(request())).status, 429)
  const descriptor = candidateDescriptor("es")
  const { run } = setup({ validatedProfiles: new Set([`${descriptor.profileID}@1`]),
    fetcher: async () => new Response("RIFFnotPCM", { headers: { "Content-Type": "audio/wav" } }) })
  strictEqual((await run(request(descriptor))).status, 502)
  throws(() => validateSpeechInput({ text: "", descriptor }), /invalid_text/)
  strictEqual(providerRequest("text", descriptor).model, descriptor.model)
})
