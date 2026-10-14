import { EXPLANATION_VERSION, type SentenceExplanation, validateExplanation } from "./content.ts"

export type ExplanationInput = {
  sentenceID: string
  english: string
  chinese: string
  language: "zh" | "en"
  generate: boolean
}
export type ExplanationClaim =
  | { state: "ready"; content: unknown }
  | { state: "missing" | "busy" | "limited" }
  | { state: "claimed"; claimID: string }

export type ExplanationDependencies = {
  authenticate(token: string): Promise<{ id: string; anonymous: boolean } | null>
  source(userID: string, sentenceID: string): Promise<{ english: string; chinese: string } | null>
  claim(userID: string, fingerprint: string, generate: boolean): Promise<ExplanationClaim>
  generate(input: ExplanationInput): Promise<SentenceExplanation>
  finish(userID: string, fingerprint: string, claimID: string, content: SentenceExplanation): Promise<boolean>
  release(userID: string, fingerprint: string, claimID: string): Promise<void>
}

const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
const reply = (status: number, value: unknown) => Response.json(value, {
  status, headers: { "Cache-Control": "no-store" },
})

async function readInput(req: Request): Promise<ExplanationInput> {
  if (!req.body) throw new Error("Missing body")
  const reader = req.body.getReader()
  const chunks: Uint8Array[] = []
  let length = 0
  const timer = setTimeout(() => { void reader.cancel().catch(() => {}) }, 5000)
  try {
    while (true) {
      const { done, value } = await reader.read()
      if (done) break
      length += value.length
      if (length > 8192) throw new Error("Body too large")
      chunks.push(value)
    }
  } finally {
    clearTimeout(timer)
    await reader.cancel().catch(() => {})
    reader.releaseLock()
  }
  const bytes = new Uint8Array(length)
  let offset = 0
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length }
  const v = JSON.parse(new TextDecoder().decode(bytes))
  if (!v || typeof v.sentenceID !== "string" || !uuid.test(v.sentenceID) ||
    typeof v.english !== "string" || !v.english.trim() || v.english.length > 1000 ||
    typeof v.chinese !== "string" || v.chinese.length > 1000 ||
    !["zh", "en"].includes(v.language) || typeof v.generate !== "boolean") throw new Error("Invalid input")
  return { sentenceID: v.sentenceID, english: v.english.trim(), chinese: v.chinese.trim(), language: v.language, generate: v.generate }
}

export function createExplanationHandler(deps: ExplanationDependencies) {
  return async (req: Request): Promise<Response> => {
    if (req.method !== "POST") return reply(405, { code: "method_not_allowed" })
    const token = /^Bearer\s+(\S+)$/i.exec(req.headers.get("Authorization") ?? "")?.[1]
    if (!token) return reply(401, { code: "unauthorized" })
    let input: ExplanationInput
    try { input = await readInput(req) } catch { return reply(400, { code: "invalid_request" }) }
    let lease: { owner: string; fingerprint: string; id: string } | undefined
    try {
      const user = await deps.authenticate(token)
      if (!user) return reply(401, { code: "unauthorized" })
      if (!user.anonymous) {
        const source = await deps.source(user.id, input.sentenceID)
        if (!source) return reply(404, { code: "sentence_not_found" })
        input = { ...input, english: source.english, chinese: source.chinese }
      }
      const bytes = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(
        JSON.stringify([EXPLANATION_VERSION, input.english, input.chinese, input.language]),
      ))
      const fingerprint = Array.from(new Uint8Array(bytes), (b) => b.toString(16).padStart(2, "0")).join("")
      const claim = await deps.claim(user.id, fingerprint, input.generate)
      if (claim.state === "ready") return reply(200, { explanation: validateExplanation(claim.content) })
      if (claim.state === "missing") return reply(200, { explanation: null })
      if (claim.state === "busy") return reply(409, { code: "explanation_in_progress" })
      if (claim.state === "limited") return reply(429, { code: "explanation_rate_limited" })
      if (claim.state !== "claimed" || !input.generate) throw new Error("Invalid claim")
      lease = { owner: user.id, fingerprint, id: claim.claimID }
      const content = validateExplanation(await deps.generate(input))
      if (!await deps.finish(user.id, fingerprint, claim.claimID, content)) throw new Error("Explanation lease expired")
      lease = undefined
      return reply(200, { explanation: content })
    } catch (error) {
      console.error("[explain-sentence]", error instanceof Error ? error.message : "Request failed")
      return reply(502, { code: "explanation_failed", error: "Unable to explain sentence" })
    } finally {
      if (lease) {
        await deps.release(lease.owner, lease.fingerprint, lease.id).catch((error) => console.error("[explain-sentence] Release failed", String(error)))
      }
    }
  }
}
