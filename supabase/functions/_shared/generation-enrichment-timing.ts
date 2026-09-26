export type EnrichmentStage =
  | "claim"
  | "metadata_generate"
  | "metadata_reuse"
  | "metadata_checkpoint"
  | "sentence_embedding"
  | "purpose_embedding"
  | "embeddings_parallel"
  | "publish_and_match"
  | "retry_state"

type Outcome = "completed" | "failed" | "no_work" | "partial_failure" | "lease_lost"
type Context = {
  runID?: string
  requestID?: string
  memoryID?: string
  guestJobID?: string
  sceneID?: string
  jobID?: string
  attempt?: number
}

export function isStagingEnrichmentEnvironment(url?: string): boolean {
  try {
    const configuredURL = url ?? Deno.env.get("SUPABASE_URL")
    return ["spb-bp1364k407p37qn7.supabase.opentrust.net", "api-staging.sanju.cc"].includes(new URL(configuredURL ?? "").hostname)
  } catch {
    // Optional diagnostics must not interrupt work when environment access is denied.
    return false
  }
}

// Only UUIDs, counts and monotonic durations are logged, never model inputs,
// outputs, account IDs, credentials or raw provider errors.
export class EnrichmentTiming {
  private readonly origin: number
  private readonly context: Context = {}
  private readonly stages: Record<string, unknown>[] = []

  constructor(
    context: Context,
    private readonly clock: () => number = () => performance.now(),
    private readonly output: (event: Record<string, unknown>) => void = (event) => console.log("[GenerationTiming]", JSON.stringify(event)),
    readonly enabled = isStagingEnrichmentEnvironment(),
  ) {
    this.origin = clock()
    for (const key of ["runID", "requestID", "memoryID", "guestJobID", "sceneID", "jobID"] as const) {
      const value = context[key]
      if (typeof value === "string" && /^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(value)) {
        this.context[key] = value.toLowerCase()
      }
    }
    if (Number.isSafeInteger(context.attempt) && context.attempt! >= 0) this.context.attempt = context.attempt
  }

  forJob(jobID: string, attempt: number): EnrichmentTiming {
    const child = new EnrichmentTiming({ ...this.context, jobID, attempt }, this.clock, this.output, this.enabled)
    const claim = this.stages.filter((stage) => stage.stage === "claim").at(-1)
    if (claim) child.stages.push(claim)
    return child
  }

  async measure<T>(stage: EnrichmentStage, operation: () => Promise<T>): Promise<T> {
    if (!this.enabled) return await operation()
    const start = this.clock()
    this.emit({ stage, event: "start" })
    let outcome = "failed"
    try {
      const result = await operation()
      outcome = "success"
      return result
    } finally {
      this.emit({ stage, event: "end", outcome, ms: this.elapsed(start) })
    }
  }

  finish(outcome: Outcome): void {
    this.emit({ stage: this.context.jobID ? "job_total" : "worker_total", event: "end", outcome, ms: this.elapsed(this.origin) })
  }

  report(): Record<string, unknown> {
    return { version: 1, ...this.context, stages: [...this.stages] }
  }

  private elapsed(start: number): number {
    return Math.round(Math.max(0, this.clock() - start) * 10) / 10
  }

  private emit(event: Record<string, unknown>): void {
    if (!this.enabled) return
    if (event.event === "end" && this.stages.length < 32) this.stages.push(event)
    // Diagnostics must not change generation, debit or retry behavior.
    try {
      this.output({ pipeline: "enrichment", ...this.context, ...event })
    } catch { /* best effort */ }
  }
}
