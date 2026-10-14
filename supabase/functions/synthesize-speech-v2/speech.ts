import { teachingLocales, type LearningLanguage, type TeachingLocale } from "../_shared/assistance-input.ts"
import { MAX_AUDIO_BYTES, readMiMoAudio, speechRequest, SPEECH_VOICES, type SpeechVoice } from "../synthesize-speech/speech.ts"

export interface SpeechDescriptor {
  profileID: string
  profileRevision: number
  language: LearningLanguage
  teachingLocale: TeachingLocale
  locale: string
  provider: "mimo" | "openai"
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

// Primary capability evidence (2026-10-13), not a claim of product/voice validation:
// https://mimo.mi.com/docs/en-US/quick-start/usage-guide/audio/speech-synthesis-v2.5
// https://developers.openai.com/api/docs/guides/text-to-speech
// MiMo's preset table lists Chinese/English. Only English profiles are routed there.
// OpenAI lists es/ja/fr and raw 24kHz PCM16LE. Accent/quality still require human acceptance.
export function candidateDescriptor(language: "es" | "ja" | "fr"): SpeechDescriptor {
  return { profileID: `${language}-coral-candidate`, profileRevision: 1, language,
    teachingLocale: teachingLocales[language], locale: { es: "es-MX", ja: "ja-JP", fr: "fr-FR" }[language],
    provider: "openai", model: "gpt-4o-mini-tts", voice: "coral", audioFormat: "pcm16le",
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
  const accent = { es: "Latin American Spanish with a Mexican accent", ja: "standard Japanese", fr: "French as spoken in France", en: "American English" }[descriptor.language]
  return { model: descriptor.model, voice: descriptor.voice, input: text, response_format: "pcm", stream_format: "audio",
    instructions: `Read the text exactly once in ${accent}. Do not add, repeat, translate, or change any words. Use a natural teaching pace.` }
}

async function* readPCM(body: ReadableStream<Uint8Array>): AsyncGenerator<string> {
  const reader = body.getReader()
  let size = 0
  try {
    while (true) {
      const { done, value } = await reader.read()
      if (done) break
      size += value.byteLength
      if (size > MAX_AUDIO_BYTES) throw new Error("audio_too_large")
      for (let offset = 0; offset < value.length; offset += 24000) {
        yield btoa(String.fromCharCode(...value.subarray(offset, offset + 24000)))
      }
    }
    if (!size || size % 2) throw new Error("incomplete_audio")
  } finally { await reader.cancel().catch(() => {}); reader.releaseLock() }
}

export function readProviderAudio(descriptor: SpeechDescriptor, body: ReadableStream<Uint8Array>) {
  return descriptor.provider === "mimo" ? readMiMoAudio(body) : readPCM(body)
}
