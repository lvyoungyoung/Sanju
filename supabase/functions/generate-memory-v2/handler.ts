import { createClient } from "npm:@supabase/supabase-js@2"
import { fetchWithTimeout, fetchWithinDeadline } from "../_shared/fetch-with-timeout.ts"
import { scheduleGenerationEnrichment, type EnrichmentScope } from "../_shared/generation-enrichment.ts"
import type { GenerationTiming } from "../_shared/generation-timing.ts"
import { type GenerationFormat, buildPromptText, selectQuestionTypes } from "./content.ts"
import { serializeGenerationError, decodeBase64, jsonResponse, normalizeOptionalUUID, isTimeoutError, generationPendingResponse } from "./responses.ts"
import { requestWithFallback, usesDeepSeekGeneration } from "./providers.ts"
import { loadCompletedAuthenticatedGenerationResponseIfNeeded, loadCompletedGuestGenerationResponseIfNeeded, markAuthenticatedGenerationJobFailed, tryAcquireGenerationSlot, releaseGenerationSlot, removeStoragePathQuietly, markGuestGenerationJobFailed } from "./repository.ts"
import { type GenerationViolationRecord, moderateImageBeforeGeneration, isGenerationViolationBanEnabled, isFutureTimestamp, recordGenerationViolation, buildGenerationPolicyViolationError } from "./moderation.ts"
import { persistGeneratedResult } from "./persist-result.ts"

interface RequestBody {
  imageBase64: string
  englishLevel?: "启蒙" | "简单" | "中等" | "高级"
  guestJobID?: string
  clientRequestID?: string
  generationFormat?: string
}
const GENERATION_REQUEST_BUDGET_MS = 90000
export async function handleGenerationRequest(req: Request, timing: GenerationTiming): Promise<Response> {
  let adminClient: any = null
  let generationSlotRequestID: string | null = null
  let generationSlotAcquired = false
  let authenticatedClientRequestID: string | null = null
  let ownedGuestJobID: string | null = null
  let generationUserID: string | null = null
  let enrichmentScope: EnrichmentScope | null = null
  let ownsAuthenticatedJob = false
  let finalizationStarted = false
  let cleanupClient: any = null
  const generationDeadline = Date.now() + GENERATION_REQUEST_BUDGET_MS
  const generationFetch = fetchWithinDeadline(generationDeadline)

  try {
    if (req.method !== "POST") {
      return jsonResponse({ error: "Method Not Allowed" }, 405)
    }

    const mimoApiKey = Deno.env.get("MIMO_API_KEY")
    const mimoBaseURL = Deno.env.get("MIMO_BASE_URL")
    const kimiApiKey = Deno.env.get("KIMI_API_KEY")
    const kimiBaseURL = Deno.env.get("KIMI_BASE_URL")
    // Select from server-owned public project identity, never the incoming URL
    // or the local gateway (which is shared by staging and production).
    const useDeepSeek = usesDeepSeekGeneration(Deno.env.get("SUPABASE_URL"))
    const deepseekApiKey = useDeepSeek ? Deno.env.get("DEEPSEEK_API_KEY") : undefined
    const deepseekBaseURL = useDeepSeek ? Deno.env.get("DEEPSEEK_BASE_URL") : undefined
    // Use the project-local gateway inside Edge Runtime. Public URL loopback
    // can time out after infrastructure upgrades even while client traffic works.
    const supabaseUrl = Deno.env.get("SUPABASE_LOCAL_URL") ?? Deno.env.get("SUPABASE_URL")
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

    if (useDeepSeek && (!deepseekApiKey || !deepseekBaseURL)) {
      return jsonResponse({ error: "Missing DeepSeek generation configuration" }, 500)
    }

    const authHeader = req.headers.get("Authorization")
    if (!authHeader?.startsWith("Bearer ")) {
      return jsonResponse({ error: "Missing Authorization header" }, 401)
    }

    const accessToken = authHeader.replace("Bearer ", "").trim()

    const userClient = createClient(supabaseUrl, supabaseAnonKey, { global: { fetch: generationFetch } })
    adminClient = createClient(supabaseUrl, serviceRoleKey, { global: { fetch: generationFetch } })
    cleanupClient = createClient(supabaseUrl, serviceRoleKey, {
      global: { fetch: (input, init) => fetchWithTimeout(input, init, 5000) },
    })

    timing.start("auth")
    const {
      data: { user },
      error: userError,
    } = await userClient.auth.getUser(accessToken)

    if (userError || !user) {
      if (Date.now() >= generationDeadline) return generationPendingResponse(true)
      return jsonResponse(
        {
          error: "Invalid JWT",
          details: userError?.message ?? null,
        },
        401
      )
    }

    generationUserID = user.id
    timing.start("profile")
    const { data: profile, error: profileError } = await adminClient
      .from("profiles")
      .select("available_generations, generation_banned_until")
      .eq("id", user.id)
      .single()

    if (profileError || !profile) {
      if (Date.now() >= generationDeadline) return generationPendingResponse(true)
      return jsonResponse({ error: "Profile not found" }, 404)
    }

    timing.start("request_decode")
    const body = (await req.json()) as RequestBody
    const imageBase64 = body.imageBase64?.replace(/\s+/g, "").trim()

    if (!imageBase64) {
      return jsonResponse({ error: "imageBase64 is required" }, 400)
    }

    const imageBytes = decodeBase64(imageBase64)
    const englishLevel = body.englishLevel ?? "中等"
    const generationFormat: GenerationFormat = body.generationFormat === "dual_tabs_v1"
      ? "dual_tabs_v1"
      : "legacy_v1"
    const isAnonymous = user.is_anonymous === true
    const guestJobID = isAnonymous ? body.guestJobID?.trim() : undefined
    authenticatedClientRequestID = isAnonymous
      ? null
      : normalizeOptionalUUID(body.clientRequestID) ?? null

    if (isAnonymous && !guestJobID) {
      return jsonResponse({ error: "guestJobID is required for anonymous users" }, 400)
    }

    const createdAt = new Date().toISOString()
    let existingGuestJob: { id: string; status: string; provider?: string | null } | null = null

    timing.start("existing_result")
    if (!isAnonymous && authenticatedClientRequestID) {
      const completedResponse = await loadCompletedAuthenticatedGenerationResponseIfNeeded(
        adminClient,
        {
          clientRequestID: authenticatedClientRequestID,
          userID: user.id,
          fallbackRemainingCredits: profile.available_generations,
          generationFormat,
        }
      )

      if (completedResponse) {
        return completedResponse
      }
    }

    if (isAnonymous) {
      const { data: loadedGuestJob, error: existingGuestJobError } = await adminClient
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

      existingGuestJob = loadedGuestJob

      if (
        existingGuestJob?.status === "completed" ||
        existingGuestJob?.status === "acknowledged"
      ) {
        const completedResponse = await loadCompletedGuestGenerationResponseIfNeeded(
          adminClient,
          {
            guestJobID: guestJobID!,
            userID: user.id,
            fallbackCreatedAt: createdAt,
            fallbackRemainingCredits: profile.available_generations,
            generationFormat,
          }
        )

        if (completedResponse) {
          return completedResponse
        }
      }

      if (existingGuestJob?.status === "pending") {
        return jsonResponse(
          {
            error: "生成仍在处理中，请稍后查看回忆。",
            code: "generation_in_progress",
            provider: "generation_job",
          },
          409
        )
      }

      if (existingGuestJob?.status === "failed") {
        return jsonResponse(
          {
            error: "生成失败，请重新生成。",
            code: "generation_failed",
            provider: "generation_job",
          },
          500
        )
      }
    }

    if ((profile.available_generations ?? 0) <= 0) {
      return jsonResponse({ error: "No credits left" }, 403)
    }

    if (isGenerationViolationBanEnabled() && isFutureTimestamp(profile.generation_banned_until)) {
      return jsonResponse(
        {
          error: "当前账号暂时无法生成，请稍后再试。",
          code: "generation_banned",
          bannedUntil: profile.generation_banned_until,
        },
        403
      )
    }

    timing.start("concurrency_slot")
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

    const guestImagePath = isAnonymous ? `${user.id}/guest/${guestJobID}.jpg` : null
    let guestImageUploaded = false
    const requestID = isAnonymous ? guestJobID! : authenticatedClientRequestID
    if (requestID) {
      timing.start("job_claim")
      const { data: claim, error: claimError } = await adminClient.rpc("claim_generation_job", {
        p_user_id: user.id,
        p_request_id: requestID,
        p_is_anonymous: isAnonymous,
        p_image_path: guestImagePath,
      })
      if (claimError) throw new Error(`Generation claim failed: ${claimError.message}`)
      if (claim !== "acquired") {
        if (claim === "completed" || claim === "acknowledged") {
          const completed = isAnonymous
            ? await loadCompletedGuestGenerationResponseIfNeeded(adminClient, {
                guestJobID: requestID, userID: user.id, fallbackCreatedAt: createdAt,
                fallbackRemainingCredits: profile.available_generations, generationFormat,
              })
            : await loadCompletedAuthenticatedGenerationResponseIfNeeded(adminClient, {
                clientRequestID: requestID, userID: user.id,
                fallbackRemainingCredits: profile.available_generations, generationFormat,
              })
          return completed ?? generationPendingResponse()
        }
        if (claim === "pending") return generationPendingResponse()
        if (claim === "failed") return jsonResponse({ error: "生成失败，请重新生成。", code: "generation_failed" }, 500)
        throw new Error("Invalid generation claim response")
      }
      ownsAuthenticatedJob = !isAnonymous
      ownedGuestJobID = isAnonymous ? requestID : null
    }

    if (isAnonymous && guestImagePath) {
      timing.start("guest_image_upload")
      const { error: uploadError } = await adminClient.storage
        .from("memories")
        .upload(guestImagePath, imageBytes, {
          contentType: "image/jpeg",
          upsert: false,
        })

      if (uploadError) {
        await markGuestGenerationJobFailed(cleanupClient, guestJobID!, user.id, `upload image failed: ${uploadError.message}`)

        return jsonResponse(
          {
            error: "upload image failed",
            details: uploadError.message,
          },
          500
        )
      }

      guestImageUploaded = true
    }

    timing.start("moderation")
    const moderationResult = await moderateImageBeforeGeneration({
      userID: user.id,
      imageBase64,
      existingImagePath: isAnonymous ? guestImagePath : null,
      requestID: generationSlotRequestID,
      fetcher: generationFetch,
    })

    if (!moderationResult.allowed) {
      timing.start("error_handling")
      const serializedError = serializeGenerationError({
        code: moderationResult.code,
        statusCode: moderationResult.statusCode,
        internalError: moderationResult.internalError,
      })

      console.error("[generate-memory-v2]", serializedError)

      let violationRecord: GenerationViolationRecord | null = null
      if (isGenerationViolationBanEnabled() && moderationResult.countedViolation) {
        violationRecord = await recordGenerationViolation(adminClient, user.id)
      }

      if (guestJobID) {
        await markGuestGenerationJobFailed(cleanupClient, guestJobID!, user.id, serializedError)
      }

      if (guestImagePath) {
        await removeStoragePathQuietly(adminClient, guestImagePath)
      }

      if (authenticatedClientRequestID) {
        await markAuthenticatedGenerationJobFailed(
          cleanupClient,
          authenticatedClientRequestID,
          user.id,
          serializedError
        )
      }

      return jsonResponse(
        moderationResult.policyViolation
          ? buildGenerationPolicyViolationError(violationRecord)
          : moderationResult.publicError,
        moderationResult.statusCode
      )
    }

    timing.start("prompt")
    // Choose once so model retries and provider fallback keep the same question types.
    const questionTypes = generationFormat === "dual_tabs_v1" ? selectQuestionTypes() : undefined
    const promptText = buildPromptText(englishLevel, generationFormat, questionTypes)

    const completionResult = await requestWithFallback({
      imageBase64,
      promptText,
      mimoBaseURL,
      mimoApiKey,
      kimiBaseURL,
      kimiApiKey,
      deepseek: useDeepSeek ? { apiKey: deepseekApiKey!, baseURL: deepseekBaseURL! } : undefined,
      generationFormat,
      fetcher: generationFetch,
      timing,
    })

    if (!completionResult.ok) {
      timing.start("error_handling")
      const serializedError = serializeGenerationError({
        provider: completionResult.provider,
        code: completionResult.code,
        statusCode: completionResult.statusCode,
        internalError: completionResult.internalError,
      })

      console.error("[generate-memory-v2]", serializedError)

      let violationRecord: GenerationViolationRecord | null = null
      if (isGenerationViolationBanEnabled() && completionResult.policyViolation) {
        violationRecord = await recordGenerationViolation(adminClient, user.id)
      }

      if (guestJobID) {
        await markGuestGenerationJobFailed(cleanupClient, guestJobID!, user.id, serializedError)
      }

      if (guestImageUploaded && guestImagePath) {
        await adminClient.storage.from("memories").remove([guestImagePath])
      }

      if (authenticatedClientRequestID) {
        await markAuthenticatedGenerationJobFailed(
          cleanupClient,
          authenticatedClientRequestID,
          user.id,
          serializedError
        )
      }

      if (completionResult.policyViolation) {
        return jsonResponse(buildGenerationPolicyViolationError(violationRecord), 403)
      }

      return jsonResponse(completionResult.publicError, completionResult.statusCode)
    }

    return await persistGeneratedResult({
      adminClient, cleanupClient, timing, userID: user.id, isAnonymous,
      guestJobID, guestImagePath, guestImageUploaded, createdAt,
      authenticatedClientRequestID, imageBytes, generationFormat, completionResult,
      onFinalizationStarted: (scope) => {
        finalizationStarted = true
        enrichmentScope = scope
      },
    })
  } catch (error) {
    timing.start("error_handling")
    // A transport failure during finalization cannot prove that the DB rolled back.
    if (cleanupClient && generationUserID && !finalizationStarted) {
      const message = error instanceof Error ? error.message : String(error)
      if (ownsAuthenticatedJob && authenticatedClientRequestID) {
        await markAuthenticatedGenerationJobFailed(cleanupClient, authenticatedClientRequestID, generationUserID, message)
      }
      if (ownedGuestJobID) {
        await markGuestGenerationJobFailed(cleanupClient, ownedGuestJobID, generationUserID, message)
      }
    }

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

    if (finalizationStarted || isTimeoutError(error) || Date.now() >= generationDeadline) {
      return generationPendingResponse(true)
    }
    return jsonResponse({ error: "生成失败，请稍后再试" }, 500)
  } finally {
    if (generationSlotAcquired && generationSlotRequestID && adminClient) {
      timing.start("release_slot")
      try {
        await releaseGenerationSlot(cleanupClient ?? adminClient, generationSlotRequestID)
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
    // Finalization queued the indexing payload in the same transaction as the
    // result and debit. Never wait for embeddings before delivering the result.
    // Only this result's first attempt; no automatic repair is scheduled.
    if (enrichmentScope) {
      timing.start("background_dispatch")
      try { scheduleGenerationEnrichment(enrichmentScope, req.headers.get("x-sanju-generation-trace-id") ?? undefined) } catch (error) {
        console.error("[generate-memory-v2] could not start background indexing", String(error))
      }
    }
  }
}
