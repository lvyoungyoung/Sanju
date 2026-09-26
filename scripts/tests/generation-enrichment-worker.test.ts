import { deepStrictEqual, strictEqual } from "node:assert";

const source = await Deno.readTextFile(
  new URL(
    "../../supabase/functions/_shared/generation-enrichment.ts",
    import.meta.url,
  ),
);
const helper = new URL(
  "../../supabase/functions/_shared/fetch-with-timeout.ts",
  import.meta.url,
).href;
const metadataHelper = new URL(
  "../../supabase/functions/_shared/sentence-metadata.ts",
  import.meta.url,
).href;
const timingHelper = new URL("../../supabase/functions/_shared/generation-enrichment-timing.ts", import.meta.url).href;
const api = await import(
  "data:application/typescript," + encodeURIComponent(`
  import {fetchWithTimeout, fetchWithinDeadline} from ${JSON.stringify(helper)};
  import {EnrichmentTiming, type EnrichmentStage} from ${JSON.stringify(timingHelper)};
  export {EnrichmentTiming};
  import {generateSentenceMetadata as generateMetadata, parseSentenceMetadata} from ${
    JSON.stringify(metadataHelper)
  };
  const generateSentenceMetadata = (sentences: any, fetcher: any) => generateMetadata(sentences, fetcher, {url:"https://model.invalid",key:"test"});
  export const state: any = {tasks:[], client:null};
  const globalThis = {EdgeRuntime: undefined as any};
  export function runtime(enabled: boolean) {
    globalThis.EdgeRuntime = enabled ? {waitUntil(task: Promise<unknown>) {state.tasks.push(task)}} : undefined;
  }
  const Deno = {env:{get:()=>"test"}};
  function createClient() {state.clientCalls++; return state.client;}
  ${source.replace(/^import .*\n/gm, "")}
`)
);
const vector = [1, ...Array(1023).fill(0)];
const initialScope = { userID: "owner", memoryID: "memory" };
const sceneScope = { userID: "owner", sceneID: "scene" };
const sentences = [{
  id: "sentence",
  english: "This is a cat.",
  chinese: "这是一只猫。",
}];
function fixture(
  failure:
    | "sentence"
    | "purpose"
    | "store"
    | "metadata"
    | "checkpoint"
    | "stale"
    | null = null,
  total = 1,
  cached = false,
) {
  const calls: string[] = [], finished: any[] = [], retried: any[] = [], reports: any[] = [];
  const expectedMetadata = [{
    sentence_id: "sentence",
    expression_purpose: "Describing a cat.",
    learning_topic_ids: ["pet_life"],
  }];
  const modelCalls: string[] = [];
  let metadata = cached ? expectedMetadata : null;
  let claims = 0;
  const client = {
    rpc: async (name: string, args: any) => {
      calls.push(name);
      if (name === "claim_scoped_generation_enrichment") {
        strictEqual(args.p_user_id, "owner");
        strictEqual(
          [args.p_memory_id, args.p_guest_job_id, args.p_scene_id].filter(
            Boolean,
          ).length,
          1,
        );
        return {
          data: claims++ < total
            ? [{
              id: `10000000-0000-0000-0000-${String(claims).padStart(12, "0")}`,
              lease_token: "lease",
              attempts: 1,
              sentences,
              metadata,
            }]
            : [],
          error: null,
        };
      }
      if (name === "save_generation_enrichment_metadata") {
        if (failure === "checkpoint") {
          return { error: { message: "checkpoint failed" } };
        }
        if (failure === "stale") return { data: false, error: null };
        metadata = args.p_metadata;
        return { data: true, error: null };
      }
      if (name === "complete_generation_enrichment") {
        finished.push(args);
        return {
          data: failure !== "store",
          error: failure === "store" ? { message: "db unavailable" } : null,
        };
      }
      if (name === "retry_generation_enrichment") {
        retried.push(args);
        return { error: null };
      }
      if (name === "save_generation_enrichment_timing") {
        reports.push(args);
        return { error: null };
      }
      throw new Error(`Unexpected RPC: ${name}`);
    },
  };
  const fetcher: typeof fetch = async (_input, init) => {
    const body = JSON.parse(String((init as { body?: unknown })?.body));
    if (body.messages) {
      modelCalls.push("metadata");
      if (failure === "metadata") return Response.json({}, { status: 503 });
      return Response.json({
        choices: [{
          message: { content: JSON.stringify({ sentences: expectedMetadata }) },
        }],
      });
    }
    const route = body.input.texts[0].startsWith("English:")
      ? "sentence"
      : "purpose";
    modelCalls.push(route);
    if (route === failure) return Response.json({}, { status: 503 });
    return Response.json({
      output: {
        embeddings: body.input.texts.map((_: any, i: number) => ({
          text_index: i,
          embedding: vector,
        })),
      },
    });
  };
  return { client, fetcher, calls, finished, retried, modelCalls, reports };
}

Deno.test("staging diagnostics measure all stages including failures without changing results", async () => {
  for (const failure of [null, "metadata", "purpose", "store", "stale"] as const) {
    const f = fixture(failure);
    const events: any[] = [];
    const timing = new api.EnrichmentTiming({}, () => performance.now(), (event: any) => events.push(event), true);
    await api.processGenerationEnrichment(f.client, initialScope, f.fetcher, Date.now() + 45_000, timing);
    strictEqual(f.reports.length, 1);
    const stages = f.reports[0].p_report.stages;
    strictEqual(stages[0].stage, "claim");
    strictEqual(stages.at(-1).stage, "job_total");
    strictEqual(stages.at(-1).outcome, failure === "stale" ? "lease_lost" : failure ? "failed" : "completed");
    strictEqual(stages.every((stage: any) => Number.isFinite(stage.ms) && stage.ms >= 0), true);
    if (!failure) {
      deepStrictEqual(stages.map((stage: any) => stage.stage).sort(), ["claim", "metadata_generate", "metadata_checkpoint", "sentence_embedding", "purpose_embedding", "embeddings_parallel", "publish_and_match", "job_total"].sort());
    }
    strictEqual(JSON.stringify(events).includes("This is a cat"), false);
    strictEqual(JSON.stringify(events).includes("lease"), failure === "stale");
  }
});

Deno.test("production diagnostics neither log nor write reports; diagnostic storage failure is nonfatal", async () => {
  const f = fixture();
  const events: any[] = [];
  await api.processGenerationEnrichment(f.client, initialScope, f.fetcher, Date.now() + 45_000,
    new api.EnrichmentTiming({}, () => performance.now(), (event: any) => events.push(event), false));
  strictEqual(events.length, 0);
  strictEqual(f.reports.length, 0);
  const g = fixture();
  const original = g.client.rpc;
  g.client.rpc = (name: string, args: any) => name === "save_generation_enrichment_timing"
    ? Promise.reject(new Error("diagnostics unavailable")) : original(name, args);
  deepStrictEqual(await api.processGenerationEnrichment(g.client, initialScope, g.fetcher, Date.now() + 45_000,
    new api.EnrichmentTiming({}, () => performance.now(), () => {}, true)), {completed: 1, failed: 0});
  strictEqual(g.retried.length, 0);
});

Deno.test("worker uses leased persisted payload and atomically completes both vectors", async () => {
  const f = fixture();
  deepStrictEqual(
    await api.processGenerationEnrichment(f.client, initialScope, f.fetcher),
    { completed: 1, failed: 0 },
  );
  strictEqual(f.finished[0].p_lease_token, "lease");
  strictEqual(f.finished[0].p_rows[0].sentence_id, "sentence");
  strictEqual(f.finished[0].p_rows[0].purpose_embedding.length, 1024);
  strictEqual(f.retried.length, 0);
  deepStrictEqual(f.modelCalls, ["metadata", "sentence", "purpose"]);
  strictEqual(f.calls[1], "save_generation_enrichment_metadata");
});

Deno.test("incomplete vectors and database failure remain retryable without finalizing or debiting", async () => {
  for (
    const failure of [
      "sentence",
      "purpose",
      "store",
      "metadata",
      "checkpoint",
    ] as const
  ) {
    const f = fixture(failure);
    deepStrictEqual(
      await api.processGenerationEnrichment(f.client, initialScope, f.fetcher),
      { completed: 0, failed: 1 },
    );
    strictEqual(f.retried.length, 1);
    strictEqual(f.retried[0].p_lease_token, "lease");
    strictEqual(f.finished.length, failure === "store" ? 1 : 0);
    strictEqual(f.calls.some((c) => c.startsWith("finalize_")), false);
  }
});

Deno.test("checkpointed metadata is reused on retries; lost leases do not start embeddings", async () => {
  const cached = fixture(null, 1, true);
  deepStrictEqual(
    await api.processGenerationEnrichment(
      cached.client,
      initialScope,
      cached.fetcher,
    ),
    { completed: 1, failed: 0 },
  );
  deepStrictEqual(cached.modelCalls, ["sentence", "purpose"]);
  strictEqual(
    cached.calls.includes("save_generation_enrichment_metadata"),
    false,
  );
  const stale = fixture("stale");
  deepStrictEqual(
    await api.processGenerationEnrichment(
      stale.client,
      initialScope,
      stale.fetcher,
    ),
    { completed: 0, failed: 0 },
  );
  deepStrictEqual(stale.modelCalls, ["metadata"]);
  strictEqual(stale.finished.length, 0);
});

Deno.test("worker bounds drain batches and refuses to start a batch with an exhausted budget", async () => {
  const f = fixture(null, 100);
  deepStrictEqual(
    await api.processGenerationEnrichment(f.client, sceneScope, f.fetcher),
    { completed: 3, failed: 0 },
  );
  strictEqual(f.finished.length, 3);
  const g = fixture();
  await api.processGenerationEnrichment(
    g.client,
    sceneScope,
    g.fetcher,
    Date.now(),
  );
  strictEqual(g.calls.length, 0);
  const initial = fixture(null, 100);
  await api.processGenerationEnrichment(
    initial.client,
    initialScope,
    initial.fetcher,
  );
  strictEqual(initial.finished.length, 1);
});

Deno.test("background registration returns immediately while slow work is still running", async () => {
  let rpcCalls = 0;
  let release!: () => void;
  const slow = new Promise<void>((resolve) => {
    release = resolve;
  });
  api.state.tasks = [];
  api.state.clientCalls = 0;
  api.state.client = {
    rpc: async () => {
      rpcCalls++;
      await slow;
      return { data: [], error: null };
    },
  };
  api.runtime(true);
  strictEqual(api.scheduleGenerationEnrichment(initialScope), undefined);
  strictEqual(api.state.tasks.length, 1);
  await Promise.resolve();
  strictEqual(api.state.clientCalls, 1);
  release();
  await Promise.all(api.state.tasks);
  strictEqual(rpcCalls, 1);
});

Deno.test("unsupported background runtime leaves durable work for topic creation rather than blocking response", () => {
  api.state.tasks = [];
  api.state.clientCalls = 0;
  api.runtime(false);
  api.scheduleGenerationEnrichment(initialScope);
  strictEqual(api.state.tasks.length, 0);
  strictEqual(api.state.clientCalls, 0);
});

Deno.test("failed background startup is contained, not an unhandled rejection", async () => {
  let rpcCalls = 0;
  api.runtime(true);
  api.state.tasks = [];
  api.state.client = {
    rpc: async () => {
      rpcCalls++;
      throw new Error("gateway unavailable");
    },
  };
  api.scheduleGenerationEnrichment(initialScope);
  await Promise.all(api.state.tasks);
  strictEqual(rpcCalls, 1);
});

Deno.test("retired retry endpoint rejects users and no longer processes work even for administrators", async () => {
  const endpoint = await Deno.readTextFile(
    new URL(
      "../../supabase/functions/process-generation-enrichment/index.ts",
      import.meta.url,
    ),
  );
  const test = await import(
    "data:application/typescript," + encodeURIComponent(`
    export let handler: any; export let calls=0;
    const Deno={env:{get:()=>"service-secret"},serve(fn:any){handler=fn}};
    async function runGenerationEnrichment(){calls++;return {completed:1,failed:0}};
    ${endpoint.replace(/^import .*\n/gm, "")}
  `)
  );
  for (const token of ["anon", "user-jwt", ""]) {
    strictEqual(
      (await test.handler(
        new Request("https://test.invalid", {
          method: "POST",
          headers: { Authorization: `Bearer ${token}` },
        }),
      )).status,
      401,
    );
  }
  strictEqual(
    (await test.handler(new Request("https://test.invalid"))).status,
    405,
  );
  strictEqual(test.calls, 0);
  strictEqual(
    (await test.handler(
      new Request("https://test.invalid", {
        method: "POST",
        headers: { Authorization: "Bearer service-secret" },
      }),
    )).status,
    410,
  );
  strictEqual(test.calls, 0);
});
