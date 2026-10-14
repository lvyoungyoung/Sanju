import { deepStrictEqual, rejects, strictEqual } from "node:assert";
import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import { consumeMemoryImageCleanup } from "../../supabase/functions/_shared/memory-image-cleanup.ts";

const owner = "00000000-0000-4000-8000-000000000001";
const image = "10000000-0000-4000-8000-000000000001";
const job = {
  id: crypto.randomUUID(),
  lease_id: crypto.randomUUID(),
  user_id: owner,
  bucket_id: "memories",
  image_path: `${owner}/${image}.jpg`,
};

function fake() {
  const state = {
    jobs: [{ ...job }],
    authorized: true,
    claimError: false,
    storageError: false,
    storageThrow: false,
    ackError: false,
    ackThrow: false,
    ackAccepted: true,
    removed: [] as string[],
    receipts: [] as any[],
  };
  const client = {
    rpc(name: string, args: any) {
      if (name === "claim_memory_image_cleanup_v2") {
        return Promise.resolve({
          data: state.jobs,
          error: state.claimError ? {} : null,
        });
      }
      if (name === "authorize_memory_image_cleanup_v2") {
        return Promise.resolve({ data: state.authorized, error: null });
      }
      if (name === "finish_memory_image_cleanup_v2") {
        state.receipts.push(args);
        if (state.ackThrow) throw new Error("private response details");
        return Promise.resolve({
          data: state.ackAccepted,
          error: state.ackError ? {} : null,
        });
      }
      throw new Error(`unexpected rpc ${name}`);
    },
    storage: {
      from(bucket: string) {
        strictEqual(bucket, "memories");
        return {
          remove(paths: string[]) {
            state.removed.push(...paths);
            if (state.storageThrow) throw new Error("private storage details");
            return Promise.resolve({
              data: [],
              error: state.storageError
                ? { message: "private storage details" }
                : null,
            });
          },
        };
      },
    },
  } as unknown as SupabaseClient;
  return { state, client };
}

Deno.test("multilingual cleanup: successful and already-absent images acknowledge exactly once", async () => {
  const { state, client } = fake();
  deepStrictEqual(await consumeMemoryImageCleanup(client, 1), {
    claimed: 1,
    completed: 1,
    failed: 0,
    hasMore: true,
  });
  deepStrictEqual(state.removed, [job.image_path]);
  deepStrictEqual(state.receipts, [{
    p_job_id: job.id,
    p_lease_id: job.lease_id,
    p_success: true,
    p_error: null,
  }]);
  state.jobs = [];
  deepStrictEqual(await consumeMemoryImageCleanup(client), {
    claimed: 0,
    completed: 0,
    failed: 0,
    hasMore: false,
  });
});

Deno.test("multilingual cleanup: reject unsafe paths and active references without touching Storage", async () => {
  for (
    const path of [
      `${owner}/../${image}.jpg`,
      `https://example.invalid/${image}.jpg`,
      `${image}/${image}.jpg`,
    ]
  ) {
    const { state, client } = fake();
    state.jobs[0].image_path = path;
    strictEqual((await consumeMemoryImageCleanup(client)).failed, 1);
    strictEqual(state.removed.length, 0);
    strictEqual(state.receipts[0].p_success, false);
  }
  const { state, client } = fake();
  state.authorized = false;
  strictEqual((await consumeMemoryImageCleanup(client)).failed, 1);
  strictEqual(state.removed.length, 0);
  strictEqual(state.receipts[0].p_error, "image_cleanup_not_authorized");
});

Deno.test("multilingual cleanup: partial failures, transport errors and lost leases remain retryable", async () => {
  for (
    const failure of [
      "storageError",
      "storageThrow",
      "ackError",
      "ackThrow",
      "ackAccepted",
    ] as const
  ) {
    const { state, client } = fake();
    state[failure] = failure !== "ackAccepted";
    const result = await consumeMemoryImageCleanup(client);
    strictEqual(result.completed, 0);
    strictEqual(result.failed, 1);
    strictEqual(state.receipts[0].p_success, !failure.startsWith("storage"));
    strictEqual(JSON.stringify(state.receipts).includes("private"), false);
  }
  const { state, client } = fake();
  state.claimError = true;
  await rejects(() => consumeMemoryImageCleanup(client), /Failed to claim/);
  strictEqual(state.removed.length, 0);
});

Deno.test("multilingual cleanup worker: service-only default invocation drains outbox even without guest jobs", async () => {
  const source = await Deno.readTextFile(
    new URL(
      "../../supabase/functions/cleanup-guest-generation-jobs/index.ts",
      import.meta.url,
    ),
  );
  const helper = new URL(
    "../../supabase/functions/_shared/memory-image-cleanup.ts",
    import.meta.url,
  ).href;
  const timeout = new URL(
    "../../supabase/functions/_shared/fetch-with-timeout.ts",
    import.meta.url,
  ).href;
  const module = await import(
    "data:application/typescript," + encodeURIComponent(`
    import {consumeMemoryImageCleanup} from ${JSON.stringify(helper)};
    import {fetchWithinDeadline} from ${JSON.stringify(timeout)};
    export let handler;
    export const state={claims:0,removals:0,ackSuccess:[],storageError:false};
    const Deno={env:{get:(name)=>name.endsWith('URL')?'http://offline.invalid':'fake-service-key'},serve:fn=>{handler=fn}};
    const createClient=()=>({
      rpc:async(name,args)=>{
        if(name==='claim_memory_image_cleanup_v2'){state.claims++;return {data:[${
      JSON.stringify(job)
    }],error:null}}
        if(name==='finish_memory_image_cleanup_v2')state.ackSuccess.push(args.p_success);
        return {data:true,error:null};
      },
      from:()=>({select:()=>{const query={lt:()=>query,order:()=>query,limit:async()=>({data:[],error:null})};return query}}),
      storage:{from:()=>({remove:async()=>{state.removals++;return {data:[],error:state.storageError?{}:null}}})}
    });
    ${source.replace(/^import .*\n/gm, "")}
  `)
  );
  for (const token of ["", "user-token", "fake-service-key-extra"]) {
    const response = await module.handler(
      new Request("http://offline.invalid", {
        method: "POST",
        headers: { Authorization: `Bearer ${token}` },
      }),
    );
    strictEqual(response.status, 401);
  }
  strictEqual(module.state.claims, 0);
  const request = () =>
    new Request("http://offline.invalid", {
      method: "POST",
      headers: { Authorization: "Bearer fake-service-key" },
    });
  const response = await module.handler(request());
  strictEqual(response.status, 200);
  const body = await response.json();
  strictEqual(body.deletedJobs, 0);
  strictEqual(body.memoryCleanup.completed, 1);
  strictEqual(module.state.removals, 1);
  module.state.storageError = true;
  strictEqual((await module.handler(request())).status, 500);
  deepStrictEqual(module.state.ackSuccess, [true, false]);
});
