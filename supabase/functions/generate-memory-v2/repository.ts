import { type Sentence, type GenerationFormat, type ProviderName, hasSupportedStoredSentenceCount, toClientSentences } from "./content.ts"
import { serializeGenerationError, truncateDiagnosticText, jsonResponse, generationPendingResponse } from "./responses.ts"

const GENERATION_CONCURRENCY_LIMIT = 50
const GENERATION_SLOT_TTL_SECONDS = 180

export async function finalizeAuthenticatedGeneration(
  adminClient: any,
  args: {
    memoryID: string
    userID: string
    clientRequestID: string | null
    imagePath: string
    createdAt: string
    provider: ProviderName
    sentences: Sentence[]
    tags: string[]
  }
): Promise<
  | { ok: true; remainingCredits: number }
  | {
      ok: false
      code?: string
      outcomeUnknown?: boolean
      statusCode: number
      internalError: string
      publicError: Record<string, unknown>
    }
> {
  const { data, error } = await adminClient.rpc("finalize_authenticated_generation", {
    p_memory_id: args.memoryID,
    p_user_id: args.userID,
    p_client_request_id: args.clientRequestID,
    p_image_path: args.imagePath,
    p_created_at: args.createdAt,
    p_provider: args.provider,
    p_sentences: args.sentences,
    p_tags: args.tags,
  })

  if (error) {
    return { ...buildRpcErrorResponse(error, "Authenticated finalize failed"), outcomeUnknown: !/^[0-9A-Z]{5}$/.test(error.code ?? "") }
  }

  return {
    ok: true,
    remainingCredits: normalizeRPCInteger(data),
  }
}

export async function finalizeGuestGeneration(
  adminClient: any,
  args: {
    guestJobID: string
    userID: string
    createdAt: string
    provider: ProviderName
    sentences: Sentence[]
    tags: string[]
  }
): Promise<
  | { ok: true; remainingCredits: number }
  | {
      ok: false
      code?: string
      outcomeUnknown?: boolean
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
    p_tags: args.tags,
  })

  if (error) {
    return { ...buildRpcErrorResponse(error, "Guest finalize failed"), outcomeUnknown: !/^[0-9A-Z]{5}$/.test(error.code ?? "") }
  }

  return {
    ok: true,
    remainingCredits: normalizeRPCInteger(data),
  }
}

export async function updateMemoryGenerationDiagnostics(
  adminClient: any,
  args: {
    memoryID: string
    userID: string
    provider: ProviderName
    mimoFailureReason: string | null
  }
): Promise<void> {
  try {
    const { error } = await adminClient
      .from("memories")
      .update({
        provider: args.provider,
        mimo_failure_reason: args.mimoFailureReason,
      })
      .eq("id", args.memoryID)
      .eq("user_id", args.userID)

    if (error) {
      throw error
    }
  } catch (error) {
    console.error(
      "[generate-memory-v2]",
      serializeGenerationError({
        provider: args.provider,
        code: "generation_diagnostics_update_failed",
        statusCode: 500,
        internalError: error instanceof Error ? error.message : String(error),
      })
    )
  }
}

export async function updateGuestGenerationDiagnostics(
  adminClient: any,
  args: {
    guestJobID: string
    provider: ProviderName
    mimoFailureReason: string | null
  }
): Promise<void> {
  try {
    const { error } = await adminClient
      .from("guest_generation_jobs")
      .update({
        provider: args.provider,
        mimo_failure_reason: args.mimoFailureReason,
      })
      .eq("id", args.guestJobID)

    if (error) {
      throw error
    }
  } catch (error) {
    console.error(
      "[generate-memory-v2]",
      serializeGenerationError({
        provider: args.provider,
        code: "guest_generation_diagnostics_update_failed",
        statusCode: 500,
        internalError: error instanceof Error ? error.message : String(error),
      })
    )
  }
}

export async function loadCompletedAuthenticatedGenerationResponseIfNeeded(
  adminClient: any,
  args: {
    clientRequestID: string
    userID: string
    fallbackRemainingCredits: number
    generationFormat: GenerationFormat
  }
): Promise<Response | null> {
  const { data: job, error: jobError } = await adminClient
    .from("generation_jobs")
    .select("status, memory_id, remaining_credits")
    .eq("client_request_id", args.clientRequestID)
    .eq("user_id", args.userID)
    .maybeSingle()

  if (jobError) {
    console.error("[generate-memory-v2] generation lookup failed", jobError.message)
    return generationPendingResponse(true)
  }
  if (job?.status !== "completed") return null
  if (!job.memory_id) return jsonResponse({ error: "生成结果已不可用。", code: "generation_result_unavailable" }, 410)

  const { data: memory, error: memoryError } = await adminClient
    .from("memories")
    .select(
      `
      id,
      image_url,
      created_at,
      provider,
      tags,
      memory_sentences (
        id,
        english,
        chinese,
        learning_topic_ids,
        presentation_group,
        is_favorite,
        sort_order
      )
    `
    )
    .eq("id", job.memory_id)
    .eq("user_id", args.userID)
    .maybeSingle()

  if (memoryError) return generationPendingResponse(true)
  if (!memory) return jsonResponse({ error: "生成结果已不可用。", code: "generation_result_unavailable" }, 410)

  const sentences = Array.isArray(memory.memory_sentences)
    ? [...memory.memory_sentences].sort(
        (left: any, right: any) => (left.sort_order ?? 0) - (right.sort_order ?? 0)
      )
    : []

  if (!hasSupportedStoredSentenceCount(sentences.length, args.generationFormat)) {
    return generationPendingResponse(true)
  }

  return jsonResponse({
    memory: {
      id: memory.id,
      imagePath: memory.image_url ?? "",
      createdAt: memory.created_at,
      provider: memory.provider ?? null,
      tags: Array.isArray(memory.tags) ? memory.tags : [],
      sentences: toClientSentences(sentences, args.generationFormat),
    },
    remainingCredits: job.remaining_credits ?? args.fallbackRemainingCredits,
    clientRequestID: args.clientRequestID,
  })
}

export async function loadCompletedGuestGenerationResponseIfNeeded(
  adminClient: any,
  args: {
    guestJobID: string
    userID: string
    fallbackCreatedAt: string
    fallbackRemainingCredits: number
    generationFormat: GenerationFormat
  }
): Promise<Response | null> {
  const { data: completedJob, error: completedJobError } = await adminClient
    .from("guest_generation_jobs")
    .select("id, created_at, remaining_credits, sentences, provider, tags")
    .eq("id", args.guestJobID)
    .eq("user_id", args.userID)
    .maybeSingle()

  if (completedJobError) {
    console.error("[generate-memory-v2] completed guest lookup failed", completedJobError.message)
    return generationPendingResponse(true)
  }

  const sentences = Array.isArray(completedJob?.sentences) ? completedJob.sentences : []
  if (!hasSupportedStoredSentenceCount(sentences.length, args.generationFormat)) {
    return generationPendingResponse(true)
  }

  return jsonResponse({
    memory: {
      id: completedJob.id,
      imagePath: "",
      createdAt: completedJob?.created_at ?? args.fallbackCreatedAt,
      provider: completedJob?.provider ?? null,
      tags: Array.isArray(completedJob?.tags) ? completedJob.tags : [],
      sentences: toClientSentences(sentences, args.generationFormat),
    },
    remainingCredits: completedJob?.remaining_credits ?? args.fallbackRemainingCredits,
    guestJobID: args.guestJobID,
  })
}
export async function updateAuthenticatedGenerationDiagnostics(
  adminClient: any,
  args: { clientRequestID: string; userID: string; memoryID: string; mimoFailureReason: string | null }
): Promise<void> {
  try {
    const { error } = await adminClient.from("generation_jobs")
      .update({ mimo_failure_reason: args.mimoFailureReason })
      .eq("client_request_id", args.clientRequestID)
      .eq("user_id", args.userID)
      .eq("memory_id", args.memoryID)
      .eq("status", "completed")
    if (error) throw error
  } catch (error) {
    console.error("[generate-memory-v2] job diagnostics failed", String(error))
  }
}

export async function markAuthenticatedGenerationJobFailed(
  adminClient: any,
  clientRequestID: string,
  userID: string,
  errorMessage: string
): Promise<void> {
  try {
    const now = new Date().toISOString()
    const { error } = await adminClient
      .from("generation_jobs")
      .update({
        status: "failed",
        error_message: truncateDiagnosticText(errorMessage, 1000),
        updated_at: now,
        failed_at: now,
      })
      .eq("client_request_id", clientRequestID)
      .eq("user_id", userID)
      .eq("status", "pending")

    if (error) {
      throw error
    }
  } catch (error) {
    console.error(
      "[generate-memory-v2]",
      serializeGenerationError({
        code: "authenticated_generation_job_fail_update_failed",
        statusCode: 500,
        internalError: error instanceof Error ? error.message : String(error),
      })
    )
  }
}

export async function tryAcquireGenerationSlot(
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

export async function releaseGenerationSlot(adminClient: any, requestID: string): Promise<void> {
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
export async function removeStoragePathQuietly(adminClient: any, path: string): Promise<void> {
  try {
    await adminClient.storage.from("memories").remove([path])
  } catch (error) {
    console.error(
      "[generate-memory-v2]",
      serializeGenerationError({
        code: "storage_cleanup_failed",
        statusCode: 500,
        internalError: error instanceof Error ? error.message : String(error),
      })
    )
  }
}
export async function markGuestGenerationJobFailed(adminClient: any, jobID: string, userID: string, message: string): Promise<void> {
  try {
    const { error } = await adminClient.from("guest_generation_jobs")
      .update({ status: "failed", error_message: truncateDiagnosticText(message, 1000) })
      .eq("id", jobID).eq("user_id", userID).eq("status", "pending")
    if (error) throw error
  } catch (error) {
    console.error("[generate-memory-v2] guest failure update failed", String(error))
  }
}
