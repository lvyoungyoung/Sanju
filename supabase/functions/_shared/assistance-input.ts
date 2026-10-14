import type { SupportLanguage } from "./languages/main.ts"
export { supportsExplanation, teachingLocales } from "./languages/main.ts"
export type { LearningLanguage, SupportLanguage, TeachingLocale } from "./languages/main.ts"
export const languageNames: Record<SupportLanguage, string> = {
  "zh-Hans": "Simplified Chinese", en: "English", es: "Spanish", ja: "Japanese", fr: "French",
}
export async function readAssistanceJSON(req: Request, maxBytes = 8192): Promise<Record<string, unknown>> {
  const reader = req.body?.getReader()
  if (!reader) throw new Error("invalid_request")
  let expired = false
  const cancel = () => { expired = true; void reader.cancel().catch(() => {}) }
  const timer = setTimeout(cancel, 5000)
  req.signal.addEventListener("abort", cancel, { once: true })
  const chunks: Uint8Array[] = []
  let size = 0
  try {
    if (req.signal.aborted) throw new Error("cancelled")
    while (true) {
      const { done, value } = await reader.read()
      if (expired) throw new Error("request_timeout")
      if (done) break
      size += value.byteLength
      if (size > maxBytes) throw new Error("request_too_large")
      chunks.push(value)
    }
    const bytes = new Uint8Array(size)
    let offset = 0
    for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length }
    const value = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes))
    if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("invalid_request")
    return value
  } finally {
    clearTimeout(timer)
    req.signal.removeEventListener("abort", cancel)
    await reader.cancel().catch(() => {})
    reader.releaseLock()
  }
}
