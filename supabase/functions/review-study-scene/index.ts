import { createClient } from "npm:@supabase/supabase-js@2";
import { type ReviewCandidate, reviewCandidates } from "./review.ts";

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return Response.json({ error: "Method Not Allowed" }, { status: 405 });
  }
  let adminClient: any;
  let userID: string | undefined;
  let claimed: ReviewCandidate[] = [];
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
    const { data, error } = await adminClient.rpc(
      "claim_study_scene_sentence_reviews",
      { p_user_id: userID, p_scene_id: sceneID },
    );
    if (error) throw error;
    claimed = data ?? [];
    let reviewedCount = 0;
    if (claimed.length > 0) {
      const mimoURL = Deno.env.get("MIMO_BASE_URL");
      const mimoKey = Deno.env.get("MIMO_API_KEY");
      if (!mimoURL || !mimoKey) {
        throw new Error("Missing MiMo review configuration");
      }
      const decisions = await reviewCandidates(claimed, {
        url: mimoURL,
        apiKey: mimoKey,
      });
      const completed = await adminClient.rpc(
        "complete_study_scene_sentence_reviews",
        { p_user_id: userID, p_decisions: decisions },
      );
      if (completed.error) throw completed.error;
      reviewedCount = completed.data ?? 0;
    }
    return Response.json(
      await statusResponse(adminClient, userID, sceneID, reviewedCount),
    );
  } catch (error) {
    console.error(
      "[review-study-scene]",
      error instanceof Error
        ? error.message
        : "Database review operation failed",
    );
    if (adminClient && userID && claimed.length > 0) {
      const deferred = await adminClient.rpc(
        "defer_study_scene_sentence_reviews",
        { p_user_id: userID, p_claims: claimed },
      );
      if (deferred.error) {
        console.error(
          "[review-study-scene] Unable to release batch; lease will expire",
        );
      }
      try {
        const status = await statusResponse(adminClient, userID, sceneID, 0);
        return Response.json({
          ...status,
          retryAfterSeconds: Math.max(30, status.retryAfterSeconds),
        });
      } catch { /* The persisted lease makes a later retry safe. */ }
    }
    return Response.json({ error: "Unable to review study theme sentences" }, {
      status: 503,
    });
  }
});

async function statusResponse(
  adminClient: any,
  userID: string,
  sceneID: string | null,
  reviewedCount: number,
) {
  const { data, error } = await adminClient.rpc(
    "get_study_scene_review_status",
    { p_user_id: userID, p_scene_id: sceneID },
  );
  if (error) throw error;
  const status = data?.[0];
  if (!status) throw new Error("Missing review status");
  return {
    reviewedCount,
    pendingCount: status.pending_count,
    retryAfterSeconds: status.retry_after_seconds,
  };
}
