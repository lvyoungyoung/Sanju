import { deepStrictEqual, strictEqual, throws } from "node:assert";
import { GenerationTiming, withGenerationTiming } from "../../supabase/functions/_shared/generation-timing.ts";

Deno.test("timing uses elapsed stages, accumulates repeats and measures the whole handler", () => {
  let now = 100;
  const timing = new GenerationTiming(() => now);
  now = 105;
  timing.start("auth");
  now = 112;
  timing.start("mimo");
  now = 212;
  timing.start("auth");
  now = 215;
  strictEqual(timing.header(), "setup;dur=5.0, auth;dur=10.0, mimo;dur=100.0, total;dur=115.0");
  throws(() => timing.start("unsafe;dur=99"), /Invalid timing stage/);
});

Deno.test("opt-in metadata preserves success/error bodies and headers, and waits for finally", async () => {
  const id = "AB000000-0000-0000-0000-000000000001";
  for (const status of [200, 403, 500]) {
    let cleanupComplete = false;
    const response = await withGenerationTiming(new Request("https://example.invalid", {
      headers: { "X-Sanju-Generation-Timing": "1", "X-Sanju-Generation-Trace-ID": id },
    }), async (_req, timing) => {
      try {
        timing.start("moderation");
        return Response.json({ status }, { status, headers: { "x-existing": "preserved" } });
      } finally {
        timing.start("release_slot");
        await Promise.resolve();
        cleanupComplete = true;
      }
    });
    strictEqual(cleanupComplete, true);
    strictEqual(response.status, status);
    strictEqual(response.headers.get("x-existing"), "preserved");
    strictEqual(response.headers.get("x-sanju-generation-trace-id"), id.toLowerCase());
    strictEqual(response.headers.get("Server-Timing")?.includes("release_slot;dur="), true);
    strictEqual(response.headers.get("X-Sanju-Generation-Timing"), "1");
    deepStrictEqual(await response.json(), { status });
  }
});

Deno.test("old requests retain the original response and trace IDs cannot inject arbitrary content", async () => {
  const original = Response.json({ memory: { sentences: [] } });
  strictEqual(await withGenerationTiming(new Request("https://example.invalid"), () => Promise.resolve(original)), original);
  strictEqual(original.headers.get("Server-Timing"), null);
  for (const trace of ["", "private text", "123\tunsafe"]) {
    const response = await withGenerationTiming(new Request("https://example.invalid", {
      headers: { "X-Sanju-Generation-Timing": "1", "X-Sanju-Generation-Trace-ID": trace },
    }), () => Promise.resolve(new Response(null, { status: 204 })));
    strictEqual(response.status, 204);
    strictEqual(response.headers.get("X-Sanju-Generation-Trace-ID"), null);
    strictEqual(await response.text(), "");
  }
});
