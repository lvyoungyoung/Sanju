export const EMBEDDING_MODEL = "qwen3.7-text-embedding"
const EMBEDDING_DIMENSIONS = 1024
const EMBEDDING_TIMEOUT_MS = 20_000

export async function createEmbeddings(
  embeddingURL: string,
  embeddingAPIKey: string,
  inputs: string[],
  textType: "query" | "document",
): Promise<number[][]> {
  const controller = new AbortController()
  const timeout = setTimeout(() => controller.abort(), EMBEDDING_TIMEOUT_MS)
  try {
    const response = await fetch(
      embeddingURL,
      {
        method: "POST",
        signal: controller.signal,
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${embeddingAPIKey}`,
        },
        body: JSON.stringify({
          model: EMBEDDING_MODEL,
          input: { texts: inputs },
          parameters: {
            dimension: EMBEDDING_DIMENSIONS,
            output_type: "dense",
            text_type: textType,
          },
        }),
      },
    )
    const rawText = await response.text()
    if (!response.ok) {
      throw new Error(`Embedding request failed: HTTP ${response.status}`)
    }

    let payload: any
    try {
      payload = JSON.parse(rawText)
    } catch {
      throw new Error("Embedding response was not JSON")
    }
    const items = payload?.data ?? payload?.output?.embeddings ?? []
    // Providers may reorder batched results. Honor their indices when present.
    const embeddings: unknown[] = Array(inputs.length)
    if (!Array.isArray(items) || items.length !== inputs.length) throw new Error("Invalid embedding count")
    const seen = new Set<number>()
    for (let i = 0; i < items.length; i++) {
      const index = items[i]?.text_index ?? items[i]?.index ?? i
      if (!Number.isInteger(index) || index < 0 || index >= inputs.length || seen.has(index)) {
        throw new Error("Invalid embedding index")
      }
      seen.add(index)
      embeddings[index] = items[i]?.embedding
    }

    if (embeddings.length !== inputs.length || embeddings.some((item: unknown) => !isEmbedding(item))) {
      throw new Error("Embedding response had an invalid vector")
    }
    return embeddings as number[][]
  } finally {
    clearTimeout(timeout)
  }
}

function isEmbedding(value: unknown): value is number[] {
  return Array.isArray(value) &&
    value.length === EMBEDDING_DIMENSIONS &&
    value.every((item) => typeof item === "number" && Number.isFinite(item)) &&
    value.some((item) => item !== 0)
}
