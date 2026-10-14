import { deepStrictEqual, strictEqual, throws, ok, rejects } from "node:assert"
import { readQwenAudio } from "../../supabase/functions/synthesize-speech-v2/qwen.ts"
import { createSpeechV2Handler, type SpeechDependencies } from "../../supabase/functions/synthesize-speech-v2/handler.ts"
import { candidateDescriptor, englishDescriptor, profiles, providerRequest, validateSpeechInput } from "../../supabase/functions/synthesize-speech-v2/speech.ts"

const qwenFrame = (data = "AAABAA==", finish_reason: string | null = null) =>
  `data: ${JSON.stringify({ output: { audio: { data }, finish_reason } })}\n\n`
const qwenResponse = () => new Response(qwenFrame() + qwenFrame("", "stop"), { headers: { "Content-Type": "text/event-stream" } })
function request(descriptor = englishDescriptor(), extra = {}) {
  return new Request("https://local.test/speech", { method: "POST", headers: { Authorization: "Bearer fixture" },
    body: JSON.stringify({ text: "Bonjour.", language: descriptor.language, teachingLocale: descriptor.teachingLocale, descriptor, ...extra }) })
}
function setup(overrides: Partial<SpeechDependencies> = {}) {
  const calls = { budget: 0, provider: 0, body: {} as any, headers: new Headers() }
  const deps: SpeechDependencies = {
    providers: { mimo: { url: "https://fixture.test/mimo", apiKey: "fixture" }, qwen: { url: "https://fixture.test/tts", apiKey: "fixture" } },
    authenticate: async () => "owner-a",
    consumeBudget: async () => { calls.budget++; return true },
    fetcher: async (_url, init) => {
      calls.provider++; calls.body = JSON.parse(String((init as RequestInit)?.body))
      calls.headers = new Headers((init as RequestInit)?.headers)
      return calls.body.model === "mimo-v2.5-tts"
        ? new Response('data: {"choices":[{"delta":{"audio":{"data":"AAABAA=="}}}]}\n\ndata: [DONE]\n\n')
        : qwenResponse()
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
Deno.test("speech v2 Qwen adapter retains exact text and selects each language and voice", async () => {
  for (const language of ["es", "ja", "fr"] as const) {
    const descriptor = candidateDescriptor(language)
    const { run, calls } = setup({ validatedProfiles: new Set([`${descriptor.profileID}@1`]) })
    const response = await run(request(descriptor, { text: "  exact text  " }))
    const events = (await response.text()).trim().split("\n").map(s => JSON.parse(s))
    deepStrictEqual(events[0].descriptor, descriptor)
    deepStrictEqual(events.map(e => e.type), ["descriptor", "audio", "done"])
    strictEqual(calls.body.input.text, "  exact text  ")
    strictEqual(calls.body.model, "qwen3-tts-flash")
    strictEqual(calls.body.input.voice, { es: "Sonrisa", ja: "Ono Anna", fr: "Emilien" }[language])
    strictEqual(calls.body.input.language_type, { es: "Spanish", ja: "Japanese", fr: "French" }[language])
    strictEqual(calls.headers.get("X-DashScope-SSE"), "enable")
    strictEqual(calls.headers.get("Authorization"), "Bearer fixture")
    strictEqual(events[1].data, "AAABAA==")
  }
})
Deno.test("speech v2 truncated and odd streams fail without a done event or a second provider", async () => {
  for (const descriptor of [englishDescriptor(), candidateDescriptor("fr")]) {
    let calls = 0
    const { run } = setup({ validatedProfiles: new Set([`${descriptor.profileID}@1`]), fetcher: async () => {
      calls++
      return descriptor.provider === "mimo"
        ? new Response('data: {"choices":[{"delta":{"audio":{"data":"AAAA"}}}]}\n\n')
        : new Response(qwenFrame("AA==", "stop"), { headers: { "Content-Type": "text/event-stream" } })
    } })
    const response = await run(request(descriptor))
    const events = (await response.text()).trim().split("\n").map(s => JSON.parse(s))
    strictEqual(events.at(-1).type, "error")
    ok(!events.some(e => e.type === "done")); strictEqual(calls, 1)
  }
})

async function collectQwen(raw: string, chunkSize = 7) {
  const data = new TextEncoder().encode(raw)
  let offset = 0
  const stream = new ReadableStream<Uint8Array>({ pull(controller) {
    if (offset >= data.length) { controller.close(); return }
    controller.enqueue(data.slice(offset, offset + chunkSize)); offset += chunkSize
  } })
  const audio = []
  for await (const chunk of readQwenAudio(stream)) audio.push(chunk)
  return audio
}

Deno.test("Qwen parser handles fragmented SSE, CRLF, comments and final-frame audio", async () => {
  deepStrictEqual(await collectQwen((": heartbeat\n\nevent: result\nid: 1\n" + qwenFrame() + qwenFrame("AAABAA==", "stop")).replaceAll("\n", "\r\n")), ["AAABAA==", "AAABAA=="])
  deepStrictEqual(await collectQwen(qwenFrame() + 'data: {"output":{"finish_reason":"stop","audio":{"data":"","url":"https://never-fetch.test/file.wav"}}}\n\n'), ["AAABAA=="])
})

Deno.test("Qwen parser rejects incomplete, empty, malformed, errored and oversized audio", async () => {
  for (const raw of [qwenFrame(), qwenFrame("", "stop"), qwenFrame("AA==", "stop"),
    qwenFrame("???", "stop"), qwenFrame("AAABAA==", "length"), 'data: not-json\n\n',
    'data: {"code":"InvalidApiKey","message":"rejected"}\n\n',
    qwenFrame() + 'data: {"status_code":429,"output":{"finish_reason":"stop"}}\n\n']) {
    await rejects(() => collectQwen(raw))
  }
  await rejects(() => collectQwen("data: " + "x".repeat(512_001), 64_000), /frame_too_large/)
  const largeFrame = qwenFrame(btoa("\0".repeat(300_000)))
  await rejects(() => collectQwen(largeFrame.repeat(10) + qwenFrame("", "stop"), 64_000), /audio_too_large/)
})

Deno.test("Qwen reader cancels upstream when playback is cancelled", async () => {
  let cancelled = false
  const stream = new ReadableStream<Uint8Array>({
    start(c) { c.enqueue(new TextEncoder().encode(qwenFrame())) },
    cancel() { cancelled = true },
  })
  const audio = readQwenAudio(stream)
  strictEqual((await audio.next()).value, "AAABAA==")
  await audio.return(undefined)
  strictEqual(cancelled, true)
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
