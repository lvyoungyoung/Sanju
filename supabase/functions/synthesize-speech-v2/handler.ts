import { readAssistanceJSON } from "../_shared/assistance-input.ts"
import { providerRequest, readProviderAudio, validateSpeechInput, type SpeechProviderConfig } from "./speech.ts"

export interface SpeechDependencies {
  providers: Partial<Record<"mimo" | "openai", SpeechProviderConfig>>
  // Empty by default. Release only exact profile@revision IDs after human voice/locale QA.
  validatedProfiles?: ReadonlySet<string>
  authenticate(token: string): Promise<string | null>
  consumeBudget(userID: string): Promise<boolean>
  fetcher?: typeof fetch
  timeoutMs?: number
}
const reply = (code: string, status: number) => Response.json({ code }, { status, headers: { "Cache-Control": "no-store" } })

export function createSpeechV2Handler(deps: SpeechDependencies) {
  return async (req: Request): Promise<Response> => {
    if (req.method !== "POST") return reply("method_not_allowed", 405)
    const token = /^Bearer\s+(\S+)$/i.exec(req.headers.get("Authorization") ?? "")?.[1]
    if (!token) return reply("unauthorized", 401)
    let input: ReturnType<typeof validateSpeechInput>
    try { input = validateSpeechInput(await readAssistanceJSON(req)) }
    catch { return reply("speech_descriptor_mismatch", 400) }
    const { text, descriptor } = input
    const controller = new AbortController()
    const abort = () => controller.abort()
    req.signal.addEventListener("abort", abort, { once: true })
    if (req.signal.aborted) abort()
    const timer = setTimeout(abort, deps.timeoutMs ?? 15000)
    const cleanup = () => { clearTimeout(timer); req.signal.removeEventListener("abort", abort); controller.abort() }
    let streaming = false
    try {
      const userID = await deps.authenticate(token)
      controller.signal.throwIfAborted()
      if (!userID) return reply("unauthorized", 401)
      if (descriptor.language !== "en" && !deps.validatedProfiles?.has(`${descriptor.profileID}@${descriptor.profileRevision}`)) {
        return reply("speech_voice_not_validated", 503)
      }
      const config = deps.providers[descriptor.provider]
      if (!config?.url || !config.apiKey) return reply("speech_provider_not_configured", 503)
      if (!await deps.consumeBudget(userID)) return reply("speech_rate_limited", 429)
      controller.signal.throwIfAborted()
      const upstream = await (deps.fetcher ?? fetch)(config.url, {
        method: "POST", signal: controller.signal,
        headers: { "Content-Type": "application/json", ...(descriptor.provider === "mimo"
          ? { "api-key": config.apiKey } : { Authorization: `Bearer ${config.apiKey}` }) },
        body: JSON.stringify(providerRequest(text, descriptor)),
      })
      const contentType = upstream.headers.get("Content-Type")?.split(";")[0].trim()
      if (!upstream.ok || !upstream.body || (descriptor.provider === "openai" && !["audio/pcm", "application/octet-stream"].includes(contentType ?? ""))) {
        await upstream.body?.cancel()
        return reply("speech_provider_rejected", 502)
      }
      const audio = readProviderAudio(descriptor, upstream.body)
      const encoder = new TextEncoder()
      const encode = (v: unknown) => encoder.encode(JSON.stringify(v) + "\n")
      let cancelled = false
      let sentDescriptor = false
      const stream = new ReadableStream<Uint8Array>({
        async pull(output) {
          try {
            controller.signal.throwIfAborted()
            if (!sentDescriptor) { output.enqueue(encode({ type: "descriptor", descriptor })); sentDescriptor = true; return }
            const next = await audio.next()
            controller.signal.throwIfAborted()
            if (cancelled) return
            if (next.done) { output.enqueue(encode({ type: "done" })); output.close(); cleanup() }
            else output.enqueue(encode({ type: "audio", data: next.value }))
          } catch {
            const code = controller.signal.aborted ? "speech_provider_timeout" : "speech_provider_stream_invalid"
            cleanup()
            await audio.return(undefined).catch(() => {})
            if (!cancelled) { output.enqueue(encode({ type: "error", code })); output.close() }
          }
        },
        async cancel() { cancelled = true; cleanup(); await audio.return(undefined).catch(() => {}) },
      })
      streaming = true
      return new Response(stream, { headers: { "Content-Type": "application/x-ndjson; charset=utf-8",
        "Cache-Control": "no-store, no-transform", "X-Accel-Buffering": "no" } })
    } catch { return reply(controller.signal.aborted ? "speech_timeout" : "speech_unavailable", 503) }
    finally { if (!streaming) cleanup() }
  }
}
