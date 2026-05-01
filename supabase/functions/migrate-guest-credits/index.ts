import { createClient } from "npm:@supabase/supabase-js@2"

interface RequestBody {
  guestRefreshToken: string
  guestUserID: string
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
    const guestRefreshToken = body.guestRefreshToken?.trim()
    const guestUserID = body.guestUserID?.trim()

    if (!guestRefreshToken || !guestUserID) {
      return jsonResponse({ error: "guestRefreshToken and guestUserID are required" }, 400)
    }

    const refreshResponse = await fetch(`${supabaseUrl}/auth/v1/token?grant_type=refresh_token`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        apikey: supabaseAnonKey,
      },
      body: JSON.stringify({
        refresh_token: guestRefreshToken,
      }),
    })

    const refreshText = await refreshResponse.text()
    let refreshData: any = null

    try {
      refreshData = JSON.parse(refreshText)
    } catch {
      refreshData = null
    }

    if (!refreshResponse.ok) {
      return jsonResponse(
        {
          error: "Guest session refresh failed",
          details: refreshData ?? refreshText,
        },
        400
      )
    }

    const refreshedGuestUser = refreshData?.user
    if (!refreshedGuestUser?.id || refreshedGuestUser.id !== guestUserID) {
      return jsonResponse(
        {
          error: "Guest user mismatch",
          details: {
            expected: guestUserID,
            actual: refreshedGuestUser?.id ?? null,
          },
        },
        400
      )
    }

    if (refreshedGuestUser.is_anonymous !== true) {
      return jsonResponse(
        {
          error: "Guest session is not anonymous",
        },
        400
      )
    }

    const { data: accountProfile, error: accountProfileError } = await adminClient
      .from("profiles")
      .select("id, apple_user_id, nickname, email, english_level, language_style, available_generations")
      .eq("id", user.id)
      .single()

    if (accountProfileError || !accountProfile) {
      return jsonResponse(
        {
          error: "Account profile not found",
          details: accountProfileError?.message ?? null,
        },
        404
      )
    }

    const { data: rpcResult, error: rpcError } = await adminClient.rpc("transfer_guest_credits", {
      p_guest_user_id: guestUserID,
      p_account_user_id: user.id,
    })

    if (rpcError) {
      return jsonResponse(
        {
          error: "Failed to migrate guest credits",
          details: {
            message: rpcError.message,
            details: rpcError.details ?? null,
            hint: rpcError.hint ?? null,
            code: rpcError.code ?? null,
          },
        },
        500
      )
    }

    const { data: profile, error: profileError } = await adminClient
      .from("profiles")
      .select("id,apple_user_id,nickname,email,english_level,language_style,available_generations")
      .eq("id", user.id)
      .single()

    if (profileError || !profile) {
      return jsonResponse(
        {
          error: "Failed to load migrated profile",
          details: profileError?.message ?? null,
        },
        500
      )
    }

    const merged = Array.isArray(rpcResult) ? Boolean(rpcResult[0]?.merged) : Boolean(rpcResult?.merged)

    return jsonResponse({
      profile,
      merged,
      guestUserID,
    })
  } catch (error) {
    return jsonResponse(
      {
        error: "Unexpected server error",
        details: error instanceof Error ? error.message : String(error),
      },
      500
    )
  }
})

function jsonResponse(data: unknown, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      "Content-Type": "application/json; charset=utf-8",
    },
  })
}
