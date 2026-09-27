import { withGenerationTiming } from "../_shared/generation-timing.ts"
import { handleGenerationRequest } from "./handler.ts"

Deno.serve((req) => withGenerationTiming(req, handleGenerationRequest))
