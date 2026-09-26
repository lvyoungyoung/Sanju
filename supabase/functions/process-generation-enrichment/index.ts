// Keep a tombstone so redeployment disables the previously published endpoint.
Deno.serve(async (req) => {
  if (req.method !== "POST") return Response.json({ error: "Method Not Allowed" }, { status: 405 })
  const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")
  if (!key || req.headers.get("Authorization") !== `Bearer ${key}`) {
    return Response.json({ error: "Unauthorized" }, { status: 401 })
  }
  return Response.json({ error: "Enrichment retries now start only when creating a study topic" }, { status: 410 })
})
