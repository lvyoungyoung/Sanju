import { createClient } from "npm:@supabase/supabase-js@2"
import { fetchWithinDeadline, fetchWithTimeout } from "./fetch-with-timeout.ts"
import { generateSentenceMetadata, parseSentenceMetadata } from "./sentence-metadata.ts"

export interface IndexableSentence {
  id: string
  english: string
  chinese: string
  expression_purpose?: string
  learning_topic_ids?: string[]
}

// A separate deadline/client is essential: returning the generation response
// must not cancel indexing or leave it using the generation's exhausted budget.
export function scheduleGenerationEnrichment(userID: string): void {
  const runtime = (globalThis as typeof globalThis & {
    EdgeRuntime?: { waitUntil: (task: Promise<unknown>) => void }
  }).EdgeRuntime
  if (!runtime?.waitUntil) {
    console.warn("[generation-enrichment] background runtime unavailable; durable jobs await worker")
    return
  }
  const task = Promise.resolve().then(() => runGenerationEnrichment(userID)).catch((error) => {
    console.error("[generation-enrichment] background worker failed", error instanceof Error ? error.message : String(error))
  })
  runtime.waitUntil(task)
}

export async function runGenerationEnrichment(userID: string | null = null) {
  const url = Deno.env.get("SUPABASE_LOCAL_URL") ?? Deno.env.get("SUPABASE_URL")
  const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")
  if (!url || !key) throw new Error("Missing server configuration")
  const deadline = Date.now() + 45_000
  const fetcher = fetchWithinDeadline(deadline)
  const client = createClient(url, key, { global: { fetch: fetcher } })
  return await processGenerationEnrichment(client, userID, fetcher, deadline)
}

// Claim only one batch at a time; leases allow a later worker to resume after
// process termination. Finishing persists vectors, matches and completion atomically.
export async function processGenerationEnrichment(
  client: any, userID: string | null, fetcher: typeof fetch, deadline = Date.now() + 45_000,
) {
  let completed = 0
  let failed = 0
  for (let batch = 0; batch < 3 && Date.now() < deadline - 32_000; batch++) {
    const claim = await client.rpc("claim_generation_enrichment", { p_user_id: userID })
    if (claim.error) throw new Error(`Index claim failed: ${claim.error.message}`)
    const job = claim.data?.[0]
    if (!job) break
    try {
      const metadata = job.metadata != null
        ? parseSentenceMetadata(job.metadata, job.sentences)
        : await generateSentenceMetadata(job.sentences, fetcher)
      if (job.metadata == null) {
        // Checkpoint before embedding so a vector retry does not repeat the AI call.
        const saved = await client.rpc("save_generation_enrichment_metadata", {
          p_job_id: job.id, p_lease_token: job.lease_token, p_metadata: metadata,
        })
        if (saved.error) throw new Error(`Metadata checkpoint failed: ${saved.error.message}`)
        if (saved.data !== true) continue
      }
      const enriched = job.sentences.map((sentence: IndexableSentence, index: number) => ({
        ...sentence,
        expression_purpose: metadata[index].expression_purpose,
        learning_topic_ids: metadata[index].learning_topic_ids,
      }))
      const rows = await buildSentenceEmbeddingRows(enriched, fetcher)
      // Both vectors must be complete before publishing metadata and topic matches.
      if (rows.some((row) => !row.embedding || (row.expression_purpose && !row.purpose_embedding))) {
        throw new Error("Incomplete sentence embeddings")
      }
      const result = await client.rpc("complete_generation_enrichment", {
        p_job_id: job.id, p_lease_token: job.lease_token, p_rows: rows,
      })
      if (result.error) throw new Error(`Index completion failed: ${result.error.message}`)
      if (result.data === true) completed++
    } catch (error) {
      failed++
      const message = error instanceof Error ? error.message : String(error)
      console.error("[generation-enrichment] retry scheduled", JSON.stringify({ jobID: job.id, attempt: job.attempts, error: message }))
      const retry = await client.rpc("retry_generation_enrichment", {
        p_job_id: job.id, p_lease_token: job.lease_token, p_error: message.slice(0, 500),
      })
      if (retry.error) throw new Error(`Index retry update failed: ${retry.error.message}`)
    }
  }
  return { completed, failed }
}

export async function buildSentenceEmbeddingRows(sentences: IndexableSentence[], fetcher: typeof fetch) {
  const purposes = sentences.flatMap((sentence, index) => {
    const text = normalizeExpressionPurpose(sentence.expression_purpose)
    return text ? [{ index, text }] : []
  })
  if (purposes.length !== sentences.length) {
    console.warn("[generation-enrichment] missing expression purposes", sentences.length - purposes.length)
  }
  // Independent requests: one provider failure must not discard the other route.
  const [original, purpose] = await Promise.allSettled([
    fetchSentenceEmbeddings(sentences.map((sentence) => `English: ${sentence.english}\nChinese: ${sentence.chinese}`), fetcher),
    purposes.length ? fetchSentenceEmbeddings(purposes.map((item) => item.text), fetcher) : Promise.resolve([]),
  ])
  for (const [route, result] of [["sentence", original], ["purpose", purpose]] as const) {
    if (result.status === "rejected") {
      console.error(`[generation-enrichment] ${route} embedding failed`, result.reason instanceof Error ? result.reason.message : String(result.reason))
    }
  }
  const purposeVectors = new Map(purposes.map((item, i) => [item.index, purpose.status === "fulfilled" ? purpose.value[i] : null]))
  return sentences.map((sentence, index) => ({
    sentence_id: sentence.id,
    embedding: original.status === "fulfilled" ? original.value[index] : null,
    expression_purpose: normalizeExpressionPurpose(sentence.expression_purpose) ?? null,
    purpose_embedding: purposeVectors.get(index) ?? null,
    model: "qwen3.7-text-embedding",
    updated_at: new Date().toISOString(),
  }))
}

async function fetchSentenceEmbeddings(texts: string[], fetcher: typeof fetch): Promise<number[][]> {
  const apiKey = Deno.env.get("DASHSCOPE_API_KEY")
  const embeddingURL = Deno.env.get("DASHSCOPE_EMBEDDING_URL")
  if (!apiKey || !embeddingURL) {
    throw new Error("Missing DashScope embedding configuration")
  }

  const response = await fetchWithTimeout(
    embeddingURL,
    {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${apiKey}`,
      },
      body: JSON.stringify({
        model: "qwen3.7-text-embedding",
        input: {
          texts,
        },
        parameters: {
          dimension: 1024,
          output_type: "dense",
          text_type: "document",
        },
      }),
    },
    8_000,
    fetcher
  )
  const rawText = await response.text()
  if (!response.ok) {
    throw new Error(`Embedding request failed: HTTP ${response.status}`)
  }

  const payload = JSON.parse(rawText)
  const items = payload?.data ?? payload?.output?.embeddings
  if (!Array.isArray(items) || items.length !== texts.length) throw new Error("Invalid embedding count")
  const embeddings: unknown[] = Array(texts.length)
  const seen = new Set<number>()
  for (let i = 0; i < items.length; i++) {
    const index = items[i]?.text_index ?? items[i]?.index ?? i
    if (!Number.isInteger(index) || index < 0 || index >= texts.length || seen.has(index)) throw new Error("Invalid embedding index")
    seen.add(index)
    embeddings[index] = items[i]?.embedding
  }

  if (
    embeddings.length !== texts.length ||
    embeddings.some(
      (embedding: unknown) =>
        !Array.isArray(embedding) ||
        embedding.length !== 1024 ||
        !embedding.every((value) => typeof value === "number" && Number.isFinite(value)) ||
        !embedding.some((value) => value !== 0)
    )
  ) {
    throw new Error("Embedding response had an invalid vector")
  }

  return embeddings as number[][]
}

function normalizeExpressionPurpose(value: unknown): string | undefined {
  if (typeof value !== "string") return undefined
  const purpose = value.trim().replace(/\s+/g, " ")
  return purpose.length > 0 && purpose.length <= 240 && purpose.split(" ").length <= 30 ? purpose : undefined
}
