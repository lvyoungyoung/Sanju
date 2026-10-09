import { fetchWithTimeout } from "../_shared/fetch-with-timeout.ts"
import { explanationPrompt, validateExplanation } from "./content.ts"
import type { ExplanationInput } from "./handler.ts"

export type ExplanationProvider = { name: "deepseek" | "mimo" | "kimi"; url: string; key: string }

export async function generateExplanation(input: ExplanationInput, providers: ExplanationProvider[], fetcher: typeof fetch = fetch) {
  for (const provider of providers) {
    try {
      const response = await fetchWithTimeout(provider.url, {
        method: "POST",
        headers: { "Content-Type": "application/json", ...(
          provider.name === "mimo" ? { "api-key": provider.key } : { Authorization: `Bearer ${provider.key}` }
        ) },
        body: JSON.stringify({
          model: { deepseek: "deepseek-flash", mimo: "mimo-v2.6-flash", kimi: "kimi-k2.5" }[provider.name],
          messages: [
            { role: "system", content: explanationPrompt(input.language) },
            { role: "user", content: JSON.stringify({ english: input.english, chinese: input.chinese }) },
          ],
          thinking: { type: "disabled" },
          ...(provider.name === "deepseek" ? { max_tokens: 2048 } : { max_completion_tokens: 2048 }),
        }),
      }, 20000, fetcher)
      if (!response.ok) throw new Error(`HTTP ${response.status}`)
      const payload = await response.json()
      const raw = payload?.choices?.[0]?.message?.content
      if (typeof raw !== "string") throw new Error("Missing content")
      const json = raw.trim().replace(/^```(?:json)?\s*/i, "").replace(/\s*```$/, "")
      return validateExplanation(JSON.parse(json))
    } catch (error) {
      console.error("[explain-sentence] Provider failed", provider.name, error instanceof Error ? error.message : "Invalid response")
    }
  }
  throw new Error("No explanation provider succeeded")
}
