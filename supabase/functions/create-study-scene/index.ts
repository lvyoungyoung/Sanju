import { createClient } from "npm:@supabase/supabase-js@2"

const EMBEDDING_MODEL = "qwen3.7-text-embedding"
const EMBEDDING_DIMENSIONS = 1024
const EMBEDDING_TIMEOUT_MS = 20_000

interface CreateStudySceneRequest {
  name?: string
}

Deno.serve(async (req) => {
  try {
    if (req.method !== "POST") {
      return jsonResponse({ error: "Method Not Allowed" }, 405)
    }

    const supabaseUrl = Deno.env.get("SUPABASE_LOCAL_URL") ?? Deno.env.get("SUPABASE_URL")
    const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY")
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")
    const embeddingAPIKey = Deno.env.get("DASHSCOPE_API_KEY")
    const embeddingURL = Deno.env.get("DASHSCOPE_EMBEDDING_URL")

    if (!supabaseUrl || !supabaseAnonKey || !serviceRoleKey || !embeddingAPIKey || !embeddingURL) {
      return jsonResponse({ error: "Missing server configuration" }, 500)
    }

    const authHeader = req.headers.get("Authorization")
    if (!authHeader?.startsWith("Bearer ")) {
      return jsonResponse({ error: "Missing Authorization header" }, 401)
    }

    const body = (await req.json()) as CreateStudySceneRequest
    const name = body.name?.trim() ?? ""
    if (name.length < 2 || name.length > 24) {
      return jsonResponse({ error: "Study scene name must be between 2 and 24 characters" }, 400)
    }

    const accessToken = authHeader.replace("Bearer ", "").trim()
    const userClient = createClient(supabaseUrl, supabaseAnonKey, {
      global: { headers: { Authorization: `Bearer ${accessToken}` } },
    })
    const adminClient = createClient(supabaseUrl, serviceRoleKey)
    const {
      data: { user },
      error: userError,
    } = await userClient.auth.getUser()

    if (userError || !user) {
      return jsonResponse({ error: "Invalid JWT" }, 401)
    }

    if (user.is_anonymous === true) {
      return jsonResponse({ error: "Sign in is required to create study scenes" }, 401)
    }

    const sceneEmbedding = await createEmbeddings(embeddingURL, embeddingAPIKey, [name], "query")
    const { data, error } = await adminClient.rpc("create_study_scene_with_embedding", {
      p_user_id: user.id,
      p_name: name,
      p_embedding: sceneEmbedding[0],
      p_model: EMBEDDING_MODEL,
    })

    if (error) {
      const diagnostic = {
        code: error.code ?? null,
        message: error.message,
        details: error.details ?? null,
        hint: error.hint ?? null,
      }
      console.error("[create-study-scene] database update failed", JSON.stringify(diagnostic))
      return jsonResponse(
        {
          error: "Failed to create study scene",
          // Staging is a controlled test environment. Returning the database
          // diagnostic here avoids hiding migration or function-signature bugs.
          ...(isStagingRequest(req) ? { diagnostic } : {}),
        },
        500
      )
    }

    const scene = Array.isArray(data) ? data[0] : data
    if (!scene) {
      return jsonResponse({ error: "Study scene response is invalid" }, 500)
    }

    return jsonResponse({ scene })
  } catch (error) {
    console.error("[create-study-scene]", error)
    return jsonResponse({ error: "Unable to create this study scene right now" }, 500)
  }
})

async function createEmbeddings(
  embeddingURL: string,
  embeddingAPIKey: string,
  inputs: string[],
  textType: "query" | "document"
): Promise<number[][]> {
  const response = await fetchWithTimeout(
    embeddingURL,
    {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${embeddingAPIKey}`,
      },
      body: JSON.stringify({
        model: EMBEDDING_MODEL,
        input: { texts: inputs },
        parameters: {
          dimension: EMBEDDING_DIMENSIONS,
          output_type: "dense",
          text_type: textType,
        },
      }),
    },
    EMBEDDING_TIMEOUT_MS
  )
  const rawText = await response.text()
  if (!response.ok) {
    throw new Error(`Embedding request failed: HTTP ${response.status}`)
  }

  let payload: any
  try {
    payload = JSON.parse(rawText)
  } catch {
    throw new Error("Embedding response was not JSON")
  }
  const embeddings = Array.isArray(payload?.data)
    ? payload.data.map((item: any) => item?.embedding)
    : Array.isArray(payload?.output?.embeddings)
      ? payload.output.embeddings.map((item: any) => item?.embedding)
      : []

  if (embeddings.length !== inputs.length || embeddings.some((item: unknown) => !isEmbedding(item))) {
    throw new Error("Embedding response had an invalid vector")
  }
  return embeddings as number[][]
}

function isEmbedding(value: unknown): value is number[] {
  return Array.isArray(value)
    && value.length === EMBEDDING_DIMENSIONS
    && value.every((item) => typeof item === "number" && Number.isFinite(item))
}

async function fetchWithTimeout(input: string, init: RequestInit, timeoutMs: number): Promise<Response> {
  const controller = new AbortController()
  const timeout = setTimeout(() => controller.abort(), timeoutMs)
  try {
    return await fetch(input, { ...init, signal: controller.signal })
  } finally {
    clearTimeout(timeout)
  }
}

function jsonResponse(data: unknown, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "Content-Type": "application/json; charset=utf-8" },
  })
}

function isStagingRequest(req: Request): boolean {
  const hosts = [
    req.headers.get("host"),
    req.headers.get("x-forwarded-host"),
    req.headers.get("origin"),
  ].filter((value): value is string => Boolean(value))

  return hosts.some((value) => value.includes("api-staging.sanju.cc"))
}
