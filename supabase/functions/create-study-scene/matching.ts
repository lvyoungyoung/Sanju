import { CATEGORY_CATALOG_VERSION, ensureCategoryEmbeddings } from "./categories.ts"
import { EMBEDDING_MODEL, createEmbeddings } from "./embedding.ts"

interface SceneMatchingRequest {
  adminClient: any
  userID: string
  name: string
  sceneID?: string
  preparing: boolean
  embeddingAPIKey: string
  embeddingURL: string
}

interface SceneMatchingResult {
  data: unknown
  error: { code?: string; message: string; details?: string; hint?: string } | null
}

export async function matchStudyScene(request: SceneMatchingRequest): Promise<SceneMatchingResult> {
  const { adminClient, userID, name, sceneID, preparing, embeddingAPIKey, embeddingURL } = request
  // Recommended names and typed names use the same raw-name query vector.
  // Category vectors are shared, cached documents, not per-user model calls.
  await ensureCategoryEmbeddings({
    read: async () => {
      const result = await adminClient.from("learning_topic_embeddings")
        .select("topic_id,embedding").eq("model", EMBEDDING_MODEL)
        .eq("catalog_version", CATEGORY_CATALOG_VERSION)
      if (result.error) throw result.error
      return result.data ?? []
    },
    write: async (rows) => {
      const result = await adminClient.from("learning_topic_embeddings").upsert(
        rows.map((row) => ({ ...row, model: EMBEDDING_MODEL, catalog_version: CATEGORY_CATALOG_VERSION })),
        { onConflict: "topic_id,model,catalog_version" },
      )
      if (result.error) throw result.error
    },
  }, (texts) => createEmbeddings(embeddingURL, embeddingAPIKey, texts, "document"))

  let needsQueryVector = true
  if (preparing) {
    const existing = await adminClient.from("study_scene_embeddings").select("scene_id,search_description")
      .eq("scene_id", sceneID!).eq("user_id", userID).eq("model", EMBEDDING_MODEL).maybeSingle()
    if (existing.error) throw existing.error
    needsQueryVector = !existing.data || Boolean(existing.data.search_description?.trim())
  }
  const sceneEmbedding = needsQueryVector
    ? (await createEmbeddings(embeddingURL, embeddingAPIKey, [name], "query"))[0] : null
  if (preparing) {
    return await adminClient.rpc("prepare_study_scene_matching", {
      p_user_id: userID, p_scene_id: sceneID, p_embedding: sceneEmbedding, p_model: EMBEDDING_MODEL,
    })
  }
  return await adminClient.rpc("create_study_scene_with_embedding", {
    p_user_id: userID,
    p_name: name,
    p_embedding: sceneEmbedding,
    p_model: EMBEDDING_MODEL,
  })
}
