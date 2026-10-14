import { withGenerationTiming } from "../_shared/generation-timing.ts"
import { handleGenerationRequest } from "../_shared/generate-memory-v2/handler.ts"

Deno.serve(req => withGenerationTiming(req, (request, timing) => handleGenerationRequest(request, timing, 3)))
