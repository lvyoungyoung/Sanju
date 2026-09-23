import { createClient } from "npm:@supabase/supabase-js@2"
import { resolveStudySceneIntent } from "./intent.ts"
import { CATEGORY_CATALOG_VERSION, ensureCategoryEmbeddings } from "./categories.ts"

const EMBEDDING_MODEL = "qwen3.7-text-embedding"
const EMBEDDING_DIMENSIONS = 1024
const EMBEDDING_TIMEOUT_MS = 20_000
const MAX_STUDY_SCENES = 20

function sceneLimitResponse() {
  return jsonResponse({ error: "最多可以创建20个学习主题", code: "study_scene_limit_reached" }, 409)
}

interface CreateStudySceneRequest {
  name?: string
  learning_topic_id?: string
}

const LEARNING_TOPIC_IDS = new Set([
  "self_and_style",
  "family_time",
  "children_growing_up",
  "friends_gatherings",
  "romance_and_companionship",
  "pet_life",
  "food_and_drinks",
  "cooking",
  "home_life",
  "city_life",
  "natural_scenery",
  "plants_and_wildlife",
  "travel",
  "transport",
  "sports_and_outdoors",
  "festivals_and_celebrations",
  "arts_and_entertainment",
  "school_and_study",
  "work_life",
  "shopping",
  "health_and_wellness",
])

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

    if (!supabaseUrl || !supabaseAnonKey || !serviceRoleKey) {
      return jsonResponse({ error: "Missing server configuration" }, 500)
    }

    const authHeader = req.headers.get("Authorization")
    if (!authHeader?.startsWith("Bearer ")) {
      return jsonResponse({ error: "Missing Authorization header" }, 401)
    }

    const body = (await req.json()) as CreateStudySceneRequest
    const name = body.name?.trim() ?? ""
    const learningTopicID = body.learning_topic_id?.trim() || null
    if (name.length < 2 || name.length > 24) {
      return jsonResponse({ error: "Study scene name must be between 2 and 24 characters" }, 400)
    }
    if (learningTopicID && !LEARNING_TOPIC_IDS.has(learningTopicID)) {
      return jsonResponse({ error: "Invalid learning topic" }, 400)
    }

    const accessToken = authHeader.replace("Bearer ", "").trim()
    const userClient = createClient(supabaseUrl, supabaseAnonKey, {
      global: { headers: { Authorization: `Bearer ${accessToken}` } },
    })
    // Preserve the device's local day when the RPC returns the new theme summary.
    // PostgreSQL validates the identifier and handles missing/invalid values.
    const studyTimeZone = req.headers.get("x-sanju-study-time-zone")
    const adminClient = createClient(supabaseUrl, serviceRoleKey, {
      global: { headers: studyTimeZone ? { "x-sanju-study-time-zone": studyTimeZone } : {} },
    })
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

    // Avoid paying for intent extraction or embedding when the limit is known. The
    // database trigger is authoritative if concurrent requests race this check.
    const { count, error: countError } = await adminClient.from("study_scenes")
      .select("id", { count: "exact", head: true }).eq("user_id", user.id)
    if (countError || count === null) {
      throw new Error("Unable to check study scene limit")
    }
    if (count >= MAX_STUDY_SCENES) {
      const { data: existing, error: existingError } = await adminClient.from("study_scenes")
        .select("id").eq("user_id", user.id).eq("name", name).maybeSingle()
      if (existingError) throw existingError
      if (!existing) return sceneLimitResponse()
    }

    let data: unknown
    let error: { code?: string; message: string; details?: string; hint?: string } | null

    if (learningTopicID) {
      const response = await adminClient.rpc("create_learning_topic_study_scene", {
        p_user_id: user.id,
        p_name: name,
        p_learning_topic_id: learningTopicID,
      })
      data = response.data
      error = response.error
    } else {
      if (!embeddingAPIKey || !embeddingURL) {
        return jsonResponse({ error: "Missing semantic matching configuration" }, 500)
      }

      const intent = await resolveStudySceneIntent(name, {
        url: Deno.env.get("MIMO_BASE_URL"),
        apiKey: Deno.env.get("MIMO_API_KEY"),
        fetcher: fetch,
      })
      if (intent.fallbackReason) {
        console.warn("[create-study-scene] intent fallback", intent.fallbackReason)
      }
      const sceneEmbedding = await createEmbeddings(embeddingURL, embeddingAPIKey, [intent.query], "query")
      if (!intent.fallbackReason) {
        try {
          await ensureCategoryEmbeddings({
            read: async () => {
              const result = await adminClient.from("learning_topic_embeddings")
                .select("topic_id,embedding").eq("model", EMBEDDING_MODEL)
                .eq("catalog_version", CATEGORY_CATALOG_VERSION)
              if (result.error) throw result.error
              return result.data ?? []
            },
            write: async (rows) => {
              const result = await adminClient.from("learning_topic_embeddings").upsert(
                rows.map((row) => ({ ...row, model: EMBEDDING_MODEL, catalog_version: CATEGORY_CATALOG_VERSION })),
                { onConflict: "topic_id,model,catalog_version" },
              )
              if (result.error) throw result.error
            },
          }, (texts) => createEmbeddings(embeddingURL, embeddingAPIKey, texts, "document"))
        } catch {
          console.warn("[create-study-scene] category cache unavailable; using available sentence/category vectors")
        }
      }
      const response = await adminClient.rpc("create_study_scene_with_matching_context", {
        p_user_id: user.id,
        p_name: name,
        p_embedding: sceneEmbedding[0],
        p_model: EMBEDDING_MODEL,
        p_search_description: intent.query,
        p_match_scope: intent.matchScope,
      })
      data = response.data
      error = response.error
    }

    if (error) {
      if (error.message === "study_scene_limit_reached") return sceneLimitResponse()
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
        500,
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
  textType: "query" | "document",
): Promise<number[][]> {
  const controller = new AbortController()
  const timeout = setTimeout(() => controller.abort(), EMBEDDING_TIMEOUT_MS)
  try {
    const response = await fetch(
      embeddingURL,
      {
        method: "POST",
        signal: controller.signal,
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
    const items = payload?.data ?? payload?.output?.embeddings ?? []
    // Providers may reorder batched results. Honor their indices when present.
    const embeddings: unknown[] = Array(inputs.length)
    if (!Array.isArray(items) || items.length !== inputs.length) throw new Error("Invalid embedding count")
    const seen = new Set<number>()
    for (let i = 0; i < items.length; i++) {
      const index = items[i]?.text_index ?? items[i]?.index ?? i
      if (!Number.isInteger(index) || index < 0 || index >= inputs.length || seen.has(index)) {
        throw new Error("Invalid embedding index")
      }
      seen.add(index)
      embeddings[index] = items[i]?.embedding
    }

    if (embeddings.length !== inputs.length || embeddings.some((item: unknown) => !isEmbedding(item))) {
      throw new Error("Embedding response had an invalid vector")
    }
    return embeddings as number[][]
  } finally {
    clearTimeout(timeout)
  }
}

function isEmbedding(value: unknown): value is number[] {
  return Array.isArray(value) &&
    value.length === EMBEDDING_DIMENSIONS &&
    value.every((item) => typeof item === "number" && Number.isFinite(item)) &&
    value.some((item) => item !== 0)
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
