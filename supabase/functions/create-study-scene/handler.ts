import { createClient } from "npm:@supabase/supabase-js@2"
import { matchStudyScene } from "./matching.ts"

const MAX_STUDY_SCENES = 20

function sceneLimitResponse() {
  return jsonResponse({ error: "最多可以创建20个学习主题", code: "study_scene_limit_reached" }, 409)
}

interface CreateStudySceneRequest {
  name?: string
  learning_topic_id?: string
  scene_id?: string
  prepare_only?: boolean
  enrichment_status_only?: boolean
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

export async function handleCreateStudyScene(req: Request): Promise<Response> {
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
    let name = body.name?.trim() ?? ""
    const preparing = body.prepare_only === true
    const legacyEnrichmentStatus = body.enrichment_status_only === true
    const sceneID = body.scene_id
    const learningTopicID = body.learning_topic_id?.trim() || null
    if (!preparing && !legacyEnrichmentStatus && (name.length < 2 || name.length > 24)) {
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

    if (preparing || legacyEnrichmentStatus) {
      if (typeof sceneID !== "string" || !/^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(sceneID)) {
        return jsonResponse({ error: "Invalid study scene" }, 400)
      }
      const existing = await adminClient.from("study_scenes").select("id,name")
        .eq("id", sceneID).eq("user_id", user.id).maybeSingle()
      if (existing.error) throw existing.error
      if (!existing.data) return jsonResponse({ error: "Study scene not found" }, 404)
      name = existing.data.name
    }

    if (legacyEnrichmentStatus) {
      // Stop polling from older clients without inspecting or restarting jobs.
      return jsonResponse({ enrichment: { pendingCount: 0, completedCount: 0, failedCount: 0, retryAfterSeconds: 5 } })
    }

    // Avoid paying for embedding when the limit is known. The
    // database trigger is authoritative if concurrent requests race this check.
    const { count, error: countError } = await adminClient.from("study_scenes")
      .select("id", { count: "exact", head: true }).eq("user_id", user.id)
    if (countError || count === null) {
      throw new Error("Unable to check study scene limit")
    }
    if (!preparing && count >= MAX_STUDY_SCENES) {
      const { data: existing, error: existingError } = await adminClient.from("study_scenes")
        .select("id").eq("user_id", user.id).eq("name", name).maybeSingle()
      if (existingError) throw existingError
      if (!existing) return sceneLimitResponse()
    }

    if (!embeddingAPIKey || !embeddingURL) {
      return jsonResponse({ error: "Missing semantic matching configuration" }, 500)
    }
    const { data, error } = await matchStudyScene({
      adminClient, userID: user.id, name, sceneID, preparing, embeddingAPIKey, embeddingURL,
    })

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

    const scene = (Array.isArray(data) ? data[0] : data) as { id: string } | null
    if (!scene) {
      return jsonResponse({ error: "Study scene response is invalid" }, 500)
    }

    return jsonResponse({ scene })
  } catch (error) {
    console.error("[create-study-scene]", error)
    return jsonResponse({ error: "Unable to create this study scene right now" }, 500)
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
