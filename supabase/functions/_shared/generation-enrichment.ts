import { createClient } from "npm:@supabase/supabase-js@2"
import { fetchWithinDeadline, fetchWithTimeout } from "./fetch-with-timeout.ts"
import { generateSentenceMetadata, parseSentenceMetadata } from "./sentence-metadata.ts"
import { type EnrichmentStage, EnrichmentTiming } from "./generation-enrichment-timing.ts"

export interface IndexableSentence {
  id: string
  english: string
  chinese: string
  expression_purpose?: string
  learning_topic_ids?: string[]
}

export type EnrichmentScope =
  & { userID: string }
  & (
    | { memoryID: string; guestJobID?: never; sceneID?: never }
    | { guestJobID: string; memoryID?: never; sceneID?: never }
    | { sceneID: string; memoryID?: never; guestJobID?: never }
  )

// A separate deadline/client is essential: returning the generation response
// must not cancel indexing or leave it using the generation's exhausted budget.
export function scheduleGenerationEnrichment(scope: EnrichmentScope, requestID?: string): void {
  const runtime = (globalThis as typeof globalThis & {
    EdgeRuntime?: { waitUntil: (task: Promise<unknown>) => void }
  }).EdgeRuntime
  if (!runtime?.waitUntil) {
    console.warn("[generation-enrichment] background runtime unavailable; missing work awaits topic creation")
    return
  }
  const task = Promise.resolve().then(() => runGenerationEnrichment(scope, requestID)).catch((error) => {
    console.error("[generation-enrichment] background worker failed", error instanceof Error ? error.message : String(error))
  })
  runtime.waitUntil(task)
}

async function runGenerationEnrichment(scope: EnrichmentScope, requestID?: string) {
  const url = Deno.env.get("SUPABASE_LOCAL_URL") ?? Deno.env.get("SUPABASE_URL")
  const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")
  if (!url || !key) throw new Error("Missing server configuration")
  const deadline = Date.now() + 45_000
  const fetcher = fetchWithinDeadline(deadline)
  const client = createClient(url, key, { global: { fetch: fetcher } })
  const timing = new EnrichmentTiming({ ...scope, requestID, runID: crypto.randomUUID() })
  return await processGenerationEnrichment(client, scope, fetcher, deadline, timing)
}

// Claim only one batch at a time; leases allow a later worker to resume after
// process termination. Finishing persists vectors, matches and completion atomically.
export async function processGenerationEnrichment(
  client: any,
  scope: EnrichmentScope,
  fetcher: typeof fetch,
  deadline = Date.now() + 45_000,
  timing = new EnrichmentTiming({ ...scope, runID: crypto.randomUUID() }),
) {
  let completed = 0
  let failed = 0
  let endedNormally = false
  const batchLimit = scope.sceneID ? 3 : 1
  try {
    for (let batch = 0; batch < batchLimit && Date.now() < deadline - 32_000; batch++) {
      const claim = await timing.measure("claim", async () => {
        const result = await client.rpc("claim_scoped_generation_enrichment", {
          p_user_id: scope.userID,
          p_memory_id: scope.memoryID ?? null,
          p_guest_job_id: scope.guestJobID ?? null,
          p_scene_id: scope.sceneID ?? null,
        })
        if (result.error) throw new Error(`Index claim failed: ${result.error.message}`)
        return result
      })
      const job = claim.data?.[0]
      if (!job) break
      const jobTiming = timing.forJob(job.id, job.attempts)
      let jobOutcome: "completed" | "failed" | "lease_lost" = "failed"
      try {
        const metadata = await jobTiming.measure(
          job.metadata != null ? "metadata_reuse" : "metadata_generate",
          async () =>
            job.metadata != null
              ? parseSentenceMetadata(job.metadata, job.sentences)
              : await generateSentenceMetadata(job.sentences, fetcher),
        )
        if (job.metadata == null) {
          // Checkpoint before embedding so a vector retry does not repeat the AI call.
          const saved = await jobTiming.measure("metadata_checkpoint", async () => {
            const result = await client.rpc("save_generation_enrichment_metadata", {
              p_job_id: job.id,
              p_lease_token: job.lease_token,
              p_metadata: metadata,
            })
            if (result.error) throw new Error(`Metadata checkpoint failed: ${result.error.message}`)
            return result
          })
          if (saved.data !== true) {
            jobOutcome = "lease_lost"
            continue
          }
        }
        const enriched = job.sentences.map((sentence: IndexableSentence, index: number) => ({
          ...sentence,
          expression_purpose: metadata[index].expression_purpose,
          learning_topic_ids: metadata[index].learning_topic_ids,
        }))
        const rows = await jobTiming.measure("embeddings_parallel", async () => {
          const rows = await buildSentenceEmbeddingRows(enriched, fetcher, jobTiming)
          // Both vectors must be complete before publishing metadata and topic matches.
          if (rows.some((row) => !row.embedding || (row.expression_purpose && !row.purpose_embedding))) {
            throw new Error("Incomplete sentence embeddings")
          }
          return rows
        })
        const result = await jobTiming.measure("publish_and_match", async () => {
          const result = await client.rpc("complete_generation_enrichment", {
            p_job_id: job.id,
            p_lease_token: job.lease_token,
            p_rows: rows,
          })
          if (result.error) throw new Error(`Index completion failed: ${result.error.message}`)
          return result
        })
        if (result.data === true) completed++
        jobOutcome = result.data === true ? "completed" : "lease_lost"
      } catch (error) {
        failed++
        const message = error instanceof Error ? error.message : String(error)
        console.error("[generation-enrichment] retry scheduled", JSON.stringify({ jobID: job.id, attempt: job.attempts, error: message }))
        await jobTiming.measure("retry_state", async () => {
          const retry = await client.rpc("retry_generation_enrichment", {
            p_job_id: job.id,
            p_lease_token: job.lease_token,
            p_error: message.slice(0, 500),
          })
          if (retry.error) throw new Error(`Index retry update failed: ${retry.error.message}`)
        })
      } finally {
        jobTiming.finish(jobOutcome)
        if (jobTiming.enabled) {
          try {
            const saved = await client.rpc("save_generation_enrichment_timing", {
              p_job_id: job.id,
              p_attempt: job.attempts,
              p_report: jobTiming.report(),
            })
            if (saved.error) console.warn("[GenerationTiming] enrichment timing persistence unavailable")
          } catch {
            console.warn("[GenerationTiming] enrichment timing persistence unavailable")
          }
        }
      }
    }
    endedNormally = true
    return { completed, failed }
  } finally {
    timing.finish(!endedNormally ? "failed" : failed ? "partial_failure" : completed ? "completed" : "no_work")
  }
}

export async function buildSentenceEmbeddingRows(sentences: IndexableSentence[], fetcher: typeof fetch, timing?: EnrichmentTiming) {
  const purposes = sentences.flatMap((sentence, index) => {
    const text = normalizeExpressionPurpose(sentence.expression_purpose)
    return text ? [{ index, text }] : []
  })
  if (purposes.length !== sentences.length) {
    console.warn("[generation-enrichment] missing expression purposes", sentences.length - purposes.length)
  }
  // Independent requests: one provider failure must not discard the other route.
  const measure = <T>(stage: EnrichmentStage, operation: () => Promise<T>) => timing ? timing.measure(stage, operation) : operation()
  const [original, purpose] = await Promise.allSettled([
    measure(
      "sentence_embedding",
      () => fetchSentenceEmbeddings(sentences.map((sentence) => `English: ${sentence.english}\nChinese: ${sentence.chinese}`), fetcher),
    ),
    purposes.length
      ? measure("purpose_embedding", () => fetchSentenceEmbeddings(purposes.map((item) => item.text), fetcher))
      : Promise.resolve([]),
  ])
  for (const [route, result] of [["sentence", original], ["purpose", purpose]] as const) {
    if (result.status === "rejected") {
      console.error(
        `[generation-enrichment] ${route} embedding failed`,
        result.reason instanceof Error ? result.reason.message : String(result.reason),
      )
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
    fetcher,
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
        !embedding.some((value) => value !== 0),
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
