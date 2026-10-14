import { createClient } from "npm:@supabase/supabase-js@2"
import { createExplanationV2Handler } from "./handler.ts"
import type { ExplanationSource } from "./content.ts"
import type { ExplanationClaim } from "../explain-sentence/handler.ts"
import type { ExplanationProvider } from "../explain-sentence/model.ts"
import { generateExplanation } from "./model.ts"

Deno.serve(async req => {
  const url = Deno.env.get("SUPABASE_LOCAL_URL") ?? Deno.env.get("SUPABASE_URL")
  const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")
  if (!url || !key) return Response.json({ code: "server_not_configured" }, { status: 503 })
  const admin = createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false },
    global: { fetch: (input, init) => fetch(input, { ...init, signal: AbortSignal.timeout(5000) }) } })
  const providers: ExplanationProvider[] = []
  for (const name of ["mimo", "deepseek", "kimi"] as const) {
    const endpoint = Deno.env.get(`${name.toUpperCase()}_BASE_URL`)
    const apiKey = Deno.env.get(`${name.toUpperCase()}_API_KEY`)
    if (endpoint && apiKey) providers.push({ name, url: endpoint, key: apiKey })
  }
  const rpc = async (name: string, args: Record<string, unknown>) => {
    const { data, error } = await admin.rpc(name, args)
    if (error) throw new Error("explanation_database_unavailable")
    return data
  }
  return createExplanationV2Handler({
    async authenticate(token) {
      const { data, error } = await admin.auth.getUser(token)
      return error || !data.user ? null : { id: data.user.id, anonymous: data.user.is_anonymous === true }
    },
    async source(userID, sentenceID) {
      return await rpc("sentence_explanation_source_v2", { p_user_id: userID, p_sentence_id: sentenceID }) as ExplanationSource | null
    },
    async claim(userID, fingerprint, generate) {
      return await rpc("claim_sentence_explanation", { p_user_id: userID, p_fingerprint: fingerprint, p_generate: generate }) as ExplanationClaim
    },
    generate: input => generateExplanation(input, providers),
    async finish(userID, fingerprint, claimID, content) {
      return await rpc("finish_sentence_explanation_v2", {
        p_user_id: userID, p_fingerprint: fingerprint, p_claim_id: claimID, p_content: content,
      }) === true
    },
    async release(userID, fingerprint, claimID) {
      const { error } = await admin.from("sentence_explanations").delete().eq("user_id", userID)
        .eq("fingerprint", fingerprint).eq("claim_id", claimID).is("content", null)
      if (error) throw new Error("explanation_release_failed")
    },
  })(req)
})
