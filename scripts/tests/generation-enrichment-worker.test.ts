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
const api = await import(
  "data:application/typescript," + encodeURIComponent(`
  import {fetchWithTimeout, fetchWithinDeadline} from ${JSON.stringify(helper)};
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
  const calls: string[] = [], finished: any[] = [], retried: any[] = [];
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
      if (name === "claim_generation_enrichment") {
        return {
          data: claims++ < total
            ? [{
              id: String(claims),
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
  return { client, fetcher, calls, finished, retried, modelCalls };
}

Deno.test("worker uses leased persisted payload and atomically completes both vectors", async () => {
  const f = fixture();
  deepStrictEqual(
    await api.processGenerationEnrichment(f.client, "owner", f.fetcher),
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
      await api.processGenerationEnrichment(f.client, "owner", f.fetcher),
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
      "owner",
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
    await api.processGenerationEnrichment(stale.client, "owner", stale.fetcher),
    { completed: 0, failed: 0 },
  );
  deepStrictEqual(stale.modelCalls, ["metadata"]);
  strictEqual(stale.finished.length, 0);
});

Deno.test("worker bounds drain batches and refuses to start a batch with an exhausted budget", async () => {
  const f = fixture(null, 100);
  deepStrictEqual(
    await api.processGenerationEnrichment(f.client, null, f.fetcher),
    { completed: 3, failed: 0 },
  );
  strictEqual(f.finished.length, 3);
  const g = fixture();
  await api.processGenerationEnrichment(g.client, null, g.fetcher, Date.now());
  strictEqual(g.calls.length, 0);
});

Deno.test("background registration returns immediately while slow work is still running", async () => {
  let release!: () => void;
  const slow = new Promise<void>((resolve) => {
    release = resolve;
  });
  api.state.tasks = [];
  api.state.clientCalls = 0;
  api.state.client = {
    rpc: async () => {
      await slow;
      return { data: [], error: null };
    },
  };
  api.runtime(true);
  strictEqual(api.scheduleGenerationEnrichment("owner"), undefined);
  strictEqual(api.state.tasks.length, 1);
  await Promise.resolve();
  strictEqual(api.state.clientCalls, 1);
  release();
  await Promise.all(api.state.tasks);
});

Deno.test("unsupported background runtime leaves durable work for sweeper rather than blocking response", () => {
  api.state.tasks = [];
  api.state.clientCalls = 0;
  api.runtime(false);
  api.scheduleGenerationEnrichment("owner");
  strictEqual(api.state.tasks.length, 0);
  strictEqual(api.state.clientCalls, 0);
});

Deno.test("failed background startup is contained, not an unhandled rejection", async () => {
  api.runtime(true);
  api.state.tasks = [];
  api.state.client = {
    rpc: async () => {
      throw new Error("gateway unavailable");
    },
  };
  api.scheduleGenerationEnrichment("owner");
  await Promise.all(api.state.tasks);
});

Deno.test("administrative retry endpoint rejects user credentials and non-POST requests", async () => {
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
    200,
  );
  strictEqual(test.calls, 1);
});
