import { createClient } from "npm:@supabase/supabase-js@2"

interface Sentence {
  english: string
  chinese: string
}

type ProviderName = "mimo" | "kimi"

function buildPromptText(
  englishLevel: "简单" | "中等" | "高级",
  languageStyle: "平铺直叙" | "抒情优美"
): string {
  const englishLevelPrompt =
    englishLevel === "简单"
      ? "请使用非常简单、非常常见的英语词汇和句式，默认面向英语初学者。每句尽量控制在 6 到 12 个单词之间，优先使用小学到初中阶段常见词，不要使用抽象词、书面词、复杂从句、比喻、拟人、现在分词作状语、过去分词作定语等复杂结构。尽量多用简单主谓宾句型，例如 This is..., There is..., A girl is..., The cat is...。"
      : englishLevel === "高级"
        ? "请使用更丰富、更自然、更有层次感的英语表达，默认面向英语水平较高的学习者。每句尽量控制在 14 到 24 个单词之间，可以使用更细腻的词汇、更加完整的句子结构，以及适度的修辞和节奏变化，但仍要保持自然、准确、可理解，不要写得像诗歌或过度炫技。"
        : "请使用自然、日常、适合中等英语水平学习者的表达。每句尽量控制在 10 到 18 个单词之间，可以使用常见但稍丰富一些的日常表达，允许适度使用定语、状语和更完整的句子结构，但不要过于书面或艰深。"

  const languageStylePrompt =
    languageStyle === "抒情优美"
      ? "整体风格请明显更细腻、更有画面感、更有情绪和节奏。可以适度使用温柔、优美、富有氛围感的词语，让句子读起来更柔和、更有美感，但仍然要自然、准确、易懂。允许轻微的抒情和意境表达，但不要写成诗歌，不要过度夸张，不要脱离图片内容。"
      : "整体风格请尽量客观、直接、朴素、清楚，像日常口语或基础学习材料，不要刻意营造氛围，不要使用文学化修饰，不要写得太美，也不要加入抽象感受、联想、象征或情绪渲染。优先描述看得见的内容本身。"

  return `
请根据这张图片，生成三句适合英语学习的英文描述，并为每句提供对应的中文翻译。
如果图片是手机截图、应用界面、图表、股票页面、数据面板、网页、文档或任何带有大量文字/数字的信息界面，你也只能输出三句简洁描述，不要做分析报告，不要解释涨跌原因，不要总结数据，不要逐项抄写图片里的文字。
描述必须围绕图片中最明显、最直接可见的内容，用自然、可学习、可模仿的英语表达。
${englishLevelPrompt}
${languageStylePrompt}

你必须严格遵守以下输出规则：
1. 你的回复必须是一个 JSON 对象
2. 不要把 JSON 放在字符串里
3. 不要返回 markdown
4. 不要使用 \`\`\` 或 \`\`\`json 代码块
5. 不要写任何解释、前言、结尾、备注
6. 顶层字段必须且只能是 sentences
7. sentences 必须是长度为 3 的数组
8. 每一项必须且只能包含 english 和 chinese 两个字段
9. english 和 chinese 都必须是字符串
10. 不要输出任何多余字段
11. 不要转义整个 JSON 对象
12. 不要在 JSON 前后添加任何字符
13. 每句中文控制在 8 到 30 个汉字之间
14. 如果图片里有文字或数字，可以适度提到 "a screen"、"a chart"、"some numbers" 这类概括性表达，但不要逐字抄录内容

你必须严格按照下面这个格式返回：
{"sentences":[{"english":"...","chinese":"..."},{"english":"...","chinese":"..."},{"english":"...","chinese":"..."}]}
`.trim()
}

async function fetchWithTimeout(
  input: string,
  init: RequestInit,
  timeoutMs: number
): Promise<Response> {
  const controller = new AbortController()
  const timeout = setTimeout(() => controller.abort(), timeoutMs)

  try {
    return await fetch(input, {
      ...init,
      signal: controller.signal,
    })
  } finally {
    clearTimeout(timeout)
  }
}

function serializeGenerationError(args: {
  provider?: ProviderName
  code?: string
  statusCode?: number
  internalError: string
}) {
  return JSON.stringify({
    provider: args.provider ?? null,
    code: args.code ?? null,
    statusCode: args.statusCode ?? null,
    internalError: args.internalError,
    at: new Date().toISOString(),
  })
}

function parseSentences(content: string): Sentence[] | null {
  const candidate = extractSentencePayload(content)
  if (!candidate || !Array.isArray(candidate.sentences)) {
    return extractSentencesByPattern(content)
  }

  const sentences = normalizeSentenceArray(candidate.sentences)
  if (sentences.length === 3) {
    return sentences
  }

  return extractSentencesByPattern(content)
}

function extractSentencePayload(content: string): any | null {
  const normalized = normalizeJSONPayload(content)

  const direct = tryParseJSON(normalized)
  const fromDirect = normalizeParsedPayload(direct)
  if (fromDirect) {
    return fromDirect
  }

  const extracted = extractJSONObject(normalized)
  if (extracted) {
    const parsed = tryParseJSON(extracted)
    const normalizedParsed = normalizeParsedPayload(parsed)
    if (normalizedParsed) {
      return normalizedParsed
    }
  }

  return null
}

function normalizeParsedPayload(parsed: any): any | null {
  if (!parsed) {
    return null
  }

  if (typeof parsed === "string") {
    const reparsed = tryParseJSON(parsed)
    if (!reparsed || reparsed === parsed) {
      return null
    }
    return normalizeParsedPayload(reparsed)
  }

  if (Array.isArray(parsed)) {
    const sentences = normalizeSentenceArray(parsed)
    if (sentences.length === 3) {
      return { sentences }
    }
    return null
  }

  if (typeof parsed === "object" && !Array.isArray(parsed)) {
    const rawSentences = parsed.sentences

    if (typeof rawSentences === "string") {
      const reparsedSentences = tryParseJSON(rawSentences)
      const normalizedSentences = normalizeSentenceArray(reparsedSentences)
      if (normalizedSentences.length === 3) {
        return { sentences: normalizedSentences }
      }
    }

    if (Array.isArray(rawSentences)) {
      const normalizedSentences = normalizeSentenceArray(rawSentences)
      if (normalizedSentences.length === 3) {
        return { sentences: normalizedSentences }
      }
    }
  }

  return null
}

function normalizeSentenceArray(value: any): Sentence[] {
  if (!Array.isArray(value)) {
    return []
  }

  return value
    .map((item: any) => ({
      english: String(item?.english ?? "").trim(),
      chinese: String(item?.chinese ?? "").trim(),
    }))
    .filter((item: Sentence) => item.english && item.chinese)
}

function extractSentencesByPattern(content: string): Sentence[] | null {
  const normalized = normalizeJSONPayload(content)
  const pairRegex = /"english"\s*:\s*"((?:\\.|[^"\\])*)"\s*,\s*"chinese"\s*:\s*"((?:\\.|[^"\\])*)"/g

  const matches: Sentence[] = []
  let match: RegExpExecArray | null

  while ((match = pairRegex.exec(normalized)) !== null) {
    const english = decodeJSONStringFragment(match[1]).trim()
    const chinese = decodeJSONStringFragment(match[2]).trim()

    if (english && chinese) {
      matches.push({ english, chinese })
    }
  }

  return matches.length === 3 ? matches : null
}

function decodeJSONStringFragment(value: string): string {
  try {
    return JSON.parse(`"${value}"`)
  } catch {
    return value
      .replace(/\\"/g, '"')
      .replace(/\\\\/g, "\\")
      .replace(/\\n/g, " ")
      .replace(/\\r/g, " ")
      .replace(/\\t/g, " ")
  }
}

function tryParseJSON(value: string): any | null {
  try {
    return JSON.parse(value)
  } catch {
    return null
  }
}

function normalizeJSONPayload(content: string): string {
  const trimmed = content.trim()

  if (trimmed.startsWith("```")) {
    return trimmed
      .replace(/^```json\s*/i, "")
      .replace(/^```\s*/i, "")
      .replace(/\s*```$/, "")
      .trim()
  }

  return trimmed
}

function extractJSONObject(content: string): string | null {
  const start = content.indexOf("{")
  const end = content.lastIndexOf("}")

  if (start === -1 || end === -1 || end <= start) {
    return null
  }

  return content.slice(start, end + 1).trim()
}

function decodeBase64(base64: string): Uint8Array {
  const binary = atob(base64)
  const bytes = new Uint8Array(binary.length)
  for (let index = 0; index < binary.length; index += 1) {
    bytes[index] = binary.charCodeAt(index)
  }
  return bytes
}

function jsonResponse(data: unknown, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      "Content-Type": "application/json; charset=utf-8",
    },
  })
}



interface RequestBody {
  imageBase64: string
  englishLevel?: "简单" | "中等" | "高级"
  languageStyle?: "平铺直叙" | "抒情优美"
  guestJobID?: string
}

const MIMO_TIMEOUT_MS = 15000
const KIMI_TIMEOUT_MS = 20000
const GENERATION_CONCURRENCY_LIMIT = 50
const GENERATION_SLOT_TTL_SECONDS = 180
const GENERATION_VIOLATION_WINDOW_SECONDS = 24 * 60 * 60
const GENERATION_VIOLATION_LIMIT = 3
const GENERATION_VIOLATION_BAN_SECONDS = 24 * 60 * 60

Deno.serve(async (req) => {
  let adminClient: any = null
  let generationSlotRequestID: string | null = null
  let generationSlotAcquired = false

  try {
    if (req.method !== "POST") {
      return jsonResponse({ error: "Method Not Allowed" }, 405)
    }

    const mimoApiKey = Deno.env.get("MIMO_API_KEY")
    const mimoBaseURL = Deno.env.get("MIMO_BASE_URL")
    const kimiApiKey = Deno.env.get("KIMI_API_KEY")
    const kimiBaseURL = Deno.env.get("KIMI_BASE_URL")
    const supabaseUrl = Deno.env.get("SUPABASE_URL")
    const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY")
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")

    if (
      !mimoApiKey ||
      !mimoBaseURL ||
      !kimiApiKey ||
      !kimiBaseURL ||
      !supabaseUrl ||
      !supabaseAnonKey ||
      !serviceRoleKey
    ) {
      return jsonResponse({ error: "Missing server configuration" }, 500)
    }

    const authHeader = req.headers.get("Authorization")
    if (!authHeader?.startsWith("Bearer ")) {
      return jsonResponse({ error: "Missing Authorization header" }, 401)
    }

    const accessToken = authHeader.replace("Bearer ", "").trim()

    const userClient = createClient(supabaseUrl, supabaseAnonKey)
    adminClient = createClient(supabaseUrl, serviceRoleKey)

    const {
      data: { user },
      error: userError,
    } = await userClient.auth.getUser(accessToken)

    if (userError || !user) {
      return jsonResponse(
        {
          error: "Invalid JWT",
          details: userError?.message ?? null,
        },
        401
      )
    }

    const { data: profile, error: profileError } = await adminClient
      .from("profiles")
      .select("available_generations, generation_banned_until")
      .eq("id", user.id)
      .single()

    if (profileError || !profile) {
      return jsonResponse({ error: "Profile not found" }, 404)
    }

    if ((profile.available_generations ?? 0) <= 0) {
      return jsonResponse({ error: "No credits left" }, 403)
    }

    if (isFutureTimestamp(profile.generation_banned_until)) {
      return jsonResponse(
        {
          error: "当前账号暂时无法生成，请稍后再试。",
          code: "generation_banned",
          bannedUntil: profile.generation_banned_until,
        },
        403
      )
    }

    const body = (await req.json()) as RequestBody
    const imageBase64 = body.imageBase64?.replace(/\s+/g, "").trim()

    if (!imageBase64) {
      return jsonResponse({ error: "imageBase64 is required" }, 400)
    }

    const englishLevel = body.englishLevel ?? "中等"
    const languageStyle = body.languageStyle ?? "平铺直叙"
    const isAnonymous = user.is_anonymous === true
    const guestJobID = isAnonymous ? body.guestJobID?.trim() : undefined

    if (isAnonymous && !guestJobID) {
      return jsonResponse({ error: "guestJobID is required for anonymous users" }, 400)
    }

    generationSlotRequestID = crypto.randomUUID()
    generationSlotAcquired = await tryAcquireGenerationSlot(adminClient, {
      requestID: generationSlotRequestID,
      userID: user.id,
    })

    if (!generationSlotAcquired) {
      return jsonResponse(
        {
          error: "当前使用人数过多，请稍后重试。",
          code: "rate_limited",
          provider: "concurrency_gate",
        },
        429
      )
    }

    const createdAt = new Date().toISOString()

    let guestImagePath: string | null = null
    let guestImageUploaded = false

    if (isAnonymous) {
      guestImagePath = `${user.id}/guest/${guestJobID}.jpg`

      const { data: existingGuestJob, error: existingGuestJobError } = await adminClient
        .from("guest_generation_jobs")
        .select("id, status, provider")
        .eq("id", guestJobID)
        .eq("user_id", user.id)
        .maybeSingle()

      if (existingGuestJobError) {
        return jsonResponse(
          {
            error: "Failed to load guest generation job",
            details: existingGuestJobError.message,
          },
          500
        )
      }

      if (!existingGuestJob) {
        const { error: insertJobError } = await adminClient
          .from("guest_generation_jobs")
          .insert({
            id: guestJobID,
            user_id: user.id,
            status: "pending",
            image_path: guestImagePath,
          })

        if (insertJobError) {
          return jsonResponse(
            {
              error: "Failed to create guest generation job",
              details: insertJobError.message,
            },
            500
          )
        }

        const imageBytes = decodeBase64(imageBase64)
        const { error: uploadError } = await adminClient.storage
          .from("memories")
          .upload(guestImagePath, imageBytes, {
            contentType: "image/jpeg",
            upsert: false,
          })

        if (uploadError) {
          await adminClient
            .from("guest_generation_jobs")
            .update({
              status: "failed",
              error_message: `upload image failed: ${uploadError.message}`,
            })
            .eq("id", guestJobID)

          return jsonResponse(
            {
              error: "upload image failed",
              details: uploadError.message,
            },
            500
          )
        }

        guestImageUploaded = true
      } else if (
        existingGuestJob.status === "completed" ||
        existingGuestJob.status === "acknowledged"
      ) {
        const { data: completedJob, error: completedJobError } = await adminClient
          .from("guest_generation_jobs")
          .select("id, created_at, remaining_credits, sentences, provider")
          .eq("id", guestJobID)
          .eq("user_id", user.id)
          .maybeSingle()

        if (completedJobError) {
          return jsonResponse(
            {
              error: "Failed to load completed guest generation job",
              details: completedJobError.message,
            },
            500
          )
        }

        const sentences = Array.isArray(completedJob?.sentences) ? completedJob.sentences : []
        if (sentences.length !== 3) {
          return jsonResponse({ error: "Completed guest generation job is invalid" }, 500)
        }

        return jsonResponse({
          memory: {
            id: crypto.randomUUID(),
            imagePath: "",
            createdAt: completedJob?.created_at ?? createdAt,
            provider: completedJob?.provider ?? null,
            sentences: sentences.map((sentence: any) => ({
              id: crypto.randomUUID(),
              english: String(sentence?.english ?? "").trim(),
              chinese: String(sentence?.chinese ?? "").trim(),
              is_favorite: false,
            })),
          },
          remainingCredits: completedJob?.remaining_credits ?? profile.available_generations,
          guestJobID,
        })
      }
    }

    const promptText = buildPromptText(englishLevel, languageStyle)

    const completionResult = await requestWithFallback({
      imageBase64,
      promptText,
      mimoBaseURL,
      mimoApiKey,
      kimiBaseURL,
      kimiApiKey,
    })

    if (!completionResult.ok) {
      const serializedError = serializeGenerationError({
        provider: completionResult.provider,
        code: completionResult.code,
        statusCode: completionResult.statusCode,
        internalError: completionResult.internalError,
      })

      console.error("[generate-memory-v2]", serializedError)

      let violationRecord: GenerationViolationRecord | null = null
      if (completionResult.policyViolation) {
        violationRecord = await recordGenerationViolation(adminClient, user.id)
      }

      if (guestJobID) {
        await adminClient
          .from("guest_generation_jobs")
          .update({
            status: "failed",
            error_message: serializedError,
          })
          .eq("id", guestJobID)
      }

      if (guestImageUploaded && guestImagePath) {
        await adminClient.storage.from("memories").remove([guestImagePath])
      }

      if (completionResult.policyViolation) {
        return jsonResponse(buildGenerationPolicyViolationError(violationRecord), 403)
      }

      return jsonResponse(completionResult.publicError, completionResult.statusCode)
    }

    const { sentences, provider } = completionResult
    const finalizedSentences = sentences.map((sentence) => ({
      id: crypto.randomUUID(),
      english: sentence.english,
      chinese: sentence.chinese,
      is_favorite: false,
    }))

    if (isAnonymous) {
      const finalizeResult = await finalizeGuestGeneration(adminClient, {
        guestJobID: guestJobID!,
        userID: user.id,
        createdAt,
        provider,
        sentences: finalizedSentences,
      })

      if (!finalizeResult.ok) {
        const serializedError = serializeGenerationError({
          provider,
          code: finalizeResult.code,
          statusCode: finalizeResult.statusCode,
          internalError: finalizeResult.internalError,
        })

        console.error("[generate-memory-v2]", serializedError)

        await adminClient
          .from("guest_generation_jobs")
          .update({
            status: "failed",
            error_message: serializedError,
          })
          .eq("id", guestJobID)

        if (guestImageUploaded && guestImagePath) {
          await adminClient.storage.from("memories").remove([guestImagePath])
        }

        return jsonResponse(finalizeResult.publicError, finalizeResult.statusCode)
      }

      return jsonResponse({
        memory: {
          id: crypto.randomUUID(),
          imagePath: "",
          createdAt,
          provider,
          sentences: finalizedSentences,
        },
        remainingCredits: finalizeResult.remainingCredits,
        guestJobID,
      })
    }

    const memoryID = crypto.randomUUID()
    const imagePath = `${user.id}/${crypto.randomUUID().toLowerCase()}.jpg`
    const imageBytes = decodeBase64(imageBase64)

    const { error: uploadError } = await adminClient.storage
      .from("memories")
      .upload(imagePath, imageBytes, {
        contentType: "image/jpeg",
        upsert: false,
      })

    if (uploadError) {
      return jsonResponse(
        {
          error: "upload image failed",
          details: uploadError.message,
        },
        500
      )
    }

    const finalizeResult = await finalizeAuthenticatedGeneration(adminClient, {
      memoryID,
      userID: user.id,
      imagePath,
      createdAt,
      provider,
      sentences: finalizedSentences,
    })

    if (!finalizeResult.ok) {
      const serializedError = serializeGenerationError({
        provider,
        code: finalizeResult.code,
        statusCode: finalizeResult.statusCode,
        internalError: finalizeResult.internalError,
      })

      console.error("[generate-memory-v2]", serializedError)
      await adminClient.storage.from("memories").remove([imagePath])

      return jsonResponse(finalizeResult.publicError, finalizeResult.statusCode)
    }

    return jsonResponse({
      memory: {
        id: memoryID,
        imagePath,
        createdAt,
        provider,
        sentences: finalizedSentences,
      },
      remainingCredits: finalizeResult.remainingCredits,
    })
  } catch (error) {
    console.error(
      "[generate-memory-v2]",
      JSON.stringify({
        provider: null,
        code: "unexpected_server_error",
        statusCode: 500,
        internalError: error instanceof Error ? error.message : String(error),
        at: new Date().toISOString(),
      })
    )

    return jsonResponse(
      {
        error: "生成失败，请稍后再试",
        details: error instanceof Error ? error.message : String(error),
        stack: error instanceof Error ? error.stack : null,
      },
      500
    )
  } finally {
    if (generationSlotAcquired && generationSlotRequestID && adminClient) {
      try {
        await releaseGenerationSlot(adminClient, generationSlotRequestID)
      } catch (error) {
        console.error(
          "[generate-memory-v2]",
          JSON.stringify({
            code: "generation_slot_release_failed",
            internalError: error instanceof Error ? error.message : String(error),
            requestID: generationSlotRequestID,
            at: new Date().toISOString(),
          })
        )
      }
    }
  }
})

async function requestWithFallback(args: {
  imageBase64: string
  promptText: string
  mimoBaseURL: string
  mimoApiKey: string
  kimiBaseURL: string
  kimiApiKey: string
}): Promise<
  | { ok: true; sentences: Sentence[]; provider: ProviderName }
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
    model: "mimo-v2-omni",
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

  const mimoResult = await requestMimoOnce(
    args.mimoBaseURL,
    args.mimoApiKey,
    mimoRequestBody
  )

  if (mimoResult.ok) {
    return mimoResult
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

  const kimiResult = await requestKimiOnce(
    args.kimiBaseURL,
    args.kimiApiKey,
    kimiRequestBody
  )

  if (kimiResult.ok) {
    return kimiResult
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
    internalError: `[MiMo] ${mimoResult.internalError} | [Kimi] ${kimiResult.internalError}`,
    publicError: kimiResult.publicError,
  }
}

async function requestMimoOnce(
  mimoBaseURL: string,
  mimoApiKey: string,
  requestBody: unknown
): Promise<
  | { ok: true; sentences: Sentence[]; provider: ProviderName }
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

  try {
    response = await fetchWithTimeout(
      mimoBaseURL,
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "api-key": mimoApiKey,
        },
        body: JSON.stringify(requestBody),
      },
      MIMO_TIMEOUT_MS
    )
  } catch (error) {
    const isTimeout = error instanceof DOMException && error.name === "AbortError"

    return {
      ok: false,
      provider: "mimo",
      fallbackable: true,
      rateLimited: false,
      statusCode: 500,
      internalError: isTimeout ? "MiMo request timeout" : `MiMo fetch failed: ${String(error)}`,
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
    if (isGenerationPolicyViolation(data, rawText)) {
      return {
        ok: false,
        provider: "mimo",
        code: "generation_policy_violation",
        policyViolation: true,
        fallbackable: false,
        rateLimited: false,
        statusCode: 403,
        internalError: `MiMo policy violation: ${rawText}`,
        publicError: {
          error: "这张图片暂时无法生成，请更换图片后再试。",
          code: "generation_policy_violation",
          provider: "mimo",
        },
      }
    }

    if (response.status === 429) {
      return {
        ok: false,
        provider: "mimo",
        code: "rate_limited",
        fallbackable: false,
        rateLimited: true,
        statusCode: 429,
        internalError: "MiMo rate limited",
        publicError: {
          error: "当前使用人数过多，请稍后重试。",
          code: "rate_limited",
          provider: "mimo",
        },
      }
    }

    return {
      ok: false,
      provider: "mimo",
      fallbackable: false,
      rateLimited: false,
      statusCode: response.status,
      internalError: "MiMo request failed",
      publicError: {
        error: "生成失败，请稍后再试",
        details: data ?? rawText,
      },
    }
  }

  const content = data?.choices?.[0]?.message?.content
  if (typeof content === "string" && isGenerationPolicyViolation(data, content)) {
    return {
      ok: false,
      provider: "mimo",
      code: "generation_policy_violation",
      policyViolation: true,
      fallbackable: false,
      rateLimited: false,
      statusCode: 403,
      internalError: `MiMo policy violation content: ${content}`,
      publicError: {
        error: "这张图片暂时无法生成，请更换图片后再试。",
        code: "generation_policy_violation",
        provider: "mimo",
      },
    }
  }

  if (!content || typeof content !== "string") {
    return {
      ok: false,
      provider: "mimo",
      fallbackable: true,
      rateLimited: false,
      statusCode: 500,
      internalError: "Invalid MiMo response content",
      publicError: { error: "生成结果格式异常，请重试" },
    }
  }

  const sentences = parseSentences(content)
  if (!sentences || sentences.length !== 3) {
    return {
      ok: false,
      provider: "mimo",
      fallbackable: true,
      rateLimited: false,
      statusCode: 500,
      internalError: "Failed to parse sentences",
      publicError: { error: "生成结果格式异常，请重试" },
    }
  }

  return {
    ok: true,
    sentences,
    provider: "mimo",
  }
}

async function requestKimiOnce(
  kimiBaseURL: string,
  kimiApiKey: string,
  requestBody: unknown
): Promise<
  | { ok: true; sentences: Sentence[]; provider: ProviderName }
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
      KIMI_TIMEOUT_MS
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
    if (isGenerationPolicyViolation(data, rawText)) {
      return {
        ok: false,
        provider: "kimi",
        code: "generation_policy_violation",
        policyViolation: true,
        rateLimited: false,
        statusCode: 403,
        internalError: `Kimi policy violation: ${rawText}`,
        publicError: {
          error: "这张图片暂时无法生成，请更换图片后再试。",
          code: "generation_policy_violation",
          provider: "kimi",
        },
      }
    }

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
        details: data ?? rawText,
      },
    }
  }

  const content = data?.choices?.[0]?.message?.content
  if (typeof content === "string" && isGenerationPolicyViolation(data, content)) {
    return {
      ok: false,
      provider: "kimi",
      code: "generation_policy_violation",
      policyViolation: true,
      rateLimited: false,
      statusCode: 403,
      internalError: `Kimi policy violation content: ${content}`,
      publicError: {
        error: "这张图片暂时无法生成，请更换图片后再试。",
        code: "generation_policy_violation",
        provider: "kimi",
      },
    }
  }

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

  const sentences = parseSentences(content)
  if (!sentences || sentences.length !== 3) {
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
    sentences,
    provider: "kimi",
  }
}

async function finalizeAuthenticatedGeneration(
  adminClient: any,
  args: {
    memoryID: string
    userID: string
    imagePath: string
    createdAt: string
    provider: ProviderName
    sentences: Sentence[]
  }
): Promise<
  | { ok: true; remainingCredits: number }
  | {
      ok: false
      code?: string
      statusCode: number
      internalError: string
      publicError: Record<string, unknown>
    }
> {
  const { data, error } = await adminClient.rpc("finalize_authenticated_generation", {
    p_memory_id: args.memoryID,
    p_user_id: args.userID,
    p_image_path: args.imagePath,
    p_created_at: args.createdAt,
    p_provider: args.provider,
    p_sentences: args.sentences,
  })

  if (error) {
    return buildRpcErrorResponse(error, "Authenticated finalize failed")
  }

  return {
    ok: true,
    remainingCredits: normalizeRPCInteger(data),
  }
}

async function finalizeGuestGeneration(
  adminClient: any,
  args: {
    guestJobID: string
    userID: string
    createdAt: string
    provider: ProviderName
    sentences: Sentence[]
  }
): Promise<
  | { ok: true; remainingCredits: number }
  | {
      ok: false
      code?: string
      statusCode: number
      internalError: string
      publicError: Record<string, unknown>
    }
> {
  const { data, error } = await adminClient.rpc("finalize_guest_generation", {
    p_guest_job_id: args.guestJobID,
    p_user_id: args.userID,
    p_completed_at: args.createdAt,
    p_provider: args.provider,
    p_sentences: args.sentences,
  })

  if (error) {
    return buildRpcErrorResponse(error, "Guest finalize failed")
  }

  return {
    ok: true,
    remainingCredits: normalizeRPCInteger(data),
  }
}

async function tryAcquireGenerationSlot(
  adminClient: any,
  args: {
    requestID: string
    userID: string
  }
): Promise<boolean> {
  const { data, error } = await adminClient.rpc("try_acquire_generation_slot", {
    p_request_id: args.requestID,
    p_user_id: args.userID,
    p_max_slots: GENERATION_CONCURRENCY_LIMIT,
    p_ttl_seconds: GENERATION_SLOT_TTL_SECONDS,
  })

  if (error) {
    throw new Error(`Acquire generation slot failed: ${error.message}`)
  }

  return data === true
}

async function releaseGenerationSlot(adminClient: any, requestID: string): Promise<void> {
  const { error } = await adminClient.rpc("release_generation_slot", {
    p_request_id: requestID,
  })

  if (error) {
    throw new Error(`Release generation slot failed: ${error.message}`)
  }
}

function buildRpcErrorResponse(
  error: {
    message: string
    details?: string | null
    hint?: string | null
    code?: string
  },
  fallbackMessage: string
): {
  ok: false
  code?: string
  statusCode: number
  internalError: string
  publicError: Record<string, unknown>
} {
  const normalizedMessage = `${error.message} ${error.details ?? ""}`.trim().toLowerCase()
  const isNoCredits = normalizedMessage.includes("no credits left")

  if (isNoCredits) {
    return {
      ok: false,
      code: "no_credits_left",
      statusCode: 403,
      internalError: error.message,
      publicError: {
        error: "No credits left",
      },
    }
  }

  return {
    ok: false,
    code: error.code,
    statusCode: 500,
    internalError: `${fallbackMessage}: ${error.message}`,
    publicError: {
      error: "生成失败，请稍后再试",
      details: {
        message: error.message,
        details: error.details ?? null,
        hint: error.hint ?? null,
        code: error.code ?? null,
      },
    },
  }
}

function normalizeRPCInteger(value: unknown): number {
  if (typeof value === "number" && Number.isFinite(value)) {
    return value
  }

  if (typeof value === "string") {
    const parsed = Number.parseInt(value, 10)
    if (Number.isFinite(parsed)) {
      return parsed
    }
  }

  throw new Error(`Unexpected RPC integer result: ${JSON.stringify(value)}`)
}

type GenerationViolationRecord = {
  violationCount: number
  bannedUntil: string | null
}

function isFutureTimestamp(value: unknown): boolean {
  if (typeof value !== "string" || !value.trim()) {
    return false
  }

  const timestamp = Date.parse(value)
  return Number.isFinite(timestamp) && timestamp > Date.now()
}

async function recordGenerationViolation(
  adminClient: any,
  userID: string
): Promise<GenerationViolationRecord | null> {
  const { data, error } = await adminClient.rpc("record_generation_violation", {
    p_user_id: userID,
    p_window_seconds: GENERATION_VIOLATION_WINDOW_SECONDS,
    p_limit: GENERATION_VIOLATION_LIMIT,
    p_ban_seconds: GENERATION_VIOLATION_BAN_SECONDS,
  })

  if (error) {
    console.error(
      "[generate-memory-v2]",
      serializeGenerationError({
        code: "record_generation_violation_failed",
        statusCode: 500,
        internalError: error.message,
      })
    )
    return null
  }

  const record = Array.isArray(data) ? data[0] : data
  if (!record) {
    return null
  }

  const rawCount = record.violation_count ?? record.violationCount
  const violationCount =
    typeof rawCount === "number" ? rawCount : Number.parseInt(String(rawCount ?? "0"), 10)
  const bannedUntil =
    typeof record.banned_until === "string"
      ? record.banned_until
      : typeof record.bannedUntil === "string"
        ? record.bannedUntil
        : null

  return {
    violationCount: Number.isFinite(violationCount) ? violationCount : 0,
    bannedUntil,
  }
}

function buildGenerationPolicyViolationError(
  record: GenerationViolationRecord | null
): Record<string, unknown> {
  const isBanned = isFutureTimestamp(record?.bannedUntil)

  return {
    error: isBanned
      ? "当前账号暂时无法生成，请稍后再试。"
      : "这张图片暂时无法生成，请更换图片后再试。",
    code: isBanned ? "generation_banned" : "generation_policy_violation",
    bannedUntil: record?.bannedUntil ?? null,
    violationCount: record?.violationCount ?? null,
  }
}

function isGenerationPolicyViolation(data: unknown, rawText: string): boolean {
  const collectedText = [rawText, ...collectStringValues(data)]
    .join(" ")
    .toLowerCase()
  const compactText = collectedText.replace(/[\s_-]+/g, "")

  const compactKeywords = [
    "contentfilter",
    "contentpolicy",
    "policyviolation",
    "safetyviolation",
    "imagesafety",
    "filteredduetosafety",
  ]
  const phraseKeywords = [
    "moderation",
    "prohibited",
    "disallowed",
    "not allowed",
    "unsafe content",
    "sensitive content",
    "violates policy",
    "violated policy",
    "policy violation",
    "content filter",
    "content policy",
    "safety policy",
    "safety violation",
    "违规",
    "不合规",
    "违反",
    "违法",
    "敏感内容",
    "内容安全",
    "安全策略",
    "审核不通过",
    "无法处理该图片",
  ]

  return (
    compactKeywords.some((keyword) => compactText.includes(keyword)) ||
    phraseKeywords.some((keyword) => collectedText.includes(keyword))
  )
}

function collectStringValues(value: unknown, depth = 0): string[] {
  if (depth > 4 || value == null) {
    return []
  }

  if (typeof value === "string") {
    return [value]
  }

  if (typeof value === "number" || typeof value === "boolean") {
    return [String(value)]
  }

  if (Array.isArray(value)) {
    return value.flatMap((item) => collectStringValues(item, depth + 1))
  }

  if (typeof value === "object") {
    return Object.values(value as Record<string, unknown>).flatMap((item) =>
      collectStringValues(item, depth + 1)
    )
  }

  return []
}
