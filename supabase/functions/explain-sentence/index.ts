import { createClient } from "npm:@supabase/supabase-js@2"
import { createExplanationHandler, type ExplanationClaim } from "./handler.ts"
import { generateExplanation, type ExplanationProvider } from "./model.ts"

const url = Deno.env.get("SUPABASE_LOCAL_URL") ?? Deno.env.get("SUPABASE_URL")
const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")
const providers: ExplanationProvider[] = []
for (const name of ["deepseek", "mimo", "kimi"] as const) {
  const prefix = name.toUpperCase()
  const endpoint = Deno.env.get(`${prefix}_BASE_URL`)
  const key = Deno.env.get(`${prefix}_API_KEY`)
  if (endpoint && key) providers.push({ name, url: endpoint, key })
}

Deno.serve(async (req) => {
  if (!url || !serviceKey) return Response.json({ code: "server_not_configured" }, { status: 503 })
  const admin = createClient(url, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false },
    global: { fetch: (input, init) => fetch(input, { ...init, signal: AbortSignal.timeout(5000) }) },
  })
  const rpc = async (name: string, args: Record<string, unknown>) => {
    const { data, error } = await admin.rpc(name, args)
    if (error) throw new Error(`${name}: ${error.message}`)
    return data
  }
  return await createExplanationHandler({
    async authenticate(token) {
      const { data, error } = await admin.auth.getUser(token)
      if (error || !data.user) return null
      return { id: data.user.id, anonymous: data.user.is_anonymous === true }
    },
    async source(userID, sentenceID) {
      const { data, error } = await admin.from("memory_sentences")
        .select("english,chinese,memories!inner(user_id)").eq("id", sentenceID).eq("memories.user_id", userID).maybeSingle()
      if (error) throw new Error(`Sentence lookup: ${error.message}`)
      return data ? { english: data.english, chinese: data.chinese } : null
    },
    async claim(userID, fingerprint, generate) {
      return await rpc("claim_sentence_explanation", {
        p_user_id: userID, p_fingerprint: fingerprint, p_generate: generate,
      }) as ExplanationClaim
    },
    generate: (input) => generateExplanation(input, providers),
    async finish(userID, fingerprint, claimID, content) {
      return await rpc("finish_sentence_explanation", {
        p_user_id: userID, p_fingerprint: fingerprint, p_claim_id: claimID, p_content: content,
      }) === true
    },
    async release(userID, fingerprint, claimID) {
      const { error } = await admin.from("sentence_explanations").delete()
        .eq("user_id", userID).eq("fingerprint", fingerprint).eq("claim_id", claimID).is("content", null)
      if (error) throw new Error(error.message)
    },
  })(req)
})
