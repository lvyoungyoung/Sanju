import { createClient } from "npm:@supabase/supabase-js@2"

type DeletionJobStatus = "pending" | "running" | "completed" | "failed"

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

    const userID = user.id

    const { data: existingJob, error: loadJobError } = await adminClient
      .from("account_deletion_jobs")
      .select("id, status")
      .eq("user_id", userID)
      .maybeSingle()

    if (loadJobError) {
      return jsonResponse(
        {
          error: "Failed to load deletion job",
          details: loadJobError.message,
        },
        500
      )
    }

    if (existingJob?.status === "completed") {
      return jsonResponse({
        success: true,
        alreadyCompleted: true,
      })
    }

    if (!existingJob) {
      const { error: createJobError } = await adminClient
        .from("account_deletion_jobs")
        .insert({
          user_id: userID,
          status: "pending",
        })

      if (createJobError) {
        return jsonResponse(
          {
            error: "Failed to create deletion job",
            details: createJobError.message,
          },
          500
        )
      }
    }

    const nowISO = new Date().toISOString()
    const { error: startJobError } = await adminClient
      .from("account_deletion_jobs")
      .update({
        status: "running" as DeletionJobStatus,
        started_at: nowISO,
        last_error: null,
      })
      .eq("user_id", userID)

    if (startJobError) {
      return jsonResponse(
        {
          error: "Failed to start deletion job",
          details: startJobError.message,
        },
        500
      )
    }

    try {
      const warnings: string[] = []

      const { data: memories, error: memoriesError } = await adminClient
        .from("memories")
        .select("id, image_url")
        .eq("user_id", userID)

      if (memoriesError) {
        throw new Error(`Failed to load user memories: ${memoriesError.message}`)
      }

      const memoryIDs = (memories ?? [])
        .map((item) => item.id)
        .filter((value): value is string => typeof value === "string" && value.length > 0)

      const imagePaths = (memories ?? [])
        .map((item) => item.image_url)
        .filter((value): value is string => typeof value === "string" && value.length > 0)

      if (memoryIDs.length > 0) {
        const { error: deleteSentencesError } = await adminClient
          .from("memory_sentences")
          .delete()
          .in("memory_id", memoryIDs)

        if (deleteSentencesError) {
          throw new Error(`Failed to delete memory sentences: ${deleteSentencesError.message}`)
        }
      }

      const tableDeletes: Array<{
        table: string
        column: string
        value: string
        errorMessage: string
      }> = [
        {
          table: "memories",
          column: "user_id",
          value: userID,
          errorMessage: "Failed to delete memories",
        },
        {
          table: "purchase_ledger",
          column: "user_id",
          value: userID,
          errorMessage: "Failed to delete purchase ledger",
        },
        {
          table: "generation_transactions",
          column: "user_id",
          value: userID,
          errorMessage: "Failed to delete generation transactions",
        },
        {
          table: "profiles",
          column: "id",
          value: userID,
          errorMessage: "Failed to delete profile",
        },
        {
          table: "apple_auth_credentials",
          column: "user_id",
          value: userID,
          errorMessage: "Failed to delete Apple auth credential",
        },
      ]

      for (const step of tableDeletes) {
        const { error } = await adminClient
          .from(step.table)
          .delete()
          .eq(step.column, step.value)

        if (error) {
          throw new Error(`${step.errorMessage}: ${error.message}`)
        }
      }

      const { error: deleteAuthUserError } = await adminClient.auth.admin.deleteUser(userID)
      if (deleteAuthUserError) {
        const normalized = deleteAuthUserError.message.toLowerCase()
        const alreadyGone =
          normalized.includes("not found") ||
          normalized.includes("user not found") ||
          normalized.includes("does not exist")

        if (!alreadyGone) {
          throw new Error(`Failed to delete auth user: ${deleteAuthUserError.message}`)
        }
      }

      if (imagePaths.length > 0) {
        const { error: removeImagesError } = await adminClient.storage
          .from("memories")
          .remove(imagePaths)

        if (removeImagesError) {
          warnings.push("Some storage objects could not be removed.")
        }
      }

      const completionWarning = warnings.length > 0 ? warnings.join(" ") : null

      const { error: completeJobError } = await adminClient
        .from("account_deletion_jobs")
        .update({
          status: "completed" as DeletionJobStatus,
          completed_at: new Date().toISOString(),
          last_error: completionWarning,
        })
        .eq("user_id", userID)

      if (completeJobError) {
        return jsonResponse(
          {
            success: true,
            warning: "Account deleted, but failed to mark deletion job completed.",
            details: completeJobError.message,
          },
          200
        )
      }

      return jsonResponse({
        success: true,
        warning: completionWarning,
        details: completionWarning,
      })
    } catch (jobError) {
      const message = jobError instanceof Error ? jobError.message : String(jobError)

      await adminClient
        .from("account_deletion_jobs")
        .update({
          status: "failed" as DeletionJobStatus,
          last_error: message,
        })
        .eq("user_id", userID)

      return jsonResponse(
        {
          error: "Failed to delete account",
          details: message,
        },
        500
      )
    }
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
