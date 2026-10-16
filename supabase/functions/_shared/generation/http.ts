import { createClient } from "npm:@supabase/supabase-js@2"
import { fetchWithTimeout } from "../fetch-with-timeout.ts"
import { ContractError, record } from "../content-contracts/memory.ts"
import { jsonResponse } from "../generate-memory-v2/responses.ts"
import { readAssistanceJSON } from "../assistance-input.ts"

export async function authenticatedContentRequest(req: Request, operation: (args: { body: Record<string, any>; user: any; client: any; authClient: any }) => Promise<Response>, maxBodyBytes = 6 * 1024 * 1024): Promise<Response> {
  try {
    if (req.method !== "POST") return jsonResponse({ error: "Method Not Allowed" }, 405)
    const url = Deno.env.get("SUPABASE_LOCAL_URL") ?? Deno.env.get("SUPABASE_URL")
    const anon = Deno.env.get("SUPABASE_ANON_KEY")
    const service = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")
    if (!url || !anon || !service) throw new Error("Missing server configuration")
    const token = req.headers.get("Authorization")?.match(/^Bearer (.+)$/)?.[1]
    if (!token) throw new ContractError("invalid_jwt", 401)
    const options = { global: { fetch: (input: RequestInfo | URL, init?: RequestInit) => fetchWithTimeout(input, init, 15000) } }
    const authClient = createClient(url, anon, options)
    const { data: { user }, error } = await authClient.auth.getUser(token)
    if (error || !user) throw new ContractError("invalid_jwt", 401)
    let body: Record<string, any>
    try { body = record(await readAssistanceJSON(req, maxBodyBytes)) } catch { throw new ContractError("invalid_request") }
    return await operation({ body, user, authClient, client: createClient(url, service, options) })
  } catch (error) {
    if (error instanceof ContractError) return jsonResponse({ error: error.code, code: error.code }, error.status)
    console.error("[multilingual-content] request failed")
    return jsonResponse({ error: "Content service unavailable", code: "service_unavailable" }, 503)
  }
}
