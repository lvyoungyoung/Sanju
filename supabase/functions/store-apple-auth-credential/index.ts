import { createClient } from "npm:@supabase/supabase-js@2"
import { importPKCS8, SignJWT } from "npm:jose@5.9.6"

interface RequestBody {
  authorizationCode: string
}

Deno.serve(async (req) => {
  try {
    if (req.method !== "POST") {
      return jsonResponse({ error: "Method Not Allowed" }, 405)
    }

    const supabaseUrl = Deno.env.get("SUPABASE_URL")
    const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY")
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")
    const appleTeamID = Deno.env.get("APPLE_TEAM_ID")
    const appleClientID = Deno.env.get("APPLE_CLIENT_ID")
    const appleKeyID = Deno.env.get("APPLE_KEY_ID")
    const applePrivateKey = Deno.env.get("APPLE_PRIVATE_KEY")

    if (!supabaseUrl || !supabaseAnonKey || !serviceRoleKey) {
      return jsonResponse({ error: "Missing server configuration" }, 500)
    }

    if (!appleTeamID || !appleClientID || !appleKeyID || !applePrivateKey) {
      return jsonResponse({ error: "Missing Apple configuration" }, 500)
    }

    const authHeader = req.headers.get("Authorization")
    if (!authHeader?.startsWith("Bearer ")) {
      return jsonResponse({ error: "Missing Authorization header" }, 401)
    }

    const accessToken = authHeader.replace("Bearer ", "").trim()

    const userClient = createClient(supabaseUrl, supabaseAnonKey)
    const adminClient = createClient(supabaseUrl, serviceRoleKey)

    const {
      data: { user },
      error: userError,
    } = await userClient.auth.getUser(accessToken)

    if (userError || !user) {
      return jsonResponse(
        {
          error: "Invalid JWT",
          details: userError?.message ?? null,
        },
        401
      )
    }

    const body = (await req.json()) as RequestBody
    const authorizationCode = body.authorizationCode?.trim()

    if (!authorizationCode) {
      return jsonResponse({ error: "authorizationCode is required" }, 400)
    }

    const clientSecret = await generateAppleClientSecret({
      teamID: appleTeamID,
      clientID: appleClientID,
      keyID: appleKeyID,
      privateKey: applePrivateKey,
    })

    const tokenResponse = await fetch("https://appleid.apple.com/auth/token", {
      method: "POST",
      headers: {
        "Content-Type": "application/x-www-form-urlencoded",
      },
      body: new URLSearchParams({
        client_id: appleClientID,
        client_secret: clientSecret,
        code: authorizationCode,
        grant_type: "authorization_code",
      }).toString(),
    })

    const tokenText = await tokenResponse.text()

    let tokenJSON: Record<string, unknown> | null = null
    try {
      tokenJSON = JSON.parse(tokenText)
    } catch {
      tokenJSON = null
    }

    if (!tokenResponse.ok) {
      return jsonResponse(
        {
          error: "Failed to exchange Apple authorization code",
          details: tokenJSON ?? tokenText,
        },
        500
      )
    }

    const refreshToken =
      typeof tokenJSON?.refresh_token === "string"
        ? tokenJSON.refresh_token.trim()
        : ""

    if (!refreshToken) {
      return jsonResponse(
        {
          error: "Missing refresh token from Apple token response",
          details: tokenJSON,
        },
        500
      )
    }

    const { error: upsertError } = await adminClient
      .from("apple_auth_credentials")
      .upsert({
        user_id: user.id,
        refresh_token: refreshToken,
        updated_at: new Date().toISOString(),
      })

    if (upsertError) {
      return jsonResponse(
        {
          error: "Failed to store refresh token",
          details: upsertError.message,
        },
        500
      )
    }

    return jsonResponse({ success: true })
  } catch (error) {
    return jsonResponse(
      {
        error: "Unexpected server error",
        details: error instanceof Error ? error.message : String(error),
        stack: error instanceof Error ? error.stack : null,
      },
      500
    )
  }
})

async function generateAppleClientSecret(input: {
  teamID: string
  clientID: string
  keyID: string
  privateKey: string
}) {
  const algorithm = "ES256"
  const now = Math.floor(Date.now() / 1000)
  const expiration = now + 60 * 60 * 24 * 180

  const normalizedPrivateKey = input.privateKey.replace(/\\n/g, "\n")
  const key = await importPKCS8(normalizedPrivateKey, algorithm)

  return await new SignJWT({})
    .setProtectedHeader({
      alg: algorithm,
      kid: input.keyID,
    })
    .setIssuer(input.teamID)
    .setSubject(input.clientID)
    .setAudience("https://appleid.apple.com")
    .setIssuedAt(now)
    .setExpirationTime(expiration)
    .sign(key)
}

function jsonResponse(data: unknown, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      "Content-Type": "application/json; charset=utf-8",
    },
  })
}