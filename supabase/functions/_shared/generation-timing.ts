// Sequential wall-clock stages, including the handler's finally/slot release.
// No prompts, images, identities or credentials are included in this metadata.
export class GenerationTiming {
  private readonly origin: number
  private previous: number
  private stage = "setup"
  private readonly durations = new Map<string, number>()

  constructor(private readonly clock: () => number = () => performance.now()) {
    this.origin = this.previous = clock()
  }

  start(stage: string): void {
    if (!/^[a-z][a-z0-9_]{0,47}$/.test(stage)) throw new Error("Invalid timing stage")
    const now = this.clock()
    this.durations.set(this.stage, (this.durations.get(this.stage) ?? 0) + Math.max(0, now - this.previous))
    this.stage = stage
    this.previous = now
  }

  header(): string {
    this.start("finished")
    const values = [...this.durations].map(([name, duration]) => `${name};dur=${duration.toFixed(1)}`)
    values.push(`total;dur=${Math.max(0, this.previous - this.origin).toFixed(1)}`)
    return values.join(", ")
  }
}

export async function withGenerationTiming(
  req: Request, handler: (req: Request, timing: GenerationTiming) => Promise<Response>,
): Promise<Response> {
  const timing = new GenerationTiming()
  const response = await handler(req, timing)
  // Debug clients opt in; legacy/release clients receive the identical contract.
  if (req.headers.get("x-sanju-generation-timing") !== "1") return response
  const headers = new Headers(response.headers)
  headers.set("Server-Timing", timing.header())
  headers.set("X-Sanju-Generation-Timing", "1")
  const traceID = req.headers.get("x-sanju-generation-trace-id") ?? ""
  if (/^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(traceID)) {
    headers.set("X-Sanju-Generation-Trace-ID", traceID.toLowerCase())
  }
  return new Response(response.body, { status: response.status, statusText: response.statusText, headers })
}
