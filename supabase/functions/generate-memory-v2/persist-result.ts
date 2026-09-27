import type { EnrichmentScope } from "../_shared/generation-enrichment.ts"
import type { GenerationTiming } from "../_shared/generation-timing.ts"
import { type GenerationFormat, type FinalizedSentence, toClientSentences } from "./content.ts"
import { serializeGenerationError, jsonResponse, generationPendingResponse } from "./responses.ts"
import type { requestWithFallback } from "./providers.ts"
import { finalizeAuthenticatedGeneration, finalizeGuestGeneration, updateMemoryGenerationDiagnostics, updateGuestGenerationDiagnostics, loadCompletedAuthenticatedGenerationResponseIfNeeded, loadCompletedGuestGenerationResponseIfNeeded, updateAuthenticatedGenerationDiagnostics, markAuthenticatedGenerationJobFailed, markGuestGenerationJobFailed } from "./repository.ts"

interface PersistGeneratedResultContext {
  adminClient: any
  cleanupClient: any
  timing: GenerationTiming
  userID: string
  isAnonymous: boolean
  guestJobID: string | undefined
  guestImagePath: string | null
  guestImageUploaded: boolean
  createdAt: string
  authenticatedClientRequestID: string | null
  imageBytes: Uint8Array
  generationFormat: GenerationFormat
  completionResult: Extract<Awaited<ReturnType<typeof requestWithFallback>>, { ok: true }>
  onFinalizationStarted: (scope: EnrichmentScope) => void
}

// Keep the finalization marker in the request owner: a transport error after
// this point does not prove the transaction failed, so recovery must stay open.
export async function persistGeneratedResult(context: PersistGeneratedResultContext): Promise<Response> {
  const { adminClient, cleanupClient, timing, userID, isAnonymous, guestJobID,
    guestImagePath, guestImageUploaded, createdAt, authenticatedClientRequestID,
    imageBytes, generationFormat, completionResult, onFinalizationStarted } = context
  timing.start("result_prepare")
  const { sentences, provider, mimoFailureReason } = completionResult
  const finalizedSentences: FinalizedSentence[] = sentences.map((sentence) => ({
    id: crypto.randomUUID(),
    english: sentence.english,
    chinese: sentence.chinese,
    learning_topic_ids: sentence.learning_topic_ids,
    expression_purpose: sentence.expression_purpose,
    presentation_group: sentence.presentation_group ?? "what_i_see",
    is_favorite: false,
  }))

  if (isAnonymous) {
    timing.start("finalize")
    onFinalizationStarted({ userID: userID, guestJobID: guestJobID! })
    const finalizeResult = await finalizeGuestGeneration(adminClient, {
      guestJobID: guestJobID!,
      userID: userID,
      createdAt,
      provider,
      sentences: finalizedSentences,
    })

    if (!finalizeResult.ok) {
      timing.start("error_handling")
      if (finalizeResult.outcomeUnknown) return generationPendingResponse(true)
      const serializedError = serializeGenerationError({
        provider,
        code: finalizeResult.code,
        statusCode: finalizeResult.statusCode,
        internalError: finalizeResult.internalError,
      })

      console.error("[generate-memory-v2]", serializedError)

      await markGuestGenerationJobFailed(cleanupClient, guestJobID!, userID, serializedError)

      if (guestImageUploaded && guestImagePath) {
        await adminClient.storage.from("memories").remove([guestImagePath])
      }

      return jsonResponse(finalizeResult.publicError, finalizeResult.statusCode)
    }

    timing.start("diagnostics")
    await updateGuestGenerationDiagnostics(adminClient, {
      guestJobID: guestJobID!,
      provider,
      mimoFailureReason,
    })

    timing.start("read_result")
    return await loadCompletedGuestGenerationResponseIfNeeded(adminClient, {
      guestJobID: guestJobID!, userID: userID, fallbackCreatedAt: createdAt,
      fallbackRemainingCredits: finalizeResult.remainingCredits, generationFormat,
    }) ?? generationPendingResponse(true)
  }

  const memoryID = crypto.randomUUID()
  const imagePath = `${userID}/${crypto.randomUUID().toLowerCase()}.jpg`

  timing.start("image_upload")
  const { error: uploadError } = await adminClient.storage
    .from("memories")
    .upload(imagePath, imageBytes, {
      contentType: "image/jpeg",
      upsert: false,
    })

  if (uploadError) {
    timing.start("error_handling")
    if (authenticatedClientRequestID) {
      await markAuthenticatedGenerationJobFailed(
        cleanupClient,
        authenticatedClientRequestID,
        userID,
        `upload image failed: ${uploadError.message}`
      )
    }

    return jsonResponse(
      {
        error: "upload image failed",
        details: uploadError.message,
      },
      500
    )
  }

  timing.start("finalize")
  onFinalizationStarted({ userID: userID, memoryID })
  const finalizeResult = await finalizeAuthenticatedGeneration(adminClient, {
    memoryID,
    userID: userID,
    clientRequestID: authenticatedClientRequestID,
    imagePath,
    createdAt,
    provider,
    sentences: finalizedSentences,
  })

  if (!finalizeResult.ok) {
    timing.start("error_handling")
    if (finalizeResult.outcomeUnknown) return generationPendingResponse(true)
    const serializedError = serializeGenerationError({
      provider,
      code: finalizeResult.code,
      statusCode: finalizeResult.statusCode,
      internalError: finalizeResult.internalError,
    })

    console.error("[generate-memory-v2]", serializedError)
    await adminClient.storage.from("memories").remove([imagePath])

    if (authenticatedClientRequestID) {
      await markAuthenticatedGenerationJobFailed(
        cleanupClient,
        authenticatedClientRequestID,
        userID,
        serializedError
      )
    }

    return jsonResponse(finalizeResult.publicError, finalizeResult.statusCode)
  }

  timing.start("diagnostics")
  await updateMemoryGenerationDiagnostics(adminClient, {
    memoryID,
    userID: userID,
    provider,
    mimoFailureReason,
  })

  if (authenticatedClientRequestID) {
    await updateAuthenticatedGenerationDiagnostics(adminClient, {
      clientRequestID: authenticatedClientRequestID,
      userID: userID,
      memoryID,
      mimoFailureReason,
    })
    // The transaction owns the canonical memory ID and response, not this worker.
    timing.start("read_result")
    return await loadCompletedAuthenticatedGenerationResponseIfNeeded(adminClient, {
      clientRequestID: authenticatedClientRequestID, userID: userID,
      fallbackRemainingCredits: finalizeResult.remainingCredits, generationFormat,
    }) ?? generationPendingResponse(true)
  }

  return jsonResponse({
    memory: {
      id: memoryID,
      imagePath,
      createdAt,
      provider,
      tags: [],
      sentences: toClientSentences(finalizedSentences, generationFormat),
    },
    remainingCredits: finalizeResult.remainingCredits,
    clientRequestID: authenticatedClientRequestID,
  })
}
