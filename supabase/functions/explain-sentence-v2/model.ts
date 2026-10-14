import { fetchWithTimeout } from "../_shared/fetch-with-timeout.ts"
import type { ExplanationProvider } from "../_shared/explain-sentence/model.ts"
import { explanationPrompt, validateExplanation, type ExplanationInput } from "./content.ts"

export async function generateExplanation(input: ExplanationInput, providers: ExplanationProvider[], fetcher: typeof fetch = fetch) {
  for (const provider of providers) {
    try {
      const response = await fetchWithTimeout(provider.url, {
        method: "POST", headers: { "Content-Type": "application/json", ...(provider.name === "mimo"
          ? { "api-key": provider.key } : { Authorization: `Bearer ${provider.key}` }) },
        body: JSON.stringify({
          model: { deepseek: "deepseek-flash", mimo: "mimo-v2.6-flash", kimi: "kimi-k2.5" }[provider.name],
          messages: [{ role: "system", content: explanationPrompt(input) },
            { role: "user", content: JSON.stringify({ targetText: input.targetText, translationText: input.translationText,
              translationLanguage: input.translationLanguage }) }],
          thinking: { type: "disabled" },
          ...(provider.name === "deepseek" ? { max_tokens: 2048 } : { max_completion_tokens: 2048 }),
        }),
      }, 20000, fetcher)
      if (!response.ok) { await response.body?.cancel(); throw new Error("provider_rejected") }
      const payload = await response.json()
      const raw = payload?.choices?.[0]?.message?.content
      if (typeof raw !== "string" || raw.length > 24000) throw new Error("invalid_content")
      return validateExplanation(JSON.parse(raw.trim().replace(/^```(?:json)?\s*/i, "").replace(/\s*```$/, "")), input)
    } catch { /* Provider fallback precedes persistence and never changes the requested language. */ }
  }
  throw new Error("explanation_provider_unavailable")
}
