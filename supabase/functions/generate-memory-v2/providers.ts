import { fetchWithTimeout } from "../_shared/fetch-with-timeout.ts"
import type { GenerationTiming } from "../_shared/generation-timing.ts"
import { type Sentence, type GenerationFormat, type ProviderName, parseGeneratedContent } from "./content.ts"
import { serializeGenerationError, summarizeProviderFailure, appendDiagnosticSnippet } from "./responses.ts"

const MIMO_TIMEOUT_MS = 20000
const KIMI_TIMEOUT_MS = 20000
const DEEPSEEK_TIMEOUT_MS = 20000

export function usesDeepSeekGeneration(projectURL: string | undefined): boolean {
  try {
    const url = new URL(projectURL ?? "")
    return url.protocol === "https:" && [
      "spb-bp1364k407p37qn7.supabase.opentrust.net",
      "api-staging.sanju.cc",
      "spb-bp103246ivn7q0nl.supabase.opentrust.net",
      "api.sanju.cc",
    ].includes(url.hostname)
  } catch {
    return false
  }
}

export async function requestWithFallback(args: {
  imageBase64: string
  promptText: string
  generationFormat: GenerationFormat
  mimoBaseURL: string
  mimoApiKey: string
  kimiBaseURL: string
  kimiApiKey: string
  deepseek?: { baseURL: string; apiKey: string }
  fetcher: typeof fetch
  timing?: GenerationTiming
}): Promise<
  | {
      ok: true
      sentences: Sentence[]
      tags: string[]
      provider: ProviderName
      mimoFailureReason: string | null
    }
  | {
      ok: false
      provider?: ProviderName
      code?: string
      policyViolation?: boolean
      statusCode: number
      internalError: string
      publicError: Record<string, unknown>
    }
> {
  const mimoRequestBody = {
    model: "mimo-v2.6-flash",
    messages: [
      {
        role: "system",
        content: "You are MiMo, an AI assistant developed by Xiaomi.",
      },
      {
        role: "user",
        content: [
          {
            type: "image_url",
            image_url: {
              url: `data:image/jpeg;base64,${args.imageBase64}`,
            },
          },
          {
            type: "text",
            text: args.promptText,
          },
        ],
      },
    ],
    thinking: {
      type: "disabled",
    },
    max_completion_tokens: 4096,
  }

  let deepseekFailure: string | null = null
  if (args.deepseek) {
    args.timing?.start("deepseek")
    const deepseekResult = await requestPrimaryModelOnce(
      args.deepseek.baseURL,
      args.deepseek.apiKey,
      {
        model: "deepseek-flash",
        messages: [
          { role: "system", content: "You are a helpful assistant." },
          mimoRequestBody.messages[1],
        ],
        thinking: { type: "disabled" },
        max_tokens: 4096,
      },
      args.generationFormat,
      args.fetcher,
      "deepseek"
    )
    args.timing?.start("model_result")
    if (deepseekResult.ok) return { ...deepseekResult, mimoFailureReason: null }
    deepseekFailure = deepseekResult.internalError
    console.error("[generate-memory-v2]", serializeGenerationError({
      provider: deepseekResult.provider,
      code: deepseekResult.code,
      statusCode: deepseekResult.statusCode,
      internalError: `[DeepSeek fallback candidate] ${deepseekFailure}`,
    }))
  }

  args.timing?.start("mimo")
  const mimoResult = await requestPrimaryModelOnce(
    args.mimoBaseURL,
    args.mimoApiKey,
    mimoRequestBody,
    args.generationFormat,
    args.fetcher
  )

  args.timing?.start("model_result")
  if (mimoResult.ok) {
    return {
      ...mimoResult,
      mimoFailureReason: null,
    }
  }

  console.error(
    "[generate-memory-v2]",
    serializeGenerationError({
      provider: mimoResult.provider,
      code: mimoResult.code,
      statusCode: mimoResult.statusCode,
      internalError: `[MiMo fallback candidate] ${mimoResult.internalError}`,
    })
  )

  const shouldFallbackToKimi = mimoResult.fallbackable || mimoResult.rateLimited

  if (!shouldFallbackToKimi) {
    return {
      ok: false,
      provider: mimoResult.provider,
      code: mimoResult.code,
      policyViolation: mimoResult.policyViolation,
      statusCode: mimoResult.statusCode,
      internalError: `[MiMo] ${mimoResult.internalError}`,
      publicError: mimoResult.publicError,
    }
  }

  const kimiRequestBody = {
    model: "kimi-k2.5",
    messages: [
      {
        role: "system",
        content: "你是 Kimi，由 Moonshot AI 提供的人工智能助手，你更擅长中文和英文的对话。你会为用户提供安全、有帮助、准确的回答。",
      },
      {
        role: "user",
        content: [
          {
            type: "image_url",
            image_url: {
              url: `data:image/jpeg;base64,${args.imageBase64}`,
            },
          },
          {
            type: "text",
            text: args.promptText,
          },
        ],
      },
    ],
    thinking: {
      type: "disabled",
    },
  }

  args.timing?.start("kimi")
  const kimiResult = await requestKimiOnce(
    args.kimiBaseURL,
    args.kimiApiKey,
    kimiRequestBody,
    args.generationFormat,
    args.fetcher
  )

  args.timing?.start("model_result")
  if (kimiResult.ok) {
    return {
      ...kimiResult,
      mimoFailureReason: summarizeProviderFailure(mimoResult),
    }
  }

  console.error(
    "[generate-memory-v2]",
    serializeGenerationError({
      provider: kimiResult.provider,
      code: kimiResult.code,
      statusCode: kimiResult.statusCode,
      internalError: `[Kimi fallback failed] ${kimiResult.internalError}`,
    })
  )

  return {
    ok: false,
    provider: kimiResult.provider ?? mimoResult.provider,
    code: kimiResult.code,
    policyViolation: kimiResult.policyViolation,
    statusCode: kimiResult.statusCode,
    internalError: `${deepseekFailure ? `[DeepSeek] ${deepseekFailure} | ` : ""}[MiMo] ${mimoResult.internalError} | [Kimi] ${kimiResult.internalError}`,
    publicError: kimiResult.publicError,
  }
}

async function requestPrimaryModelOnce(
  baseURL: string,
  apiKey: string,
  requestBody: unknown,
  generationFormat: GenerationFormat,
  fetcher: typeof fetch,
  provider: "mimo" | "deepseek" = "mimo"
): Promise<
  | { ok: true; sentences: Sentence[]; tags: string[]; provider: ProviderName }
  | {
      ok: false
      provider: ProviderName
      code?: string
      policyViolation?: boolean
      fallbackable: boolean
      rateLimited: boolean
      statusCode: number
      internalError: string
      publicError: Record<string, unknown>
    }
> {
  let response: Response
  const providerLabel = provider === "deepseek" ? "DeepSeek" : "MiMo"

  try {
    response = await fetchWithTimeout(
      baseURL,
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          ...(provider === "deepseek" ? { Authorization: `Bearer ${apiKey}` } : { "api-key": apiKey }),
        },
        body: JSON.stringify(requestBody),
      },
      provider === "deepseek" ? DEEPSEEK_TIMEOUT_MS : MIMO_TIMEOUT_MS,
      fetcher
    )
  } catch (error) {
    const isTimeout = error instanceof DOMException && error.name === "AbortError"

    return {
      ok: false,
      provider,
      fallbackable: true,
      rateLimited: false,
      statusCode: 500,
      internalError: isTimeout ? `${providerLabel} request timeout` : `${providerLabel} fetch failed: ${String(error)}`,
      publicError: {
        error: "生成失败，请稍后再试",
      },
    }
  }

  const rawText = await response.text()

  let data: any
  try {
    data = JSON.parse(rawText)
  } catch {
    data = null
  }

  if (!response.ok) {
    if (response.status === 429) {
      return {
        ok: false,
        provider,
        code: "rate_limited",
        fallbackable: false,
        rateLimited: true,
        statusCode: 429,
        internalError: `${providerLabel} rate limited`,
        publicError: {
          error: "当前使用人数过多，请稍后重试。",
          code: "rate_limited",
          provider,
        },
      }
    }

    return {
      ok: false,
      provider,
      fallbackable: true,
      rateLimited: false,
      statusCode: response.status,
      internalError: appendDiagnosticSnippet(
        `${providerLabel} request failed: HTTP ${response.status} ${response.statusText}`,
        "response_snippet",
        rawText
      ),
      publicError: {
        error: "生成失败，请稍后再试",
      },
    }
  }

  const content = data?.choices?.[0]?.message?.content

  if (!content || typeof content !== "string") {
    return {
      ok: false,
      provider,
      fallbackable: true,
      rateLimited: false,
      statusCode: 500,
      internalError: appendDiagnosticSnippet(
        `Invalid ${providerLabel} response content`,
        "response_snippet",
        rawText
      ),
      publicError: { error: "生成结果格式异常，请重试" },
    }
  }

  const generatedContent = parseGeneratedContent(content, generationFormat)
  if (!generatedContent) {
    return {
      ok: false,
      provider,
      fallbackable: true,
      rateLimited: false,
      statusCode: 500,
      internalError: appendDiagnosticSnippet(
        "Failed to parse sentences",
        "content_snippet",
        content
      ),
      publicError: { error: "生成结果格式异常，请重试" },
    }
  }

  return {
    ok: true,
    sentences: generatedContent.sentences,
    tags: generatedContent.tags,
    provider,
  }
}

async function requestKimiOnce(
  kimiBaseURL: string,
  kimiApiKey: string,
  requestBody: unknown,
  generationFormat: GenerationFormat,
  fetcher: typeof fetch
): Promise<
  | { ok: true; sentences: Sentence[]; tags: string[]; provider: ProviderName }
  | {
      ok: false
      provider: ProviderName
      code?: string
      policyViolation?: boolean
      rateLimited: boolean
      statusCode: number
      internalError: string
      publicError: Record<string, unknown>
    }
> {
  let response: Response

  try {
    response = await fetchWithTimeout(
      kimiBaseURL,
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${kimiApiKey}`,
        },
        body: JSON.stringify(requestBody),
      },
      KIMI_TIMEOUT_MS,
      fetcher
    )
  } catch (error) {
    const isTimeout = error instanceof DOMException && error.name === "AbortError"

    return {
      ok: false,
      provider: "kimi",
      rateLimited: false,
      statusCode: 500,
      internalError: isTimeout ? "Kimi request timeout" : `Kimi fetch failed: ${String(error)}`,
      publicError: {
        error: "生成失败，请稍后再试",
      },
    }
  }

  const rawText = await response.text()

  let data: any
  try {
    data = JSON.parse(rawText)
  } catch {
    data = null
  }

  if (!response.ok) {
    if (response.status === 429) {
      return {
        ok: false,
        provider: "kimi",
        code: "rate_limited",
        rateLimited: true,
        statusCode: 429,
        internalError: "Kimi rate limited",
        publicError: {
          error: "当前使用人数过多，请稍后重试。",
          code: "rate_limited",
          provider: "kimi",
        },
      }
    }

    return {
      ok: false,
      provider: "kimi",
      rateLimited: false,
      statusCode: response.status,
      internalError: "Kimi request failed",
      publicError: {
        error: "生成失败，请稍后再试",
      },
    }
  }

  const content = data?.choices?.[0]?.message?.content

  if (!content || typeof content !== "string") {
    return {
      ok: false,
      provider: "kimi",
      rateLimited: false,
      statusCode: 500,
      internalError: "Invalid Kimi response content",
      publicError: { error: "生成结果格式异常，请重试" },
    }
  }

  const generatedContent = parseGeneratedContent(content, generationFormat)
  if (!generatedContent) {
    return {
      ok: false,
      provider: "kimi",
      rateLimited: false,
      statusCode: 500,
      internalError: "Failed to parse sentences",
      publicError: { error: "生成结果格式异常，请重试" },
    }
  }

  return {
    ok: true,
    sentences: generatedContent.sentences,
    tags: generatedContent.tags,
    provider: "kimi",
  }
}
