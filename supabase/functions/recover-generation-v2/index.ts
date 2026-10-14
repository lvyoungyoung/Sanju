import { authenticatedContentRequest } from "../_shared/generation/http.ts"
import { recoverGeneration, recoveryResponse } from "../_shared/generation/adapter.ts"
import { uuid } from "../_shared/content-contracts/memory.ts"
import { jsonResponse } from "../generate-memory-v2/responses.ts"

Deno.serve(req => authenticatedContentRequest(req, async ({body, user, client}) => {
  const anonymous = user.is_anonymous === true
  const requestID = uuid(anonymous ? body.guestJobID : body.clientRequestID)
  const result = await recoverGeneration(client, user.id, requestID, anonymous)
  return recoveryResponse(result) ?? jsonResponse({ recovered: false, status: "not_found" })
}))
