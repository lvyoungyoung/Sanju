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

export interface SentenceDialogue {
  index: 0 | 1 | 2
  turn: 0 | 1
}

export interface SentenceContent {
  id: string
  targetText: string
  translationText: string
  contentVersion: 1
  presentationGroup: "what_i_see" | "what_i_say"
  isFavorite: boolean
  learningMaterial?: LearningMaterial
  dialogue?: SentenceDialogue
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
  const dialogue = s.dialogue == null ? undefined : validateDialogue(s.dialogue)
  if (s.contentVersion !== 1 || !["what_i_see", "what_i_say"].includes(s.presentationGroup) ||
      typeof s.isFavorite !== "boolean") {
    throw new ContractError("invalid_content")
  }
  if (context.targetLanguage !== "en" && !s.learningMaterial) throw new ContractError("learning_material_required")
  const learningMaterial = s.learningMaterial == null ? undefined : await validateLearningMaterial(s.learningMaterial, targetText, context.targetLanguage === "ja")
  if (context.targetLanguage !== "en" && !learningMaterial?.segments.some(s => s.canBlank)) throw new ContractError("invalid_learning_material")
  return { id: uuid(s.id), targetText, translationText, contentVersion: 1,
    presentationGroup: s.presentationGroup, isFavorite: s.isFavorite, ...(learningMaterial ? { learningMaterial } : {}),
    ...(dialogue ? { dialogue } : {}) }
}

export function validateDialogue(value: unknown): SentenceDialogue {
  const d = record(value)
  if (![0, 1, 2].includes(d.index) || ![0, 1].includes(d.turn) ||
      Object.keys(d).some(key => key !== "index" && key !== "turn")) throw new ContractError("invalid_dialogue")
  return { index: d.index, turn: d.turn }
}

// Trio indices are global; historical tabs identify pairs within each group.
export function validateSentenceCollection(sentences: SentenceContent[], format?: "dual_tabs_v1" | "dialogue_tabs_v1" | "dialogue_trio_v1"): void {
  if (new Set(sentences.map(s => s.id)).size !== sentences.length) throw new ContractError("duplicate_sentence_id")
  const hasDialogue = sentences.some(s => s.dialogue != null)
  if (format === "dialogue_trio_v1" || (!format && hasDialogue && sentences.length === 6)) {
    if (sentences.length !== 6) throw new ContractError("invalid_dialogue")
    const keys = new Set<string>()
    const groups = new Map<number, string>()
    for (const s of sentences) {
      const d = validateDialogue(s.dialogue)
      if (!["what_i_see", "what_i_say"].includes(s.presentationGroup) ||
          (d.index === 0 && s.presentationGroup !== "what_i_see") ||
          (d.index === 2 && s.presentationGroup !== "what_i_say") ||
          (groups.has(d.index) && groups.get(d.index) !== s.presentationGroup)) throw new ContractError("invalid_dialogue")
      const key = `${d.index}:${d.turn}`
      if (keys.has(key)) throw new ContractError("invalid_dialogue")
      keys.add(key)
      groups.set(d.index, s.presentationGroup)
    }
  } else if (format === "dialogue_tabs_v1" || hasDialogue || sentences.length === 12) {
    if (format === "dual_tabs_v1" || sentences.length !== 12) throw new ContractError("invalid_dialogue")
    const keys = new Set<string>()
    for (const s of sentences) {
      const d = validateDialogue(s.dialogue)
      if (!["what_i_see", "what_i_say"].includes(s.presentationGroup)) throw new ContractError("invalid_dialogue")
      const key = `${s.presentationGroup}:${d.index}:${d.turn}`
      if (keys.has(key)) throw new ContractError("invalid_dialogue")
      keys.add(key)
    }
  } else if (format === "dual_tabs_v1" ? sentences.length !== 6 || sentences.filter(s => s.presentationGroup === "what_i_see").length !== 3 : ![3, 6].includes(sentences.length)) {
    throw new ContractError("invalid_content")
  }
}
