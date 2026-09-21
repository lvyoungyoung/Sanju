import { createClient } from "npm:@supabase/supabase-js@2";

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return Response.json({ error: "Method Not Allowed" }, { status: 405 });
  }
  let adminClient: any;
  let userID: string | undefined;
  let sceneID: string | null = null;
  try {
    const url = Deno.env.get("SUPABASE_LOCAL_URL") ??
      Deno.env.get("SUPABASE_URL");
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if (!url || !anonKey || !serviceKey) {
      throw new Error("Missing server configuration");
    }
    const authorization = req.headers.get("Authorization");
    if (!authorization?.startsWith("Bearer ")) {
      return Response.json({ error: "Missing Authorization header" }, {
        status: 401,
      });
    }
    let body: any;
    try {
      body = await req.json();
    } catch {
      return Response.json({ error: "Invalid JSON body" }, { status: 400 });
    }
    if (body?.sceneID !== undefined && body.sceneID !== null) {
      if (
        typeof body.sceneID !== "string" ||
        !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(
          body.sceneID,
        )
      ) {
        return Response.json({ error: "Invalid scene ID" }, { status: 400 });
      }
      sceneID = body.sceneID;
    }
    const userClient = createClient(url, anonKey);
    const { data: { user }, error: authError } = await userClient.auth.getUser(
      authorization.slice(7).trim(),
    );
    if (authError || !user || user.is_anonymous) {
      return Response.json({ error: "Sign in required" }, { status: 401 });
    }
    userID = user.id;
    adminClient = createClient(url, serviceKey);
    if (sceneID) {
      const { data: scene, error } = await adminClient.from("study_scenes")
        .select("id")
        .eq("id", sceneID).eq("user_id", userID).maybeSingle();
      if (error) throw error;
      if (!scene) {
        return Response.json({ error: "Study theme not found" }, {
          status: 404,
        });
      }
    }
    // Compatibility endpoint for older clients. AI review is paused; matching
    // is handled directly by the semantic SQL functions, without model calls.
    return Response.json({
      reviewedCount: 0,
      pendingCount: 0,
      retryAfterSeconds: 0,
    });
  } catch (error) {
    console.error(
      "[review-study-scene]",
      error instanceof Error
        ? error.message
        : "Database review operation failed",
    );
    return Response.json({ error: "Unable to review study theme sentences" }, {
      status: 503,
    });
  }
});
