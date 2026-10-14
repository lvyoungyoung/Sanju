import { languageCatalog } from "./catalog.ts"

export { languageCatalog }
export type LearningLanguage = typeof languageCatalog.learningLanguages[number]["id"]
export type SupportLanguage = typeof languageCatalog.supportLanguages[number]
export type TeachingLocale = typeof languageCatalog.learningLanguages[number]["teachingLocale"]
export type LearningLevel = typeof languageCatalog.levels[number]

export const teachingLocales = Object.fromEntries(languageCatalog.learningLanguages.map(l => [l.id, l.teachingLocale])) as Record<LearningLanguage, TeachingLocale>

export function supportsGeneration(target: unknown, support: unknown): boolean {
  return languageCatalog.generationPairs.some(p => p.targetLanguage === target && p.supportLanguage === support)
}

export function supportsExplanation(target: unknown, support: unknown): boolean {
  return supportsGeneration(target, support) || languageCatalog.legacyExplanationPairs.some(p => p.targetLanguage === target && p.supportLanguage === support)
}

export function hasTeachingLocale(target: unknown, locale: unknown): boolean {
  return languageCatalog.learningLanguages.some(l => l.id === target && l.teachingLocale === locale)
}
