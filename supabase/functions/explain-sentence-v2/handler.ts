import { readAssistanceJSON } from "../_shared/assistance-input.ts"
import type { ExplanationClaim } from "../_shared/explain-sentence/handler.ts"
import { adaptLegacy, fingerprint, legacyFingerprint, supportLanguage, validateExplanation, validateInput, validateSource,
  type ExplanationInput, type ExplanationSource, type SentenceExplanation } from "./content.ts"

export interface ExplanationDependencies {
  authenticate(token: string): Promise<{ id: string; anonymous: boolean } | null>
  source(userID: string, sentenceID: string): Promise<ExplanationSource | null>
  claim(userID: string, fingerprint: string, generate: boolean): Promise<ExplanationClaim>
  generate(input: ExplanationInput): Promise<SentenceExplanation>
  finish(userID: string, fingerprint: string, claimID: string, content: SentenceExplanation): Promise<boolean>
  release(userID: string, fingerprint: string, claimID: string): Promise<void>
}
const reply = (status: number, value: unknown) => Response.json(value, { status, headers: { "Cache-Control": "no-store" } })
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

export function createExplanationV2Handler(deps: ExplanationDependencies) {
  return async (req: Request): Promise<Response> => {
    if (req.method !== "POST") return reply(405, { code: "method_not_allowed" })
    const token = /^Bearer\s+(\S+)$/i.exec(req.headers.get("Authorization") ?? "")?.[1]
    if (!token) return reply(401, { code: "unauthorized" })
    let body: Record<string, unknown>
    let request: Pick<ExplanationInput, "sentenceID" | "explanationLanguage" | "exampleTranslationLanguage" | "generate">
    try {
      body = await readAssistanceJSON(req)
      if (typeof body.sentenceID !== "string" || !uuid.test(body.sentenceID) ||
        (body.generate !== undefined && typeof body.generate !== "boolean")) throw new Error("invalid_request")
      const explanationLanguage = supportLanguage(body.explanationLanguage ?? body.supportLanguage)
      if (body.supportLanguage !== undefined && body.supportLanguage !== explanationLanguage) throw new Error("ambiguous_language")
      request = { sentenceID: body.sentenceID, explanationLanguage,
        exampleTranslationLanguage: supportLanguage(body.exampleTranslationLanguage ?? explanationLanguage), generate: body.generate === true }
    } catch { return reply(400, { code: "invalid_request" }) }
    let lease: { owner: string; fingerprint: string; id: string } | undefined
    try {
      const user = await deps.authenticate(token)
      if (!user) return reply(401, { code: "unauthorized" })
      let source: ExplanationSource | null
      if (!user.anonymous) {
        source = await deps.source(user.id, request.sentenceID)
        if (!source) return reply(404, { code: "sentence_not_found" })
        // Invalid persisted sources fail closed; never replace them with client text.
        source = validateSource(source)
      } else {
        try {
          // Explicit v1 local input remains English/Chinese only. Unknown schema never defaults to English.
          source = validateSource(body.source ?? {
            contentSchemaVersion: 1, contentVersion: 1, targetText: body.english, translationText: body.chinese,
            targetLanguage: "en", translationLanguage: "zh-Hans", teachingLocale: "en-US",
          })
        } catch { return reply(400, { code: "invalid_guest_source" }) }
      }
      let input: ExplanationInput
      try { input = validateInput({ ...source, ...request }) }
      catch { return reply(400, { code: "unsupported_explanation_language" }) }
      const key = await fingerprint(input)
      const result = (content: SentenceExplanation | null) => reply(200, { explanation: content, fingerprint: key })
      const cached = await deps.claim(user.id, key, false)
      if (cached.state === "ready") return result(validateExplanation(cached.content, input))
      const legacyKey = await legacyFingerprint(input)
      if (legacyKey) {
        const legacy = await deps.claim(user.id, legacyKey, false)
        if (legacy.state === "ready") return result(adaptLegacy(legacy.content, input))
      }
      if (!input.generate) return result(null)
      const claim = await deps.claim(user.id, key, true)
      if (claim.state === "ready") return result(validateExplanation(claim.content, input))
      if (claim.state === "busy") return reply(409, { code: "explanation_in_progress" })
      if (claim.state === "limited") return reply(429, { code: "explanation_rate_limited" })
      if (claim.state !== "claimed") throw new Error("invalid_claim")
      lease = { owner: user.id, fingerprint: key, id: claim.claimID }
      const content = validateExplanation(await deps.generate(input), input)
      if (!user.anonymous) {
        const current = await deps.source(user.id, input.sentenceID)
        if (!current || await fingerprint({ ...validateSource(current), ...request }) !== key) {
          return reply(409, { code: "sentence_changed" })
        }
      }
      if (!await deps.finish(user.id, key, claim.claimID, content)) throw new Error("lease_expired")
      lease = undefined
      return result(content)
    } catch {
      // Do not log user text, arbitrary provider errors or credentials.
      return reply(502, { code: "explanation_failed" })
    } finally {
      if (lease) await deps.release(lease.owner, lease.fingerprint, lease.id).catch(() => {})
    }
  }
}
