import type { LearningLanguage, SupportLanguage, TeachingLocale } from "../languages/main.ts"

export interface ContentContext {
  schemaVersion: 2
  targetLanguage: LearningLanguage
  translationLanguage: SupportLanguage
  teachingLocale: TeachingLocale
}

export interface LearningMaterial {
  schemaVersion: 1
  textDigest: string
  policyVersion: 1
  segments: {
    id: string
    surface: string
    reading?: string
    kind: "word" | "particle" | "phrase" | "punctuation" | "whitespace"
    canBlank: boolean
  }[]
}

export interface SentenceContent {
  id: string
  targetText: string
  translationText: string
  contentVersion: 1
  learningTopicIDs: string[]
  presentationGroup: "what_i_see" | "what_i_say"
  isFavorite: boolean
  learningMaterial?: LearningMaterial
}

export interface MemoryContent {
  schemaVersion: 2
  id: string
  createdAt: string
  imagePath: string
  tags: string[]
  context: ContentContext
  sentences: SentenceContent[]
}

export class ContractError extends Error {
  constructor(public code: string, public status = 400) { super(code) }
}

export function record(value: unknown): Record<string, any> {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new ContractError("invalid_request")
  return value as Record<string, any>
}

export function uuid(value: unknown): string {
  if (typeof value !== "string" || !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value)) {
    throw new ContractError("invalid_id")
  }
  return value.toLowerCase()
}

export async function sha256(value: string | Uint8Array): Promise<string> {
  const bytes = typeof value === "string" ? new TextEncoder().encode(value) : new Uint8Array(value)
  return Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", bytes)), b => b.toString(16).padStart(2, "0")).join("")
}

export function boundedText(value: unknown, max = 2000): string {
  if (typeof value !== "string" || !value.trim() || value.length > max || /[\u0000-\u0008\u000b\u000c\u000e-\u001f]/.test(value)) {
    throw new ContractError("invalid_content")
  }
  return value
}

export async function validateLearningMaterial(value: unknown, text: string, japanese = false): Promise<LearningMaterial> {
  const material = record(value)
  if (material.schemaVersion !== 1 || material.policyVersion !== 1 || material.textDigest !== await sha256(text) ||
      !Array.isArray(material.segments) || material.segments.length < 1 || material.segments.length > 256 ||
      new TextEncoder().encode(JSON.stringify(material)).length > 32768 ||
      Object.keys(material).some(k => !["schemaVersion", "policyVersion", "textDigest", "segments"].includes(k))) throw new ContractError("invalid_learning_material")
  const ids = new Set<string>()
  const segments = material.segments.map((value: unknown) => {
    const segment = record(value)
    const id = boundedText(segment.id, 100)
    if (ids.has(id)) throw new ContractError("invalid_learning_material")
    ids.add(id)
    if (Object.keys(segment).some(k => !["id", "surface", "reading", "kind", "canBlank"].includes(k)) ||
        !["word", "particle", "phrase", "punctuation", "whitespace"].includes(segment.kind) ||
        typeof segment.canBlank !== "boolean" || typeof segment.surface !== "string" ||
        !segment.surface.length || segment.surface.length > 2000 ||
        ((segment.kind === "punctuation" || segment.kind === "whitespace") && segment.canBlank)) {
      throw new ContractError("invalid_learning_material")
    }
    if (segment.kind === "whitespace" && !/^\s+$/u.test(segment.surface)) throw new ContractError("invalid_learning_material")
    if (segment.kind === "punctuation" && !/^[\p{P}\p{S}]+$/u.test(segment.surface)) throw new ContractError("invalid_learning_material")
    const reading = segment.reading === undefined ? undefined : boundedText(segment.reading, 500)
    if (japanese && /\p{Script=Han}/u.test(segment.surface) && (!reading || !/^[\p{Script=Hiragana}\p{Script=Katakana}ー\s]+$/u.test(reading))) {
      throw new ContractError("invalid_learning_material")
    }
    return { id, surface: segment.surface, kind: segment.kind, canBlank: segment.canBlank, ...(reading ? { reading } : {}) }
  })
  if (segments.map(s => s.surface).join("") !== text || (japanese && !segments.some(s => s.canBlank))) {
    throw new ContractError("invalid_learning_material")
  }
  return { schemaVersion: 1, policyVersion: 1, textDigest: material.textDigest, segments }
}

export async function validateSentence(value: unknown, context: ContentContext): Promise<SentenceContent> {
  const s = record(value)
  const targetText = boundedText(s.targetText)
  const translationText = boundedText(s.translationText)
  if (s.contentVersion !== 1 || !["what_i_see", "what_i_say"].includes(s.presentationGroup) ||
      typeof s.isFavorite !== "boolean" || !Array.isArray(s.learningTopicIDs) || s.learningTopicIDs.length > 2 ||
      s.learningTopicIDs.some((id: unknown) => typeof id !== "string" || !/^[a-z][a-z0-9_]{0,79}$/.test(id))) {
    throw new ContractError("invalid_content")
  }
  if (context.targetLanguage !== "en" && !s.learningMaterial) throw new ContractError("learning_material_required")
  const learningMaterial = s.learningMaterial == null ? undefined : await validateLearningMaterial(s.learningMaterial, targetText, context.targetLanguage === "ja")
  if (context.targetLanguage !== "en" && !learningMaterial?.segments.some(s => s.canBlank)) throw new ContractError("invalid_learning_material")
  return { id: uuid(s.id), targetText, translationText, contentVersion: 1, learningTopicIDs: [...new Set<string>(s.learningTopicIDs)],
    presentationGroup: s.presentationGroup, isFavorite: s.isFavorite, ...(learningMaterial ? { learningMaterial } : {}) }
}
