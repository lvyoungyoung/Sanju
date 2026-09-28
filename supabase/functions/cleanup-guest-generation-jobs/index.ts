import { createClient } from "npm:@supabase/supabase-js@2"

Deno.serve(async (req) => {
  try {
    if (req.method !== "POST") {
      return jsonResponse({ error: "Method Not Allowed" }, 405)
    }

    const supabaseUrl = Deno.env.get("SUPABASE_LOCAL_URL") ?? Deno.env.get("SUPABASE_URL")
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")

    if (!supabaseUrl || !serviceRoleKey) {
      return jsonResponse({ error: "Missing server configuration" }, 500)
    }

    // This is a global maintenance endpoint, not an authenticated-user action.
    const token = req.headers.get("Authorization")?.match(/^Bearer\s+(\S+)$/i)?.[1]
    if (!token || !await matchesServiceKey(token, serviceRoleKey)) {
      return jsonResponse({ error: "Service role authorization required" }, 401)
    }

    const adminClient = createClient(supabaseUrl, serviceRoleKey)

    const { data: expiredJobs, error: loadError } = await adminClient
      .from("guest_generation_jobs")
      .select("id, image_path")
      .lt("created_at", new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString())
      .order("created_at")
      .order("id")
      .limit(100)

    if (loadError) {
      return jsonResponse(
        {
          error: "Failed to load expired guest jobs",
          details: loadError.message,
        },
        500
      )
    }

    const jobs = expiredJobs ?? []
    const imagePaths = [...new Set(jobs
      .map((job) => job.image_path)
      .filter((value): value is string => typeof value === "string" && value.length > 0))]

    let deletedImages = 0
    if (imagePaths.length > 0) {
      const { data, error } = await adminClient.storage.from("memories").remove(imagePaths)
      if (error) {
        // Keep every job so a partial Storage failure remains retryable.
        return jsonResponse({ success: false, error: "Failed to delete guest images",
          details: error.message, deletedJobs: 0, deletedImages: 0 }, 500)
      }
      deletedImages = data?.length ?? 0
    }

    let deletedJobs = 0
    if (jobs.length > 0) {
      const jobIDs = jobs.map((job) => job.id)
      const { data, error } = await adminClient.from("guest_generation_jobs")
        .delete().in("id", jobIDs).select("id")
      if (error) {
        return jsonResponse({ success: false, error: "Failed to delete guest jobs",
          details: error.message, deletedJobs: 0, deletedImages }, 500)
      }
      deletedJobs = data?.length ?? 0
    }

    return jsonResponse({
      success: true,
      deletedJobs,
      deletedImages,
      // A bounded batch avoids oversized REST URLs. An authorized caller may repeat it.
      hasMore: jobs.length === 100,
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

async function matchesServiceKey(token: string, expected: string): Promise<boolean> {
  const encoder = new TextEncoder()
  const left = new Uint8Array(await crypto.subtle.digest("SHA-256", encoder.encode(token)))
  const right = new Uint8Array(await crypto.subtle.digest("SHA-256", encoder.encode(expected)))
  let difference = 0
  for (let index = 0; index < left.length; index++) difference |= left[index] ^ right[index]
  return difference === 0
}

function jsonResponse(data: unknown, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      "Content-Type": "application/json; charset=utf-8",
    },
  })
}
