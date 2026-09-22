import { createClient } from "npm:@supabase/supabase-js@2";
import { createSpeechHandler } from "./handler.ts";

Deno.serve(async (req) => {
  const url = Deno.env.get("SUPABASE_LOCAL_URL") ?? Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !serviceKey) {
    console.warn("[synthesize-speech] Supabase internal configuration missing");
    return Response.json({ error: "speech_not_configured" }, { status: 503 });
  }
  const admin = createClient(url, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false },
    global: {
      fetch: (input, init) => fetch(input, { ...init, signal: AbortSignal.timeout(5000) }),
    },
  });
  return await createSpeechHandler({
    // Like image generation, this is the full chat/completions URL, with no hardcoded fallback.
    url: Deno.env.get("MIMO_BASE_URL") ?? "",
    apiKey: Deno.env.get("MIMO_API_KEY") ?? "",
    async authenticate(token) {
      const { data, error } = await admin.auth.getUser(token);
      return error ? null : data.user?.id ?? null;
    },
    async consumeBudget(userID) {
      const { data, error } = await admin.rpc("consume_speech_request", { p_user_id: userID });
      if (error) {
        console.warn("[synthesize-speech] consume_speech_request failed", { code: error.code });
        throw new Error("speech_budget_unavailable");
      }
      return data === true;
    },
  })(req);
});
