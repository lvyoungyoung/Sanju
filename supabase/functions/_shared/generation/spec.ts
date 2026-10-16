import { ContractError, record, sha256, uuid, type ContentContext } from "../content-contracts/memory.ts"
import { hasTeachingLocale, languageCatalog, supportsGeneration, type LearningLevel } from "../languages/main.ts"

export interface GenerationSpec extends Omit<ContentContext, "schemaVersion"> {
  schemaVersion: 1
  catalogVersion: 1
  level: LearningLevel
  generationFormat: "dual_tabs_v1" | "dialogue_tabs_v1"
}

export function validateGenerationSpec(value: unknown): GenerationSpec {
  const s = record(value)
  if (s.schemaVersion !== 1 || s.catalogVersion !== languageCatalog.catalogVersion || !["dual_tabs_v1", "dialogue_tabs_v1"].includes(s.generationFormat) ||
      !hasTeachingLocale(s.targetLanguage, s.teachingLocale) || !languageCatalog.levels.includes(s.level) ||
      !supportsGeneration(s.targetLanguage, s.translationLanguage)) {
    throw new ContractError("invalid_generation_spec")
  }
  return { schemaVersion: 1, catalogVersion: 1, targetLanguage: s.targetLanguage, translationLanguage: s.translationLanguage,
    teachingLocale: s.teachingLocale, level: s.level, generationFormat: s.generationFormat }
}

export function contentContext(spec: GenerationSpec): ContentContext {
  return { schemaVersion: 2, targetLanguage: spec.targetLanguage, translationLanguage: spec.translationLanguage, teachingLocale: spec.teachingLocale }
}

export async function generationFingerprint(spec: GenerationSpec, imageBytes: Uint8Array): Promise<string> {
  return sha256(JSON.stringify({ requestSchemaVersion: 3, generationSpec: validateGenerationSpec(spec), imageDigest: await sha256(imageBytes) }))
}

export async function prepareGenerationRequest(body: unknown, anonymous: boolean, imageBytes: Uint8Array) {
  const b = record(body)
  const spec = validateGenerationSpec(b.generationSpec)
  const requestID = uuid(anonymous ? b.guestJobID : b.clientRequestID)
  if (imageBytes.length < 1 || imageBytes.length > 10 * 1024 * 1024) throw new ContractError("invalid_image")
  return { spec, requestID, fingerprint: await generationFingerprint(spec, imageBytes) }
}

export type PreparedGeneration = Awaited<ReturnType<typeof prepareGenerationRequest>>
