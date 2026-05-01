import { createClient } from "npm:@supabase/supabase-js@2"

Deno.serve(async () => {
  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL")
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")

    if (!supabaseUrl || !serviceRoleKey) {
      return jsonResponse({ error: "Missing server configuration" }, 500)
    }

    const adminClient = createClient(supabaseUrl, serviceRoleKey)

    const { data: expiredJobs, error: loadError } = await adminClient
      .from("guest_generation_jobs")
      .select("id, image_path")
      .lt("created_at", new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString())

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
    const imagePaths = jobs
      .map((job) => job.image_path)
      .filter((value): value is string => typeof value === "string" && value.length > 0)

    if (imagePaths.length > 0) {
      await adminClient.storage.from("memories").remove(imagePaths)
    }

    if (jobs.length > 0) {
      const jobIDs = jobs.map((job) => job.id)
      await adminClient.from("guest_generation_jobs").delete().in("id", jobIDs)
    }

    return jsonResponse({
      success: true,
      deletedJobs: jobs.length,
      deletedImages: imagePaths.length,
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