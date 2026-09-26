import { deepStrictEqual, rejects, strictEqual } from "node:assert";
import { EnrichmentTiming, isStagingEnrichmentEnvironment } from "../../supabase/functions/_shared/generation-enrichment-timing.ts";

Deno.test("enrichment timing only enables for trusted staging configuration, not production or lookalike hosts", () => {
  for (const url of ["https://api-staging.sanju.cc", "https://spb-bp1364k407p37qn7.supabase.opentrust.net"]) {
    strictEqual(isStagingEnrichmentEnvironment(url), true);
  }
  for (const url of ["", "http://kong:8000", "https://api.sanju.cc", "https://spb-bp103246ivn7q0nl.supabase.opentrust.net", "https://api-staging.sanju.cc.evil.test"]) {
    strictEqual(isStagingEnrichmentEnvironment(url), false);
  }
});

Deno.test("parallel branch durations are independent and report wall time rather than their sum", async () => {
  let now = 0;
  const events: any[] = [];
  const timing = new EnrichmentTiming({requestID:"invalid private content", jobID:"10000000-0000-0000-0000-000000000001", attempt:1}, () => now, (event) => events.push(event), true);
  let resolveA!: () => void, resolveB!: () => void;
  const work = timing.measure("embeddings_parallel", async () => {
    await Promise.all([
      timing.measure("sentence_embedding", () => new Promise<void>((resolve) => {resolveA = resolve})),
      timing.measure("purpose_embedding", () => new Promise<void>((resolve) => {resolveB = resolve})),
    ]);
  });
  now = 10; resolveA(); await Promise.resolve();
  now = 25; resolveB(); await work;
  timing.finish("completed");
  deepStrictEqual(events.filter((event) => event.event === "end").map((event) => [event.stage,event.ms]), [
    ["sentence_embedding",10], ["purpose_embedding",25], ["embeddings_parallel",25], ["job_total",25],
  ]);
  strictEqual(JSON.stringify(timing.report()).includes("private content"), false);
});

Deno.test("timing records failed stages but never replaces the original error", async () => {
  let now = 0;
  const timing = new EnrichmentTiming({}, () => now, () => {throw new Error("logging failed")}, true);
  const failure = new Error("provider secret error");
  await rejects(timing.measure("metadata_generate", async () => {now = 100; throw failure}), (error) => error === failure);
  strictEqual(JSON.stringify(timing.report()).includes("provider secret"), false);
  deepStrictEqual((timing.report().stages as any[]).map((stage) => [stage.ms,stage.outcome]), [[100,"failed"]]);
});
