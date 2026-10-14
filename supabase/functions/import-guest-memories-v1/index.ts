import { authenticatedContentRequest } from "../_shared/generation/http.ts"
import { ContractError, record, uuid, validateSentence, type MemoryContent } from "../_shared/content-contracts/memory.ts"
import { validateGenerationSpec, contentContext } from "../_shared/generation/spec.ts"
import { SCENE_CATEGORY_IDS } from "../_shared/scene-categories.ts"
import { jsonResponse } from "../generate-memory-v2/responses.ts"

Deno.serve(req => authenticatedContentRequest(req, async ({body, user, client, authClient}) => {
  if (user.is_anonymous === true) throw new ContractError("account_required", 403)
  if (!Array.isArray(body.memories) || body.memories.length < 1 || body.memories.length > 25) throw new ContractError("invalid_import")
  let guestUserID: string | null = null
  if (body.guestAccessToken !== undefined) {
    if (typeof body.guestAccessToken !== "string") throw new ContractError("invalid_guest_proof", 403)
    const {data: {user: guest}, error} = await authClient.auth.getUser(body.guestAccessToken)
    if (error || !guest || guest.is_anonymous !== true) throw new ContractError("invalid_guest_proof", 403)
    guestUserID = guest.id
  }
  // Validate the entire envelope before making any per-memory transaction.
  const memories: MemoryContent[] = []
  for (const item of body.memories) {
    const m = record(item)
    const c = record(m.context)
    if (m.schemaVersion !== 2 || c.schemaVersion !== 2 || !Array.isArray(m.sentences) || ![3,6].includes(m.sentences.length) ||
        !Array.isArray(m.tags) || m.tags.length > 3 || m.tags.some((id: string) => !SCENE_CATEGORY_IDS.has(id)) ||
        typeof m.createdAt !== "string" || !Number.isFinite(Date.parse(m.createdAt))) throw new ContractError("invalid_import")
    const context = contentContext(validateGenerationSpec({ ...c, schemaVersion: 1, catalogVersion: 1, level: "intermediate", generationFormat: "dual_tabs_v1" }))
    const id = uuid(m.id)
    if (m.imagePath !== "" && m.imagePath !== `${user.id}/${id}.jpg`) throw new ContractError("invalid_image_path")
    const sentences = []
    for (const s of m.sentences) sentences.push(await validateSentence(s, context))
    if (new Set(sentences.map(s => s.id)).size !== sentences.length) throw new ContractError("duplicate_sentence_id")
    memories.push({schemaVersion: 2, id, imagePath: m.imagePath, createdAt: m.createdAt, tags: m.tags, context, sentences})
  }
  if (new Set(memories.map(m => m.id)).size !== memories.length) throw new ContractError("duplicate_memory_id")
  const results = []
  for (const memory of memories) {
    const {data, error} = await client.rpc("import_guest_memory_v1", { p_user_id: user.id, p_guest_user_id: guestUserID, p_memory: memory })
    results.push(error ? { id: memory.id, imported: false, code: error.message?.includes("content_conflict") ? "content_conflict" : "import_failed" } : data)
  }
  return jsonResponse({ schemaVersion: 1, results })
}))
