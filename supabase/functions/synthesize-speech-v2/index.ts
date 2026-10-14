import { createClient } from "npm:@supabase/supabase-js@2"
import { createSpeechV2Handler } from "./handler.ts"

Deno.serve(async req => {
  const url = Deno.env.get("SUPABASE_LOCAL_URL") ?? Deno.env.get("SUPABASE_URL")
  const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")
  if (!url || !key) return Response.json({ code: "server_not_configured" }, { status: 503 })
  const admin = createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false },
    global: { fetch: (input, init) => fetch(input, { ...init, signal: AbortSignal.timeout(5000) }) } })
  return createSpeechV2Handler({
    providers: {
      mimo: { url: Deno.env.get("MIMO_BASE_URL") ?? "", apiKey: Deno.env.get("MIMO_API_KEY") ?? "" },
      // Full /v1/audio/speech endpoint. No assumption that the existing MiMo proxy handles this route.
      openai: { url: Deno.env.get("OPENAI_TTS_URL") ?? "", apiKey: Deno.env.get("OPENAI_TTS_API_KEY") ?? "" },
    },
    validatedProfiles: new Set((Deno.env.get("SPEECH_V2_VALIDATED_PROFILES") ?? "").split(",").map(s => s.trim()).filter(Boolean)),
    async authenticate(token) {
      const { data, error } = await admin.auth.getUser(token)
      return error ? null : data.user?.id ?? null
    },
    async consumeBudget(userID) {
      const { data, error } = await admin.rpc("consume_speech_request", { p_user_id: userID })
      if (error) throw new Error("speech_budget_unavailable")
      return data === true
    },
  })(req)
})
