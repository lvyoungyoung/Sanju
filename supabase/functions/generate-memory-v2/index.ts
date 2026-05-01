import { createClient } from "npm:@supabase/supabase-js@2"

import {
  buildPromptText,
  decodeBase64,
  fetchWithTimeout,
  jsonResponse,
  parseSentences,
  serializeGenerationError,
  type ProviderName,
  type Sentence,
} from "./shared.ts"

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
