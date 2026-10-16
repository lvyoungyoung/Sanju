import { ContractError, type MemoryContent } from "../content-contracts/memory.ts"
import { jsonResponse, generationPendingResponse } from "../generate-memory-v2/responses.ts"
import { isDefiniteGenerationRollback, markAuthenticatedGenerationJobFailed, markGuestGenerationJobFailed, removeStoragePathQuietly } from "../generate-memory-v2/repository.ts"
import type { GeneratedSentence } from "./content.ts"
import { contentContext, type PreparedGeneration } from "./spec.ts"

export async function recoverGeneration(client: any, userID: string, requestID: string, anonymous: boolean, fingerprint?: string): Promise<any> {
  const { data, error } = await client.rpc("recover_generation_job_v2", { p_user_id: userID, p_request_id: requestID,
    p_is_anonymous: anonymous, p_request_fingerprint: fingerprint ?? null })
  if (error) {
    if (error.message?.includes("request_context_mismatch")) throw new ContractError("request_context_mismatch", 409)
    throw new Error("Generation recovery unavailable")
  }
  return data
}

export function recoveryResponse(result: any): Response | null {
  if (!result || result.status === "not_found") return null
  if (result.status === "completed" || result.status === "acknowledged") {
    if (!result.memory) return jsonResponse({ code: "generation_result_unavailable", error: "Generation result unavailable" }, 410)
    return jsonResponse(result)
  }
  if (result.status === "failed") return jsonResponse({ code: "generation_failed", error: "Generation failed; start a new request" }, 500)
  return generationPendingResponse()
}

export async function claimGeneration(client: any, prepared: PreparedGeneration, userID: string, anonymous: boolean, imagePath: string | null): Promise<string> {
  const { data, error } = await client.rpc("claim_generation_job_v3", { p_user_id: userID, p_request_id: prepared.requestID,
    p_is_anonymous: anonymous, p_image_path: imagePath, p_generation_spec: prepared.spec, p_request_fingerprint: prepared.fingerprint,
    p_generation_policy: { version: 1, promptVersion: "multilingual-v1", materialPolicyVersion: 1, providerPolicyVersion: 1 } })
  if (error) {
    for (const code of ["request_context_mismatch", "generation_disabled"]) {
      if (error.message?.includes(code)) throw new ContractError(code, code === "generation_disabled" ? 403 : 409)
    }
    throw new Error("Generation claim failed")
  }
  return data
}

export async function persistMultilingualResult(args: {
  client: any; cleanupClient: any; userID: string; anonymous: boolean; prepared: PreparedGeneration;
  guestImagePath: string | null; imageBytes: Uint8Array; createdAt: string;
  completion: { sentences: GeneratedSentence[]; tags: string[]; provider: string };
  onFinalizationStarted: () => void;
}): Promise<Response> {
  const { client, cleanupClient, prepared, userID, anonymous, completion } = args
  const memoryID = anonymous ? prepared.requestID : crypto.randomUUID()
  const imagePath = anonymous ? args.guestImagePath! : `${userID}/${memoryID}.jpg`
  if (!anonymous) {
    const { error } = await client.storage.from("memories").upload(imagePath, args.imageBytes, { contentType: "image/jpeg", upsert: false })
    if (error) throw new Error("Image upload failed")
  }
  const memory: MemoryContent = { schemaVersion: 2, id: memoryID, imagePath, createdAt: args.createdAt,
    tags: completion.tags, context: contentContext(prepared.spec), sentences: completion.sentences }
  args.onFinalizationStarted()
  const { data, error } = await client.rpc("finalize_generation_job_v3", { p_user_id: userID, p_request_id: prepared.requestID,
    p_is_anonymous: anonymous, p_request_fingerprint: prepared.fingerprint, p_memory: memory, p_provider: completion.provider })
  if (error) {
    // A transport error cannot prove rollback. Leave the image and job for recovery.
    if (!isDefiniteGenerationRollback(error)) return generationPendingResponse(true)
    await removeStoragePathQuietly(cleanupClient, imagePath)
    if (anonymous) await markGuestGenerationJobFailed(cleanupClient, prepared.requestID, userID, error.message)
    else await markAuthenticatedGenerationJobFailed(cleanupClient, prepared.requestID, userID, error.message)
    const noCredits = error.message?.includes("No credits left")
    return jsonResponse({ code: noCredits ? "no_credits_left" : "generation_failed", error: "Generation could not be saved" }, noCredits ? 403 : 500)
  }
  return recoveryResponse(data) ?? generationPendingResponse(true)
}
