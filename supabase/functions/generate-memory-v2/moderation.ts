import { fetchWithTimeout } from "../_shared/fetch-with-timeout.ts"
import { serializeGenerationError, isTimeoutError } from "./responses.ts"

const GENERATION_VIOLATION_WINDOW_SECONDS = 24 * 60 * 60
const GENERATION_VIOLATION_LIMIT = 20
const GENERATION_VIOLATION_BAN_SECONDS = 24 * 60 * 60
const IMAGE_MODERATION_FUNCTION_TIMEOUT_MS = 10000
type ImageModerationResult =
  | { allowed: true }
  | {
      allowed: false
      code: string
      policyViolation: boolean
      countedViolation: boolean
      statusCode: number
      internalError: string
      publicError: Record<string, unknown>
    }

export type GenerationViolationRecord = {
  violationCount: number
  bannedUntil: string | null
}

export async function moderateImageBeforeGeneration(args: {
  userID: string
  imageBase64: string
  existingImagePath: string | null
  requestID: string
  fetcher: typeof fetch
}): Promise<ImageModerationResult> {
  if (!isEnabledEnvFlag(Deno.env.get("IMAGE_MODERATION_ENABLED"))) {
    return { allowed: true }
  }

  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")?.trim()
  const functionURL = buildModerationFunctionURL()

  if (!serviceRoleKey || !functionURL) {
    return buildImageModerationAllowResult("missing moderation function configuration")
  }

  const requestBody: Record<string, unknown> = {
    userID: args.userID,
    requestID: args.requestID,
    existingImagePath: args.existingImagePath,
    imageBase64: args.imageBase64,
  }

  try {
    const response = await fetchWithTimeout(
      functionURL,
      {
        method: "POST",
        headers: {
          Authorization: `Bearer ${serviceRoleKey}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify(requestBody),
      },
      IMAGE_MODERATION_FUNCTION_TIMEOUT_MS,
      args.fetcher
    )
    const rawText = await response.text()
    let data: unknown = null
    try {
      data = rawText ? JSON.parse(rawText) : null
    } catch {
      data = null
    }

    if (!response.ok) {
      return buildImageModerationAllowResult(
        `moderation function HTTP ${response.status}: ${rawText.slice(0, 1000)}`
      )
    }

    return normalizeModerationFunctionResult(data, rawText)
  } catch (error) {
    if (isTimeoutError(error)) {
      console.warn(
        "[generate-memory-v2]",
        serializeGenerationError({
          code: "image_moderation_timeout_allow",
          statusCode: 200,
          internalError: "image moderation did not return within 10s; allowing generation",
        })
      )
      return { allowed: true }
    }

    return buildImageModerationAllowResult(
      error instanceof Error ? error.message : String(error)
    )
  }
}
function buildModerationFunctionURL(): string | null {
  const configuredURL = Deno.env.get("IMAGE_MODERATION_FUNCTION_URL")?.trim()
  if (configuredURL) {
    return configuredURL
  }

  const supabaseURL = (Deno.env.get("SUPABASE_LOCAL_URL") ?? Deno.env.get("SUPABASE_URL"))?.trim()
  if (!supabaseURL) {
    return null
  }
  return `${supabaseURL.replace(/\/$/, "")}/functions/v1/moderate-image-v1`
}

function normalizeModerationFunctionResult(
  data: unknown,
  rawText: string
): ImageModerationResult {
  if (typeof data === "object" && data !== null && "allowed" in data) {
    const result = data as Record<string, unknown>
    if (result.allowed === true) {
      return { allowed: true }
    }

    if (result.allowed === false) {
      const policyViolation = result.policyViolation === true
      if (!policyViolation) {
        return buildImageModerationAllowResult(
          String(result.internalError ?? result.code ?? "moderation function unavailable")
        )
      }

      const publicError =
        typeof result.publicError === "object" && result.publicError !== null
          ? (result.publicError as Record<string, unknown>)
          : {
              error: "图片安全检查失败，请稍后再试。",
              code: "image_moderation_unavailable",
            }

      return {
        allowed: false,
        code: String(result.code ?? "image_moderation_unavailable"),
        policyViolation,
        countedViolation: result.countedViolation === true,
        statusCode:
          typeof result.statusCode === "number" && Number.isFinite(result.statusCode)
            ? result.statusCode
            : 503,
        internalError: String(result.internalError ?? "missing moderation internal error"),
        publicError,
      }
    }
  }

  return buildImageModerationAllowResult(
    `invalid moderation function response: ${rawText.slice(0, 1000)}`
  )
}

function buildImageModerationAllowResult(internalError: string): ImageModerationResult {
  console.warn(
    "[generate-memory-v2]",
    serializeGenerationError({
      code: "image_moderation_unavailable_allow",
      statusCode: 200,
      internalError: `image moderation unavailable; allowing generation: ${internalError}`,
    })
  )

  return { allowed: true }
}
function isEnabledEnvFlag(value: string | undefined | null): boolean {
  return ["1", "true", "yes", "on"].includes(value?.trim().toLowerCase() ?? "")
}

export function isGenerationViolationBanEnabled(): boolean {
  const value = Deno.env.get("GENERATION_VIOLATION_BAN_ENABLED")?.trim().toLowerCase()
  if (!value) {
    return true
  }
  return !["0", "false", "no", "off"].includes(value)
}

export function isFutureTimestamp(value: unknown): boolean {
  if (typeof value !== "string" || !value.trim()) {
    return false
  }

  const timestamp = Date.parse(value)
  return Number.isFinite(timestamp) && timestamp > Date.now()
}

export async function recordGenerationViolation(
  adminClient: any,
  userID: string
): Promise<GenerationViolationRecord | null> {
  const { data, error } = await adminClient.rpc("record_generation_violation", {
    p_user_id: userID,
    p_window_seconds: GENERATION_VIOLATION_WINDOW_SECONDS,
    p_limit: GENERATION_VIOLATION_LIMIT,
    p_ban_seconds: GENERATION_VIOLATION_BAN_SECONDS,
  })

  if (error) {
    console.error(
      "[generate-memory-v2]",
      serializeGenerationError({
        code: "record_generation_violation_failed",
        statusCode: 500,
        internalError: error.message,
      })
    )
    return null
  }

  const record = Array.isArray(data) ? data[0] : data
  if (!record) {
    return null
  }

  const rawCount = record.violation_count ?? record.violationCount
  const violationCount =
    typeof rawCount === "number" ? rawCount : Number.parseInt(String(rawCount ?? "0"), 10)
  const bannedUntil =
    typeof record.banned_until === "string"
      ? record.banned_until
      : typeof record.bannedUntil === "string"
        ? record.bannedUntil
        : null

  return {
    violationCount: Number.isFinite(violationCount) ? violationCount : 0,
    bannedUntil,
  }
}

export function buildGenerationPolicyViolationError(
  record: GenerationViolationRecord | null
): Record<string, unknown> {
  const isBanned = isFutureTimestamp(record?.bannedUntil)

  return {
    error: isBanned
      ? "当前账号暂时无法生成，请稍后再试。"
      : "这张图片暂时无法生成，请更换图片后再试。",
    code: isBanned ? "generation_banned" : "generation_policy_violation",
    bannedUntil: record?.bannedUntil ?? null,
    violationCount: record?.violationCount ?? null,
  }
}
