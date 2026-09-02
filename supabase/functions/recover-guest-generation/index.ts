import { createClient } from "npm:@supabase/supabase-js@2"

interface RequestBody {
  guestJobID?: string
  generationFormat?: string
}

const LEARNING_TOPIC_IDS = new Set([
  "people_and_relationships", "clothes_and_appearance", "house_and_home", "daily_routines",
  "food_and_cooking", "shopping_and_consumption", "health_and_body", "hobbies_and_culture",
  "sports_and_fitness", "social_occasions", "travel_and_transport", "places_and_public_services",
  "education_and_learning", "work_and_career", "nature_weather_and_environment",
  "digital_life_and_communication",
])

Deno.serve(async (req) => {
  try {
    if (req.method !== "POST") {
      return jsonResponse({ error: "Method Not Allowed" }, 405)
    }

    const supabaseUrl = Deno.env.get("SUPABASE_LOCAL_URL") ?? Deno.env.get("SUPABASE_URL")
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
    const body = (await req.json()) as RequestBody
    const guestJobID = body.guestJobID?.trim()
    const usesDualTabFormat = body.generationFormat === "dual_tabs_v1"

    if (!guestJobID) {
      return jsonResponse({ error: "guestJobID is required" }, 400)
    }

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

    if (user.is_anonymous !== true) {
      return jsonResponse(
        { error: "Only anonymous users can recover guest generations" },
        403
      )
    }

    const { data: job, error: jobError } = await adminClient
      .from("guest_generation_jobs")
      .select("id, status, image_path, created_at, remaining_credits, sentences, tags")
      .eq("id", guestJobID)
      .eq("user_id", user.id)
      .maybeSingle()

    if (jobError) {
      return jsonResponse(
        {
          error: "Failed to load guest generation job",
          details: jobError.message,
        },
        500
      )
    }

    if (!job) {
      return jsonResponse({ recovered: false })
    }

    if (job.status !== "completed" && job.status !== "acknowledged") {
      return jsonResponse({ recovered: false })
    }

    const sentences = Array.isArray(job.sentences) ? job.sentences : []
    if (usesDualTabFormat ? sentences.length !== 3 && sentences.length !== 6 : sentences.length < 3) {
      return jsonResponse({ recovered: false })
    }

    if (job.status === "completed") {
      await adminClient
        .from("guest_generation_jobs")
        .update({
          status: "acknowledged",
          acknowledged_at: new Date().toISOString(),
        })
        .eq("id", job.id)
    }

    return jsonResponse({
      recovered: true,
      guestJobID: job.id,
      memory: {
        id: crypto.randomUUID(),
        imagePath: "",
        createdAt: job.created_at,
        tags: Array.isArray(job.tags) ? job.tags : [],
        sentences: (usesDualTabFormat ? sentences : sentences.slice(0, 3)).map((sentence: any) => ({
          // Completed guest jobs already contain server-issued sentence IDs. Preserve
          // them so a recovered local memory keeps its staged semantic embedding.
          id: isUUID(sentence?.id) ? sentence.id : crypto.randomUUID(),
          english: String(sentence?.english ?? "").trim(),
          chinese: String(sentence?.chinese ?? "").trim(),
          learning_topic_ids: normalizeLearningTopicIDs(sentence?.learning_topic_ids),
          ...(usesDualTabFormat
            ? {
                presentation_group: sentence?.presentation_group === "what_i_say"
                  ? "what_i_say"
                  : "what_i_see",
              }
            : {}),
          is_favorite: false,
        })),
      },
      remainingCredits: job.remaining_credits,
      guestImagePath: job.image_path,
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

function isUUID(value: unknown): value is string {
  return typeof value === "string" &&
    /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value)
}

function normalizeLearningTopicIDs(value: unknown): string[] {
  if (!Array.isArray(value)) {
    return []
  }

  return Array.from(
    new Set(
      value
        .map((item) => String(item ?? "").trim())
        .filter((topicID) => LEARNING_TOPIC_IDS.has(topicID))
    )
  ).slice(0, 1)
}
