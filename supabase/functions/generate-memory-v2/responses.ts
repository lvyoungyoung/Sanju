import { type ProviderName } from "./content.ts"

export function serializeGenerationError(args: {
  provider?: ProviderName
  code?: string
  statusCode?: number
  internalError: string
}) {
  return JSON.stringify({
    provider: args.provider ?? null,
    code: args.code ?? null,
    statusCode: args.statusCode ?? null,
    internalError: args.internalError,
    at: new Date().toISOString(),
  })
}

export function summarizeProviderFailure(args: {
  code?: string
  statusCode: number
  rateLimited?: boolean
  internalError: string
}): string {
  const parts = [
    args.code ? `code=${args.code}` : null,
    `status=${args.statusCode}`,
    args.rateLimited ? "rate_limited=true" : null,
    args.internalError,
  ].filter((part): part is string => Boolean(part))

  return truncateDiagnosticText(parts.join(" | "))
}

export function truncateDiagnosticText(value: string, maxLength = 500): string {
  const normalized = value.replace(/\s+/g, " ").trim()
  return normalized.length > maxLength
    ? `${normalized.slice(0, maxLength - 1)}…`
    : normalized
}

export function appendDiagnosticSnippet(
  message: string,
  label: string,
  value: unknown,
  maxLength = 300
): string {
  const snippet = makeDiagnosticSnippet(value, maxLength)
  return snippet ? `${message}; ${label}=${snippet}` : message
}

function makeDiagnosticSnippet(value: unknown, maxLength = 300): string {
  let text: string

  if (typeof value === "string") {
    text = value
  } else {
    try {
      text = JSON.stringify(value)
    } catch {
      text = String(value)
    }
  }

  return truncateDiagnosticText(text, maxLength)
}
export function decodeBase64(base64: string): Uint8Array {
  const binary = atob(base64)
  const bytes = new Uint8Array(binary.length)
  for (let index = 0; index < binary.length; index += 1) {
    bytes[index] = binary.charCodeAt(index)
  }
  return bytes
}

export function jsonResponse(data: unknown, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      "Content-Type": "application/json; charset=utf-8",
    },
  })
}

export function normalizeOptionalUUID(value: unknown): string | undefined {
  if (typeof value !== "string") {
    return undefined
  }

  const trimmed = value.trim().toLowerCase()
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(trimmed)
    ? trimmed
    : undefined
}

export function isTimeoutError(error: unknown): boolean {
  return error instanceof DOMException && error.name === "AbortError"
}
export function generationPendingResponse(timedOut = false): Response {
  return jsonResponse({
    error: timedOut ? "request timed out" : "生成仍在处理中，请稍后查看回忆。",
    code: "generation_in_progress",
    provider: "generation_job",
  }, timedOut ? 504 : 409)
}
