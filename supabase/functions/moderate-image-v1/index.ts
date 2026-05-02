import { createClient } from "npm:@supabase/supabase-js@2"

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

interface ModerateImageRequestBody {
  userID?: string
  requestID?: string
  imageBase64?: string
  existingImagePath?: string | null
}

const IMAGE_MODERATION_TIMEOUT_MS = 10000
const IMAGE_MODERATION_SIGNED_URL_EXPIRES_SECONDS = 60

Deno.serve(async (req) => {
  try {
    if (req.method !== "POST") {
      return jsonResponse({ error: "Method Not Allowed" }, 405)
    }

    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")?.trim()
    if (!serviceRoleKey) {
      return jsonResponse({ error: "Missing server configuration" }, 500)
    }

    const expectedAuthorization = `Bearer ${serviceRoleKey}`
    if (req.headers.get("Authorization") !== expectedAuthorization) {
      return jsonResponse({ error: "Unauthorized" }, 401)
    }

    if (!isEnabledEnvFlag(Deno.env.get("IMAGE_MODERATION_ENABLED"))) {
      return jsonResponse({ allowed: true })
    }

    const supabaseUrl = Deno.env.get("SUPABASE_URL")?.trim()
    if (!supabaseUrl) {
      return jsonResponse(
        buildImageModerationUnavailableResult("missing supabase url"),
        200
      )
    }

    const body = (await req.json()) as ModerateImageRequestBody
    const userID = body.userID?.trim()
    const requestID = body.requestID?.trim() || crypto.randomUUID()
    const existingImagePath = body.existingImagePath?.trim() || null
    const imageBase64 = body.imageBase64?.replace(/\s+/g, "").trim()

    if (!userID) {
      return jsonResponse(
        buildImageModerationUnavailableResult("missing user id"),
        200
      )
    }

    if (!existingImagePath && !imageBase64) {
      return jsonResponse(
        buildImageModerationUnavailableResult("missing image input"),
        200
      )
    }

    const adminClient = createClient(supabaseUrl, serviceRoleKey)
    const result = await moderateImage({
      adminClient,
      userID,
      requestID,
      imageBase64,
      existingImagePath,
    })

    return jsonResponse(result)
  } catch (error) {
    return jsonResponse(
      buildImageModerationUnavailableResult(
        error instanceof Error ? error.message : String(error)
      ),
      200
    )
  }
})

async function moderateImage(args: {
  adminClient: any
  userID: string
  requestID: string
  imageBase64?: string
  existingImagePath: string | null
}): Promise<ImageModerationResult> {
  let moderationImagePath = args.existingImagePath
  let shouldRemoveModerationImage = false

  try {
    if (!moderationImagePath) {
      moderationImagePath = `${args.userID}/moderation/${args.requestID}.jpg`
      const imageBytes = decodeBase64(args.imageBase64 ?? "")
      const { error: uploadError } = await args.adminClient.storage
        .from("memories")
        .upload(moderationImagePath, imageBytes, {
          contentType: "image/jpeg",
          upsert: false,
        })

      if (uploadError) {
        return buildImageModerationUnavailableResult(
          `upload moderation image failed: ${uploadError.message}`
        )
      }

      shouldRemoveModerationImage = true
    }

    const { data: signedURLData, error: signedURLError } = await args.adminClient.storage
      .from("memories")
      .createSignedUrl(moderationImagePath, IMAGE_MODERATION_SIGNED_URL_EXPIRES_SECONDS)

    if (signedURLError || !signedURLData?.signedUrl) {
      return buildImageModerationUnavailableResult(
        `create moderation signed url failed: ${signedURLError?.message ?? "missing signed url"}`
      )
    }

    return await requestAliyunImageModeration({
      imageURL: signedURLData.signedUrl,
      dataID: args.requestID,
    })
  } finally {
    if (shouldRemoveModerationImage && moderationImagePath) {
      await removeStoragePathQuietly(args.adminClient, moderationImagePath)
    }
  }
}

async function requestAliyunImageModeration(args: {
  imageURL: string
  dataID: string
}): Promise<ImageModerationResult> {
  const accessKeyID = Deno.env.get("ALIBABA_CLOUD_ACCESS_KEY_ID")?.trim()
  const accessKeySecret = Deno.env.get("ALIBABA_CLOUD_ACCESS_KEY_SECRET")?.trim()
  const endpoint = normalizeAliyunEndpoint(Deno.env.get("ALIYUN_IMAGE_MODERATION_ENDPOINT"))
  const service = normalizeImageModerationService(
    Deno.env.get("ALIYUN_IMAGE_MODERATION_SERVICE")
  )

  if (!accessKeyID || !accessKeySecret || !endpoint) {
    return buildImageModerationUnavailableResult("missing aliyun image moderation configuration")
  }

  const fallbackEndpoint = normalizeAliyunEndpoint("green-cip.cn-beijing.aliyuncs.com")

  try {
    const primaryResponse = await requestAliyunImageModerationOnce({
      accessKeyID,
      accessKeySecret,
      endpoint,
      service,
      imageURL: args.imageURL,
      dataID: args.dataID,
    })

    if (shouldRetryAliyunImageModeration(primaryResponse) && endpoint !== fallbackEndpoint) {
      const fallbackResponse = await requestAliyunImageModerationOnce({
        accessKeyID,
        accessKeySecret,
        endpoint: fallbackEndpoint,
        service,
        imageURL: args.imageURL,
        dataID: args.dataID,
      })
      return normalizeAliyunImageModerationResponse(fallbackResponse)
    }

    return normalizeAliyunImageModerationResponse(primaryResponse)
  } catch (error) {
    if (endpoint !== fallbackEndpoint) {
      try {
        const fallbackResponse = await requestAliyunImageModerationOnce({
          accessKeyID,
          accessKeySecret,
          endpoint: fallbackEndpoint,
          service,
          imageURL: args.imageURL,
          dataID: args.dataID,
        })
        return normalizeAliyunImageModerationResponse(fallbackResponse)
      } catch (fallbackError) {
        return buildImageModerationUnavailableResult(
          `primary=${error instanceof Error ? error.message : String(error)}; fallback=${
            fallbackError instanceof Error ? fallbackError.message : String(fallbackError)
          }`
        )
      }
    }

    return buildImageModerationUnavailableResult(
      error instanceof Error ? error.message : String(error)
    )
  }
}

async function requestAliyunImageModerationOnce(args: {
  accessKeyID: string
  accessKeySecret: string
  endpoint: string
  service: string
  imageURL: string
  dataID: string
}): Promise<any> {
  return await callAliyunRPC({
    accessKeyID: args.accessKeyID,
    accessKeySecret: args.accessKeySecret,
    endpoint: args.endpoint,
    action: "ImageModeration",
    version: "2022-03-02",
    timeoutMs: IMAGE_MODERATION_TIMEOUT_MS,
    params: {
      Service: args.service,
      ServiceParameters: JSON.stringify({
        imageUrl: args.imageURL,
        dataId: args.dataID,
      }),
    },
  })
}

async function callAliyunRPC(args: {
  accessKeyID: string
  accessKeySecret: string
  endpoint: string
  action: string
  version: string
  timeoutMs: number
  params: Record<string, string>
}): Promise<any> {
  const commonParams: Record<string, string> = {
    Format: "JSON",
    Version: args.version,
    AccessKeyId: args.accessKeyID,
    SignatureMethod: "HMAC-SHA1",
    Timestamp: formatAliyunTimestamp(new Date()),
    SignatureVersion: "1.0",
    SignatureNonce: crypto.randomUUID(),
    Action: args.action,
    ...args.params,
  }
  const signature = await signAliyunRPCParams("POST", commonParams, args.accessKeySecret)
  const body = formEncode({
    ...commonParams,
    Signature: signature,
  })

  const response = await fetchWithTimeout(
    args.endpoint,
    {
      method: "POST",
      headers: {
        "Content-Type": "application/x-www-form-urlencoded; charset=utf-8",
      },
      body,
    },
    args.timeoutMs
  )
  const rawText = await response.text()
  let data: any = null
  try {
    data = rawText ? JSON.parse(rawText) : null
  } catch {
    data = null
  }

  if (!response.ok) {
    throw new Error(
      `Aliyun RPC HTTP ${response.status} ${response.statusText}: ${rawText.slice(0, 1000)}`
    )
  }

  return data ?? {
    Code: response.status,
    Message: rawText || "empty aliyun rpc response",
  }
}

async function signAliyunRPCParams(
  method: "POST" | "GET",
  params: Record<string, string>,
  accessKeySecret: string
): Promise<string> {
  const canonicalizedQueryString = Object.keys(params)
    .sort()
    .map((key) => `${percentEncode(key)}=${percentEncode(params[key] ?? "")}`)
    .join("&")
  const stringToSign = `${method}&${percentEncode("/")}&${percentEncode(
    canonicalizedQueryString
  )}`
  const key = `${accessKeySecret}&`
  const cryptoKey = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(key),
    {
      name: "HMAC",
      hash: "SHA-1",
    },
    false,
    ["sign"]
  )
  const signature = await crypto.subtle.sign(
    "HMAC",
    cryptoKey,
    new TextEncoder().encode(stringToSign)
  )
  return base64Encode(signature)
}

function normalizeAliyunImageModerationResponse(response: any): ImageModerationResult {
  const code = Number(response?.Code ?? response?.code ?? 0)
  if (code !== 200) {
    return buildImageModerationUnavailableResult(
      `Aliyun image moderation returned non-200 code: ${JSON.stringify(response)}`
    )
  }

  const data = response?.Data ?? response?.data ?? {}
  const topRiskLevel = normalizeRiskLevel(data?.RiskLevel ?? data?.riskLevel)
  const labels = extractImageModerationLabels(data)
  const labelRiskLevels = labels.map((label) => label.riskLevel)
  const hasHighRisk = topRiskLevel === "high" || labelRiskLevels.includes("high")
  const hasMediumRisk = topRiskLevel === "medium" || labelRiskLevels.includes("medium")
  const hasSevereLabel = labels.some((label) => isSevereImageModerationLabel(label))

  if (!hasHighRisk && !hasMediumRisk && !hasSevereLabel) {
    return { allowed: true }
  }

  const countedViolation = hasHighRisk || hasSevereLabel
  return {
    allowed: false,
    code: "generation_policy_violation",
    policyViolation: true,
    countedViolation,
    statusCode: 403,
    internalError: `image moderation blocked: ${JSON.stringify({
      riskLevel: topRiskLevel,
      labels,
    })}`,
    publicError: {
      error: "这张图片暂时无法生成，请更换图片后再试。",
      code: "generation_policy_violation",
    },
  }
}

function extractImageModerationLabels(data: any): Array<{
  label: string
  riskLevel: string
  confidence: number
}> {
  const rawResults = Array.isArray(data?.Result)
    ? data.Result
    : Array.isArray(data?.result)
      ? data.result
      : []

  return rawResults.map((item: any) => ({
    label: String(item?.Label ?? item?.label ?? "").trim(),
    riskLevel: normalizeRiskLevel(item?.RiskLevel ?? item?.riskLevel),
    confidence: normalizeNumber(item?.Confidence ?? item?.confidence),
  }))
}

function isSevereImageModerationLabel(label: {
  label: string
  riskLevel: string
  confidence: number
}): boolean {
  if (label.riskLevel !== "high") {
    return false
  }

  const normalizedLabel = label.label.toLowerCase()
  const severePrefixes = [
    "pornographic",
    "sexual",
    "political",
    "violent",
    "terror",
    "contraband",
    "abuse",
    "insult",
    "religion",
  ]

  return severePrefixes.some((prefix) => normalizedLabel.startsWith(prefix))
}

function buildImageModerationUnavailableResult(internalError: string): ImageModerationResult {
  const publicError: Record<string, unknown> = {
    error: "图片安全检查失败，请稍后再试。",
    code: "image_moderation_unavailable",
    debugVersion: "2026-05-02-moderate-image-v1-direct-rpc",
  }

  if (isEnabledEnvFlag(Deno.env.get("IMAGE_MODERATION_DEBUG"))) {
    publicError.details = internalError
  }

  return {
    allowed: false,
    code: "image_moderation_unavailable",
    policyViolation: false,
    countedViolation: false,
    statusCode: 503,
    internalError,
    publicError,
  }
}

async function removeStoragePathQuietly(adminClient: any, path: string): Promise<void> {
  try {
    await adminClient.storage.from("memories").remove([path])
  } catch (error) {
    console.error(
      "[moderate-image-v1]",
      JSON.stringify({
        code: "storage_cleanup_failed",
        internalError: error instanceof Error ? error.message : String(error),
        at: new Date().toISOString(),
      })
    )
  }
}

async function fetchWithTimeout(
  input: string,
  init: RequestInit,
  timeoutMs: number
): Promise<Response> {
  const controller = new AbortController()
  const timeout = setTimeout(() => controller.abort(), timeoutMs)

  try {
    return await fetch(input, {
      ...init,
      signal: controller.signal,
    })
  } finally {
    clearTimeout(timeout)
  }
}

function decodeBase64(base64: string): Uint8Array {
  const binary = atob(base64)
  const bytes = new Uint8Array(binary.length)
  for (let index = 0; index < binary.length; index += 1) {
    bytes[index] = binary.charCodeAt(index)
  }
  return bytes
}

function jsonResponse(data: unknown, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      "Content-Type": "application/json; charset=utf-8",
    },
  })
}

function shouldRetryAliyunImageModeration(response: any): boolean {
  return Number(response?.Code ?? response?.code ?? 0) === 500
}

function normalizeImageModerationService(value: string | undefined | null): string {
  const service = value?.trim()
  return service || "baselineCheck"
}

function normalizeAliyunEndpoint(value: string | undefined | null): string {
  const endpoint = value?.trim() || "green-cip.cn-shanghai.aliyuncs.com"
  if (endpoint.startsWith("http://") || endpoint.startsWith("https://")) {
    return endpoint
  }
  return `https://${endpoint}`
}

function formEncode(params: Record<string, string>): string {
  return Object.keys(params)
    .sort()
    .map((key) => `${percentEncode(key)}=${percentEncode(params[key] ?? "")}`)
    .join("&")
}

function percentEncode(value: string): string {
  return encodeURIComponent(value).replace(/[!'()*]/g, (character) =>
    `%${character.charCodeAt(0).toString(16).toUpperCase()}`
  )
}

function base64Encode(buffer: ArrayBuffer): string {
  const bytes = new Uint8Array(buffer)
  let binary = ""
  for (const byte of bytes) {
    binary += String.fromCharCode(byte)
  }
  return btoa(binary)
}

function formatAliyunTimestamp(date: Date): string {
  return date.toISOString().replace(/\.\d{3}Z$/, "Z")
}

function normalizeRiskLevel(value: unknown): string {
  return String(value ?? "none").trim().toLowerCase()
}

function normalizeNumber(value: unknown): number {
  if (typeof value === "number" && Number.isFinite(value)) {
    return value
  }

  const parsed = Number.parseFloat(String(value ?? "0"))
  return Number.isFinite(parsed) ? parsed : 0
}

function isEnabledEnvFlag(value: string | undefined | null): boolean {
  return ["1", "true", "yes", "on"].includes(value?.trim().toLowerCase() ?? "")
}
