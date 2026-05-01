import { createClient } from "npm:@supabase/supabase-js@2"
import { decodeJwt, importPKCS8, SignJWT } from "npm:jose@5.9.6"

interface ConfirmPurchaseRequest {
  transactionID: string
  productID: string
}

interface AppStoreServerConfig {
  issuerID: string
  keyID: string
  privateKey: string
  bundleID: string
}

interface AppStoreTransactionPayload {
  transactionId?: unknown
  productId?: unknown
  bundleId?: unknown
  appAccountToken?: unknown
  revocationDate?: unknown
}

const DEFAULT_PRODUCT_CREDITS: Record<string, number> = {
  "com.yanglv.sanju.credits200": 200,
  "com.yanglv.sanju.credits365": 365,
}

Deno.serve(async (req) => {
  try {
    if (req.method !== "POST") {
      return jsonResponse({ error: "Method Not Allowed" }, 405)
    }

    const supabaseUrl = Deno.env.get("SUPABASE_URL")
    const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY")
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")

    if (!supabaseUrl || !supabaseAnonKey || !serviceRoleKey) {
      return jsonResponse({ error: "Missing server configuration" }, 500)
    }

    const authHeader = req.headers.get("Authorization")
    if (!authHeader?.startsWith("Bearer ")) {
      return jsonResponse({ error: "Missing Authorization header" }, 401)
    }

    const accessToken = authHeader.replace("Bearer ", "").trim()
    const bundleID = Deno.env.get("APP_STORE_BUNDLE_ID")?.trim() || "com.yanglv.sanju"
    const appStoreConfig = readAppStoreServerConfig(bundleID)

    const userClient = createClient(supabaseUrl, supabaseAnonKey, {
      global: {
        headers: {
          Authorization: `Bearer ${accessToken}`,
        },
      },
    })

    const adminClient = createClient(supabaseUrl, serviceRoleKey)

    const {
      data: { user },
      error: userError,
    } = await userClient.auth.getUser()

    if (userError || !user) {
      return jsonResponse(
        {
          error: "Invalid JWT",
          details: userError?.message ?? null,
        },
        401
      )
    }

    const body = (await req.json()) as ConfirmPurchaseRequest
    const transactionID = body.transactionID?.trim()
    const productID = body.productID?.trim()
    const credits = creditsForProductID(productID)

    if (!transactionID || !productID || credits == null) {
      return jsonResponse({ error: "Invalid request payload" }, 400)
    }

    const transactionPayload = await fetchAppStoreTransactionPayload(
      appStoreConfig,
      transactionID
    )
    const validationError = validateAppStoreTransactionPayload(transactionPayload, {
      transactionID,
      productID,
      bundleID: appStoreConfig.bundleID,
      userID: user.id,
    })

    if (validationError) {
      return jsonResponse({ error: validationError }, 403)
    }

    const { data, error } = await adminClient.rpc("confirm_purchase_atomically", {
      p_user_id: user.id,
      p_transaction_id: transactionID,
      p_product_id: productID,
      p_credits: credits,
    })

    if (error) {
      const normalizedMessage = `${error.message} ${error.details ?? ""}`.trim().toLowerCase()

      if (normalizedMessage.includes("profile not found")) {
        return jsonResponse(
          {
            error: "Profile not found",
            details: error.details ?? null,
          },
          404
        )
      }

      if (
        normalizedMessage.includes("transaction id is required") ||
        normalizedMessage.includes("product id is required") ||
        normalizedMessage.includes("credits must be positive")
      ) {
        return jsonResponse(
          {
            error: "Invalid request payload",
            details: {
              message: error.message,
              details: error.details ?? null,
              hint: error.hint ?? null,
              code: error.code ?? null,
            },
          },
          400
        )
      }

      console.error(
        "[confirm-purchase]",
        JSON.stringify({
          code: error.code ?? null,
          message: error.message,
          details: error.details ?? null,
          hint: error.hint ?? null,
          transactionID,
          userID: user.id,
        })
      )

      return jsonResponse(
        {
          error: "Failed to confirm purchase",
          details: {
            message: error.message,
            details: error.details ?? null,
            hint: error.hint ?? null,
            code: error.code ?? null,
          },
        },
        500
      )
    }

    const normalizedResult = normalizePurchaseRPCResult(data)

    return jsonResponse({
      success: true,
      alreadyProcessed: normalizedResult.alreadyProcessed,
      remainingCredits: normalizedResult.remainingCredits,
    })
  } catch (error) {
    if (error instanceof AppStoreConfigurationError) {
      return jsonResponse({ error: "Missing App Store Server API configuration" }, 500)
    }

    if (error instanceof AppStoreLookupError) {
      return jsonResponse(
        {
          error: "Failed to validate App Store transaction",
          details: error.message,
        },
        error.status
      )
    }

    return jsonResponse(
      {
        error: "Unexpected server error",
        details: error instanceof Error ? error.message : String(error),
      },
      500
    )
  }
})

class AppStoreConfigurationError extends Error {}

class AppStoreLookupError extends Error {
  constructor(message: string, readonly status = 502) {
    super(message)
  }
}

function readAppStoreServerConfig(bundleID: string): AppStoreServerConfig {
  const issuerID = Deno.env.get("APP_STORE_CONNECT_ISSUER_ID")?.trim()
  const keyID = Deno.env.get("APP_STORE_CONNECT_KEY_ID")?.trim()
  const privateKey = Deno.env.get("APP_STORE_CONNECT_PRIVATE_KEY")?.trim()

  if (!issuerID || !keyID || !privateKey) {
    throw new AppStoreConfigurationError("Missing App Store Server API credentials")
  }

  return {
    issuerID,
    keyID,
    privateKey,
    bundleID,
  }
}

function creditsForProductID(productID: string | undefined): number | null {
  if (!productID) {
    return null
  }

  const productCredits = loadProductCredits()
  const credits = productCredits[productID]
  return Number.isInteger(credits) && credits > 0 ? credits : null
}

function loadProductCredits(): Record<string, number> {
  const raw = Deno.env.get("STOREKIT_PRODUCT_CREDITS_JSON")?.trim()
  if (!raw) {
    return DEFAULT_PRODUCT_CREDITS
  }

  try {
    const parsed = JSON.parse(raw) as Record<string, unknown>
    return Object.fromEntries(
      Object.entries(parsed)
        .map(([productID, credits]) => [productID, Number(credits)] as const)
        .filter(([, credits]) => Number.isInteger(credits) && credits > 0)
    )
  } catch {
    return DEFAULT_PRODUCT_CREDITS
  }
}

async function fetchAppStoreTransactionPayload(
  config: AppStoreServerConfig,
  transactionID: string
): Promise<AppStoreTransactionPayload> {
  const token = await generateAppStoreServerJWT(config)
  const productionResult = await requestAppStoreTransaction(
    "https://api.storekit.itunes.apple.com",
    token,
    transactionID
  )

  if (productionResult.ok) {
    return productionResult.payload
  }

  const sandboxResult = await requestAppStoreTransaction(
    "https://api.storekit-sandbox.itunes.apple.com",
    token,
    transactionID
  )

  if (sandboxResult.ok) {
    return sandboxResult.payload
  }

  throw new AppStoreLookupError(
    sandboxResult.details || productionResult.details || "Transaction not found",
    sandboxResult.status || productionResult.status || 502
  )
}

async function requestAppStoreTransaction(
  baseURL: string,
  token: string,
  transactionID: string
): Promise<
  | { ok: true; payload: AppStoreTransactionPayload }
  | { ok: false; status: number; details: string }
> {
  const response = await fetch(
    `${baseURL}/inApps/v1/transactions/${encodeURIComponent(transactionID)}`,
    {
      headers: {
        Authorization: `Bearer ${token}`,
      },
    }
  )
  const rawText = await response.text()

  if (!response.ok) {
    return {
      ok: false,
      status: response.status >= 500 ? 502 : response.status,
      details: rawText,
    }
  }

  let body: { signedTransactionInfo?: unknown }
  try {
    body = JSON.parse(rawText)
  } catch {
    throw new AppStoreLookupError("App Store returned invalid JSON")
  }

  if (typeof body.signedTransactionInfo !== "string") {
    throw new AppStoreLookupError("App Store response missed signedTransactionInfo")
  }

  return {
    ok: true,
    payload: decodeJwt(body.signedTransactionInfo) as AppStoreTransactionPayload,
  }
}

async function generateAppStoreServerJWT(config: AppStoreServerConfig): Promise<string> {
  const now = Math.floor(Date.now() / 1000)
  const normalizedPrivateKey = config.privateKey.replace(/\\n/g, "\n")
  const key = await importPKCS8(normalizedPrivateKey, "ES256")

  return await new SignJWT({
    bid: config.bundleID,
  })
    .setProtectedHeader({
      alg: "ES256",
      kid: config.keyID,
      typ: "JWT",
    })
    .setIssuer(config.issuerID)
    .setAudience("appstoreconnect-v1")
    .setIssuedAt(now)
    .setExpirationTime(now + 20 * 60)
    .sign(key)
}

function validateAppStoreTransactionPayload(
  payload: AppStoreTransactionPayload,
  expected: {
    transactionID: string
    productID: string
    bundleID: string
    userID: string
  }
): string | null {
  const transactionID = stringValue(payload.transactionId)
  const productID = stringValue(payload.productId)
  const bundleID = stringValue(payload.bundleId)
  const appAccountToken = stringValue(payload.appAccountToken)

  if (transactionID !== expected.transactionID) {
    return "Transaction ID mismatch"
  }

  if (productID !== expected.productID) {
    return "Product ID mismatch"
  }

  if (bundleID !== expected.bundleID) {
    return "Bundle ID mismatch"
  }

  if (payload.revocationDate != null) {
    return "Transaction has been revoked"
  }

  if (!appAccountToken || appAccountToken.toLowerCase() !== expected.userID.toLowerCase()) {
    return "Transaction does not belong to current user"
  }

  return null
}

function stringValue(value: unknown): string | null {
  if (typeof value === "string") {
    return value.trim()
  }

  if (typeof value === "number" || typeof value === "bigint") {
    return String(value)
  }

  return null
}

function normalizePurchaseRPCResult(data: unknown) {
  const result = Array.isArray(data) ? data[0] : data
  const remainingCreditsRaw =
    typeof result === "object" && result !== null
      ? (result as Record<string, unknown>).remaining_credits
      : data
  const alreadyProcessedRaw =
    typeof result === "object" && result !== null
      ? (result as Record<string, unknown>).already_processed
      : false

  const remainingCredits =
    typeof remainingCreditsRaw === "number"
      ? remainingCreditsRaw
      : Number.parseInt(String(remainingCreditsRaw ?? "0"), 10)

  if (!Number.isFinite(remainingCredits)) {
    throw new Error(`Unexpected confirm_purchase_atomically result: ${JSON.stringify(data)}`)
  }

  return {
    remainingCredits,
    alreadyProcessed: Boolean(alreadyProcessedRaw),
  }
}

function jsonResponse(data: unknown, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      "Content-Type": "application/json; charset=utf-8",
    },
  })
}
