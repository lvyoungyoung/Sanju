import { runGenerationEnrichment } from "../_shared/generation-enrichment.ts"

// Administrative retry sweep, never callable with a user's JWT or anon key.
Deno.serve(async (req) => {
  if (req.method !== "POST") return Response.json({ error: "Method Not Allowed" }, { status: 405 })
  const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")
  if (!key || req.headers.get("Authorization") !== `Bearer ${key}`) {
    return Response.json({ error: "Unauthorized" }, { status: 401 })
  }
  try {
    return Response.json(await runGenerationEnrichment())
  } catch (error) {
    console.error("[generation-enrichment] sweep failed", error instanceof Error ? error.message : String(error))
    return Response.json({ error: "Indexing sweep failed" }, { status: 500 })
  }
})
