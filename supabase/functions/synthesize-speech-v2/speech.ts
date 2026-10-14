import { teachingLocales, type LearningLanguage, type TeachingLocale } from "../_shared/assistance-input.ts"
import { readMiMoAudio, speechRequest, SPEECH_VOICES, type SpeechVoice } from "../_shared/synthesize-speech/speech.ts"
import { readQwenAudio } from "./qwen.ts"

export interface SpeechDescriptor {
  profileID: string
  profileRevision: number
  language: LearningLanguage
  teachingLocale: TeachingLocale
  locale: string
  provider: "mimo" | "qwen"
  model: string
  voice: string
  audioFormat: "pcm16le"
  sampleRate: 24000
  channels: 1
  promptVersion: number
}
export function englishDescriptor(voice: SpeechVoice = "Mia"): SpeechDescriptor {
  return { profileID: `en-${voice.toLowerCase()}`, profileRevision: 1, language: "en", teachingLocale: "en-US",
    locale: "en-US", provider: "mimo", model: "mimo-v2.5-tts", voice, audioFormat: "pcm16le",
    sampleRate: 24000, channels: 1, promptVersion: 2 }
}

// https://help.aliyun.com/zh/model-studio/qwen-tts-voice-list
// Locale/accent quality still requires listening acceptance before production release.
export function candidateDescriptor(language: "es" | "ja" | "fr"): SpeechDescriptor {
  const voice = { es: "Sonrisa", ja: "Ono Anna", fr: "Emilien" }[language]
  return { profileID: `${language}-qwen-${voice.toLowerCase().replaceAll(" ", "-")}`, profileRevision: 1, language,
    teachingLocale: teachingLocales[language], locale: { es: "es-419", ja: "ja-JP", fr: "fr-FR" }[language],
    provider: "qwen", model: "qwen3-tts-flash", voice, audioFormat: "pcm16le",
    sampleRate: 24000, channels: 1, promptVersion: 1 }
}
export const profiles = [...SPEECH_VOICES.map(englishDescriptor), ...(["es", "ja", "fr"] as const).map(candidateDescriptor)]

export function validateSpeechInput(value: Record<string, unknown>) {
  if (typeof value.text !== "string" || !value.text.trim() || value.text.length > 500) throw new Error("invalid_text")
  const descriptor = value.descriptor as SpeechDescriptor | undefined
  const profile = profiles.find(p => p.profileID === descriptor?.profileID)
  if (!profile || Object.keys(profile).some(k => profile[k as keyof SpeechDescriptor] !== descriptor?.[k as keyof SpeechDescriptor]) ||
    value.language !== profile.language || value.teachingLocale !== profile.teachingLocale) throw new Error("speech_descriptor_mismatch")
  return { text: value.text, descriptor: profile }
}

export interface SpeechProviderConfig { url: string; apiKey: string }
export function providerRequest(text: string, descriptor: SpeechDescriptor) {
  if (descriptor.provider === "mimo") return speechRequest(text, descriptor.voice as SpeechVoice)
  return { model: descriptor.model, input: { text, voice: descriptor.voice,
    language_type: { es: "Spanish", ja: "Japanese", fr: "French", en: "English" }[descriptor.language] } }
}

export function readProviderAudio(descriptor: SpeechDescriptor, body: ReadableStream<Uint8Array>) {
  return descriptor.provider === "mimo" ? readMiMoAudio(body) : readQwenAudio(body)
}
