import { deepStrictEqual, strictEqual } from "node:assert";
import { readFunctionSource } from "./helpers/function-source.ts";

// Exercise the actual HTTP handler with overlapping requests. All auth, storage,
// database and model calls are local doubles; transaction rules are tested in PG.
const source = await readFunctionSource(
  new URL(
    "../../supabase/functions/generate-memory-v2/index.ts",
    import.meta.url,
  ),
);
const httpHelper = new URL(
  "../../supabase/functions/_shared/fetch-with-timeout.ts",
  import.meta.url,
).href;
const timingHelper = new URL(
  "../../supabase/functions/_shared/generation-timing.ts",
  import.meta.url,
).href;
const harness = `
import { strictEqual } from "node:assert";
import { buildSentenceMetadataRules } from ${
  JSON.stringify(
    new URL(
      "../../supabase/functions/_shared/sentence-metadata.ts",
      import.meta.url,
    ).href,
  )
};
import { GenerationTiming, withGenerationTiming } from ${
  JSON.stringify(timingHelper)
};
import { fetchWithTimeout as boundedFetch, fetchWithinDeadline as deadlineFetch } from ${
  JSON.stringify(httpHelper)
};
export let handler: (req: Request) => Promise<Response>;
export const state: any = { jobs: new Map(), guests: new Map(), memories: new Map(), balance: 10, calls: 0, removed: 0, debits: 0 };
type EnrichmentScope = {userID:string,memoryID?:string,guestJobID?:string};
function scheduleGenerationEnrichment(scope: EnrichmentScope, _requestID?: string) { state.backgroundOwners.push(scope.userID); (state.backgroundScopes??=[]).push(scope); }
const Deno = {
  env: { get(name: string) {
    const values: any = { SUPABASE_ANON_KEY:'anon', SUPABASE_SERVICE_ROLE_KEY:'service', SUPABASE_URL:'https://db.invalid',
      MIMO_API_KEY:'key', KIMI_API_KEY:'key', MIMO_BASE_URL:'https://model.invalid/mimo', KIMI_BASE_URL:'https://model.invalid/kimi',
      DEEPSEEK_API_KEY:'deepseek-test-key', DEEPSEEK_BASE_URL:'https://model.invalid/deepseek' };
    if (name === 'SUPABASE_URL') return state.projectURL ?? values[name];
    if (name === 'SUPABASE_LOCAL_URL') return state.localURL;
    if (name === 'DEEPSEEK_API_KEY' && state.deepseekMissingKey) return undefined;
    if (name === 'DEEPSEEK_BASE_URL' && state.deepseekMissingURL) return undefined;
    if (name === 'IMAGE_MODERATION_ENABLED') return state.blocked ? 'true' : 'false';
    return values[name];
  } },
  serve(callback: typeof handler) { handler = callback; }
};
const fetch = (async (input: any, init?: RequestInit) => {
  if (String(input).includes('moderate-image-v1')) return Response.json({ allowed:false, policyViolation:true, countedViolation:false,
    statusCode:403, code:'generation_policy_violation', publicError:{error:'Blocked',code:'generation_policy_violation'} });
  state.calls++;
  state.modelRequests.push(JSON.parse(String(init?.body)));
  state.modelHeaders.push(new Headers(init?.headers));
  if (String(input).endsWith('/deepseek')) {
    if (state.deepseekStatus) return new Response('Provider unavailable', {status:state.deepseekStatus});
    if (state.deepseekMalformed) return Response.json({choices:[{message:{content:'not JSON'}}]});
  }
  if ((state.stallMimo && String(input).endsWith('/mimo')) || (state.stallKimi && String(input).endsWith('/kimi')) || (state.stallDeepseek && String(input).endsWith('/deepseek'))) {
    return new Response(new ReadableStream({start(controller) {
      init?.signal?.addEventListener('abort',()=>controller.error(init.signal?.reason),{once:true});
      controller.enqueue(new TextEncoder().encode('{'));
    }}));
  }
  state.modelStarted?.();
  if (state.modelWait) await state.modelWait;
  const sentence = { english:'This is a cat.', chinese:'这是一只猫。',
    ...(state.missingMetadata ? {} : {learning_topic_ids:['pets_and_animals'], expression_purpose:'Describing a cat.'}) };
  const payload = state.dual
    ? {image_descriptions:[sentence,sentence,sentence],scene_and_feelings:[sentence,sentence,sentence]}
    : {sentences:[sentence,sentence,sentence]};
  if (state.photoTags !== undefined) Object.assign(payload, {tags:state.photoTags});
  if (state.unsolicitedTags) Object.assign(payload, {tags:['动物']});
  return Response.json({choices:[{message:{content:JSON.stringify(payload)}}]});
}) as typeof globalThis.fetch;
const fetchWithTimeout = (input: any, init: any, timeout: number, fetcher = fetch) => boundedFetch(input,init,timeout,fetcher);
const fetchWithinDeadline = (deadline: number) => deadlineFetch(deadline,fetch);
class Query {
  filters: [string, any][] = []; patch: any;
  constructor(private table: string) {}
  select() {return this;} eq(k:string,v:any) {this.filters.push([k,v]); return this;}
  update(p:any) {this.patch=p; return this;}
  upsert(rows:any[]) {state.embeddingTable=this.table;state.embeddingRows=rows;return Promise.resolve({error:null});}
  execute() {
    if (this.table === 'profiles') return {data:{available_generations:state.balance,generation_banned_until:null},error:null};
    if (state.lookupError && this.table === 'generation_jobs' && !this.patch) {
      state.lookupError=false; return {data:null,error:{message:'temporary lookup failure'}};
    }
    const map = this.table === 'generation_jobs' ? state.jobs : this.table === 'guest_generation_jobs' ? state.guests : state.memories;
    const row: any = Array.from(map.values()).find((r:any) => this.filters.every(([k,v]) => r[k]===v));
    if (row && this.patch) Object.assign(row,this.patch);
    return {data:row ?? null,error:null};
  }
  single() {return Promise.resolve(this.execute());}
  maybeSingle() {return Promise.resolve(this.execute());}
  then(resolve:any,reject:any) {return Promise.resolve(this.execute()).then(resolve,reject);}
}
function createClient(_url:string,key:string,_options?:unknown):any {
  if (key==='anon') return {auth:{getUser:async(token:string)=>({data:{user:{id:token==='other'?'other':'owner',is_anonymous:!!state.anonymous}},error:null})}};
  return {from:(table:string)=>new Query(table), storage:{from:()=>({
    upload:async()=>({error:state.uploadFails?{message:'upload unavailable'}:null}), remove:async()=>{state.removed++;return {error:null};}
  })}, rpc:async(name:string,args:any)=>{
    if (name==='try_acquire_generation_slot') return {data:true,error:null};
    if (name==='release_generation_slot') {state.released++;return {data:null,error:null};}
    if (name==='refresh_semantic_study_scene_matches_for_sentence') return {data:null,error:null};
    if (name==='claim_generation_job') {
      const map=args.p_is_anonymous?state.guests:state.jobs;
      const existing=map.get(args.p_request_id);
      if (existing) return existing.user_id===args.p_user_id
        ? {data:existing.status,error:null} : {data:null,error:{message:'generation job not found'}};
      map.set(args.p_request_id,{id:args.p_request_id,client_request_id:args.p_request_id,user_id:args.p_user_id,
        status:'pending',image_path:args.p_image_path,created_at:new Date().toISOString()});
      return {data:'acquired',error:null};
    }
    if (name.startsWith('finalize_')) {
      strictEqual(Array.isArray(args.p_tags) && args.p_tags.length <= 3, true);
      state.finalizedTags = args.p_tags;
      state.finalizedSentences = args.p_sentences;
      const guest=name==='finalize_guest_generation';
      const job=(guest?state.guests:state.jobs).get(guest?args.p_guest_job_id:args.p_client_request_id);
      if (state.finalizeRejected) return {data:null,error:{message:'constraint rejected',code:'23514'}};
      state.debits++; state.balance--;
      const id=state.canonicalID ?? args.p_memory_id;
      if (!guest) state.memories.set(id,{id,user_id:args.p_user_id,image_url:args.p_image_path,
        created_at:args.p_created_at,provider:args.p_provider,tags:args.p_tags,
        memory_sentences:args.p_sentences.map((s:any,i:number)=>({...s,sort_order:i}))});
      if (job) Object.assign(job,{status:'completed',memory_id:id,image_path:args.p_image_path ?? job.image_path,
        sentences:args.p_sentences,tags:args.p_tags,provider:args.p_provider,remaining_credits:state.balance});
      if (state.finalizeThrows) throw new Error('transport disconnected after commit');
      if (state.finalizeResponseLost) return {data:null,error:{message:'request timed out',code:''}};
      return {data:state.balance,error:null};
    }
    throw new Error(name);
  }};
}
`;
const { handler, state } = await import(
  "data:application/typescript," + encodeURIComponent(
    harness + source.replace(/^import .*\n/gm, "")
      .replace("const MIMO_TIMEOUT_MS = 20000", "const MIMO_TIMEOUT_MS = 50")
      .replace(
        "const DEEPSEEK_TIMEOUT_MS = 20000",
        "const DEEPSEEK_TIMEOUT_MS = 50",
      )
      .replace("const KIMI_TIMEOUT_MS = 20000", "const KIMI_TIMEOUT_MS = 50"),
  )
);
const id = "10000000-0000-0000-0000-000000000001";
function reset(options: Record<string, unknown> = {}) {
  Object.assign(state, {
    jobs: new Map(),
    guests: new Map(),
    memories: new Map(),
    balance: 10,
    calls: 0,
    modelRequests: [],
    modelHeaders: [],
    projectURL: undefined,
    localURL: undefined,
    deepseekMissingKey: false,
    deepseekMissingURL: false,
    deepseekStatus: undefined,
    deepseekMalformed: false,
    stallDeepseek: false,
    finalizedSentences: [],
    missingMetadata: false,
    unsolicitedTags: false,
    photoTags: undefined,
    finalizedTags: [],
    removed: 0,
    released: 0,
    uploadFails: false,
    finalizeRejected: false,
    finalizeThrows: false,
    debits: 0,
    dual: true,
    anonymous: false,
    modelWait: null,
    modelStarted: null,
    blocked: false,
    lookupError: false,
    canonicalID: null,
    finalizeResponseLost: false,
    stallMimo: false,
    stallKimi: false,
    backgroundOwners: [],
    backgroundScopes: [],
    embeddingRows: undefined,
  }, options);
}
function request(
  token = "owner",
  legacy = false,
  timing = false,
  extra: Record<string, unknown> = {},
) {
  return new Request("https://example.invalid/generate", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${token}`,
      ...(timing
        ? {
          "X-Sanju-Generation-Timing": "1",
          "X-Sanju-Generation-Trace-ID": id,
        }
        : {}),
    },
    body: JSON.stringify({
      imageBase64: "AA==",
      ...(legacy
        ? {}
        : { clientRequestID: id, generationFormat: "dual_tabs_v1" }),
      ...(state.anonymous ? { guestJobID: id } : {}),
      ...extra,
    }),
  });
}

Deno.test("style-free and legacy style requests use the same natural prompt for guests and accounts", async () => {
  for (const anonymous of [false, true]) {
    for (const legacy of [false, true]) {
      for (const englishLevel of ["启蒙", "简单", "中等"]) {
        let expectedPrompt: string | undefined;
        for (
          const languageStyle of [undefined, "平铺直叙", "抒情优美", "unknown"]
        ) {
          reset({
            anonymous,
            dual: !legacy,
            projectURL: "https://api-staging.sanju.cc",
          });
          const response = await handler(
            request("owner", legacy, false, { englishLevel, languageStyle }),
          );
          strictEqual(response.status, 200);
          strictEqual(
            (await response.json()).memory.sentences.length,
            legacy ? 3 : 6,
          );
          const prompt: string =
            state.modelRequests[0].messages[1].content[1].text;
          expectedPrompt ??= prompt;
          strictEqual(prompt, expectedPrompt);
          strictEqual(prompt.includes("抒情优美："), false);
          strictEqual(state.calls, 1);
          strictEqual(state.debits, 1);
        }
      }
    }
  }
});

Deno.test("overlapping authenticated and guest requests run only one model and debit", async () => {
  for (const anonymous of [false, true]) {
    reset({ anonymous });
    let release!: () => void;
    const started = new Promise<void>((resolve) => {
      state.modelStarted = resolve;
    });
    state.modelWait = new Promise<void>((resolve) => {
      release = resolve;
    });
    const first = handler(request());
    await started;
    try {
      const duplicate = await handler(request());
      strictEqual(duplicate.status, 409);
      strictEqual((await duplicate.json()).code, "generation_in_progress");
    } finally {
      release();
    }
    const completed = await first;
    strictEqual(completed.status, 200);
    const result = await completed.json();
    strictEqual(result.memory.tags.length, 0);
    const delivered = result.memory.sentences;
    strictEqual(delivered.length, 6);
    strictEqual(
      delivered.every((s: any) =>
        Array.isArray(s.learning_topic_ids) &&
        s.learning_topic_ids.length === 1 &&
        s.learning_topic_ids[0] === "pets_and_animals"
      ),
      true,
    );
    strictEqual(state.finalizedSentences.length, 6);
    strictEqual(
      state.finalizedSentences.every((s: any) =>
        s.expression_purpose === "Describing a cat."
      ),
      true,
    );
    strictEqual(
      delivered.every((s: any) => s.expression_purpose === undefined),
      true,
    );
    strictEqual(
      state.embeddingRows,
      undefined,
      "response must not await indexing",
    );
    strictEqual(state.backgroundOwners.includes("owner"), true);
    strictEqual(state.backgroundScopes.length, 1);
    strictEqual(Boolean(state.backgroundScopes[0].guestJobID), anonymous);
    strictEqual(Boolean(state.backgroundScopes[0].memoryID), !anonymous);
    if (anonymous) {
      strictEqual(state.guests.get(id).sentences[0].id, delivered[0].id);
    }
    const replay = await handler(request());
    strictEqual(replay.status, 200);
    strictEqual((await replay.json()).memory.sentences[0].id, delivered[0].id);
    strictEqual(state.calls, 1);
    strictEqual(state.debits, 1);
    strictEqual(state.balance, 9);
    strictEqual(
      state.backgroundScopes.length,
      1,
      "reading a completed result must not trigger compensation",
    );
  }
});

Deno.test("unknown photo tags never reach storage for either account or provider", async () => {
  for (const anonymous of [false, true]) {
    for (const stallMimo of [false, true]) {
      reset({ anonymous, stallMimo, unsolicitedTags: true });
      const response = await handler(request());
      strictEqual(response.status, 200);
      const result = await response.json();
      strictEqual(result.memory.tags.length, 0);
      strictEqual(result.memory.sentences.length, 6);
      strictEqual(result.memory.sentences[0].learning_topic_ids[0], "pets_and_animals");
      strictEqual(
        state.finalizedSentences[0].expression_purpose,
        "Describing a cat.",
      );
      strictEqual(state.debits, 1);
      strictEqual(state.backgroundScopes.length, 1);
      strictEqual(state.modelRequests[0].model, "mimo-v2.6-flash");
      strictEqual(state.modelRequests[0].thinking.type, "disabled");
      strictEqual(state.modelRequests[0].max_completion_tokens, 4096);
      strictEqual(
        state.modelRequests[0].messages[1].content[0].type,
        "image_url",
      );
      if (stallMimo) strictEqual(state.modelRequests[1].model, "kimi-k2.5");
      strictEqual(
        state.modelRequests.every((body: any) =>
          JSON.stringify(body.messages).includes("照片分类 tags")
        ),
        true,
      );
    }
  }
});

Deno.test("photo categories persist independently and survive replay for all providers, formats and account types", async () => {
  for (const anonymous of [false, true]) {
    for (const legacy of [false, true]) {
      for (const provider of ["mimo", "kimi", "deepseek"]) {
        reset({
          anonymous,
          dual: !legacy,
          stallMimo: provider === "kimi",
          projectURL: provider === "deepseek"
            ? "https://api-staging.sanju.cc"
            : undefined,
          photoTags: [
            " restaurants_and_cafes ",
            "food_and_drinks",
            "food_and_drinks",
            "unknown",
            "home_life",
            "natural_scenery",
          ],
        });
        const makeRequest = () =>
          request("owner", legacy, false, { clientRequestID: id });
        const response = await handler(makeRequest());
        strictEqual(response.status, 200);
        const result = await response.json();
        const expected = [
          "restaurants_and_cafes",
          "food_and_drinks",
          "home_life",
        ];
        deepStrictEqual(result.memory.tags, expected);
        deepStrictEqual(state.finalizedTags, expected);
        strictEqual(result.memory.provider, provider);
        strictEqual(result.memory.sentences.length, legacy ? 3 : 6);
        deepStrictEqual(result.memory.sentences[0].learning_topic_ids, [
          "pets_and_animals",
        ]);
        const calls = state.calls;
        state.photoTags = ["natural_scenery"];
        const replay = await handler(makeRequest());
        strictEqual(replay.status, 200);
        deepStrictEqual((await replay.json()).memory.tags, expected);
        strictEqual(state.calls, calls);
        strictEqual(state.debits, 1);
      }
    }
  }
});

Deno.test("missing auxiliary metadata keeps valid sentences and leaves repair to the background", async () => {
  for (const anonymous of [false, true]) {
    reset({ anonymous, missingMetadata: true });
    const response = await handler(request());
    strictEqual(response.status, 200);
    strictEqual((await response.json()).memory.sentences.length, 6);
    strictEqual(
      state.finalizedSentences.every((s: any) => !s.expression_purpose),
      true,
    );
    strictEqual(state.calls, 1);
    strictEqual(state.debits, 1);
    strictEqual(state.backgroundScopes.length, 1);
  }
});

Deno.test("generation timing covers both account types without changing responses or debit", async () => {
  for (const anonymous of [false, true]) {
    reset({ anonymous });
    const response = await handler(request("owner", false, true));
    strictEqual(response.status, 200);
    strictEqual(response.headers.get("X-Sanju-Generation-Trace-ID"), id);
    const timing = response.headers.get("Server-Timing") ?? "";
    for (
      const stage of [
        "auth",
        "profile",
        "job_claim",
        "moderation",
        "mimo",
        "finalize",
        "diagnostics",
        "read_result",
        "release_slot",
        "background_dispatch",
        "total",
      ]
    ) {
      strictEqual(timing.includes(`${stage};dur=`), true, stage);
    }
    strictEqual(
      timing.includes(
        anonymous ? "guest_image_upload;dur=" : ", image_upload;dur=",
      ),
      true,
    );
    strictEqual(timing.includes("kimi;dur="), false);
    strictEqual(timing.includes("embedding"), false);
    strictEqual((await response.json()).memory.sentences.length, 6);
    strictEqual(state.debits, 1);
    strictEqual(state.embeddingRows, undefined);
  }
});

Deno.test("rejection and fallback return timings; legacy clients do not receive them", async () => {
  reset({ blocked: true });
  const rejection = await handler(request("owner", false, true));
  strictEqual(rejection.status, 403);
  strictEqual(
    rejection.headers.get("Server-Timing")?.includes("moderation;dur="),
    true,
  );
  strictEqual(
    rejection.headers.get("Server-Timing")?.includes("error_handling;dur="),
    true,
  );
  strictEqual(
    rejection.headers.get("Server-Timing")?.includes("mimo;dur="),
    false,
  );
  strictEqual((await rejection.json()).code, "generation_policy_violation");
  strictEqual(state.debits, 0);
  reset({ stallMimo: true });
  const fallback = await handler(request("owner", false, true));
  strictEqual(
    fallback.headers.get("Server-Timing")?.includes("mimo;dur="),
    true,
  );
  strictEqual(
    fallback.headers.get("Server-Timing")?.includes("kimi;dur="),
    true,
  );
  strictEqual((await fallback.json()).memory.provider, "kimi");
  strictEqual(
    state.finalizedSentences.every((s: any) =>
      s.expression_purpose === "Describing a cat."
    ),
    true,
  );
  strictEqual(state.modelRequests.length, 2);
  strictEqual(
    state.modelRequests.every((body: any) =>
      JSON.stringify(body.messages).includes("learning_topic_ids") &&
      JSON.stringify(body.messages).includes("expression_purpose")
    ),
    true,
  );
  reset({ dual: false });
  const legacy = await handler(request("owner", true));
  strictEqual(legacy.headers.get("Server-Timing"), null);
  strictEqual((await legacy.json()).memory.sentences.length, 3);
});

Deno.test("completed canonical memory is returned and lookup errors cannot restart generation", async () => {
  reset({ canonicalID: "30000000-0000-0000-0000-000000000001" });
  const result = await handler(request());
  strictEqual((await result.json()).memory.id, state.canonicalID);
  strictEqual(state.jobs.get(id).memory_id, state.canonicalID);
  state.lookupError = true;
  strictEqual((await handler(request())).status, 504);
  strictEqual(state.jobs.get(id).status, "completed");
  strictEqual((await handler(request("other"))).status, 500);
  strictEqual(state.jobs.get(id).user_id, "owner");
  strictEqual(state.jobs.get(id).status, "completed");
  strictEqual(state.calls, 1);
  strictEqual(state.debits, 1);
});

Deno.test("lost finalize response preserves committed results and images for replay", async () => {
  for (const anonymous of [false, true]) {
    reset({ anonymous, finalizeResponseLost: true });
    strictEqual((await handler(request())).status, 504);
    const job = (anonymous ? state.guests : state.jobs).get(id);
    strictEqual(job.status, "completed");
    strictEqual(state.removed, 0);
    strictEqual((await handler(request())).status, 200);
    strictEqual(state.calls, 1);
    strictEqual(state.debits, 1);
  }
});

Deno.test("policy rejection stays terminal without model calls or debits; legacy generation still returns three", async () => {
  reset({ blocked: true });
  strictEqual((await handler(request())).status, 403);
  strictEqual(state.jobs.get(id).status, "failed");
  strictEqual((await handler(request())).status, 500);
  strictEqual(state.calls, 0);
  strictEqual(state.debits, 0);
  reset({ dual: false });
  const result = await handler(request("owner", true));
  strictEqual(result.status, 200);
  strictEqual((await result.json()).memory.sentences.length, 3);
  strictEqual(state.debits, 1);
  strictEqual(state.jobs.size, 0);
});

Deno.test("extracted persistence preserves the commit boundary when finalization throws", async () => {
  for (const anonymous of [false, true]) {
    reset({ anonymous, finalizeThrows: true });
    strictEqual((await handler(request())).status, 504);
    strictEqual(
      (anonymous ? state.guests : state.jobs).get(id).status,
      "completed",
    );
    strictEqual(state.removed, 0);
    strictEqual(state.released, 1);
    strictEqual(state.backgroundScopes.length, 1);
    strictEqual((await handler(request())).status, 200);
    strictEqual(state.debits, 1);
    strictEqual(state.calls, 1);
  }
});

Deno.test("definite upload or transaction failures do not debit and release the generation slot", async () => {
  for (const anonymous of [false, true]) {
    for (const failure of ["uploadFails", "finalizeRejected"]) {
      reset({ anonymous, [failure]: true });
      strictEqual((await handler(request())).status, 500);
      strictEqual(state.debits, 0);
      strictEqual(
        (anonymous ? state.guests : state.jobs).get(id).status,
        "failed",
      );
      strictEqual(state.released, 1);
      strictEqual(state.removed, failure === "finalizeRejected" ? 1 : 0);
      if (failure === "uploadFails") {
        strictEqual(state.backgroundScopes.length, 0);
      }
    }
  }
});

Deno.test("a stalled MiMo body falls back to Kimi; two stalled bodies never debit", async () => {
  reset({ stallMimo: true });
  const recovered = await handler(request());
  strictEqual(recovered.status, 200);
  strictEqual((await recovered.json()).memory.provider, "kimi");
  strictEqual(state.calls, 2);
  strictEqual(state.debits, 1);
  strictEqual(state.jobs.get(id).status, "completed");
  reset({ stallMimo: true, stallKimi: true });
  strictEqual((await handler(request())).status, 500);
  strictEqual(state.calls, 2);
  strictEqual(state.debits, 0);
  strictEqual(state.jobs.get(id).status, "failed");
});

const stagingURL = "https://spb-bp1364k407p37qn7.supabase.opentrust.net";
const productionURL = "https://spb-bp103246ivn7q0nl.supabase.opentrust.net";

Deno.test("trusted staging and production projects use DeepSeek, independent of local gateway and request URL", async () => {
  for (
    const projectURL of [
      stagingURL,
      "https://api-staging.sanju.cc",
      productionURL,
      "https://api.sanju.cc",
    ]
  ) {
    for (const anonymous of [false, true]) {
      reset({ projectURL, anonymous, localURL: "http://kong:8000" });
      const response = await handler(request("owner", false, true));
      strictEqual(response.status, 200);
      strictEqual((await response.json()).memory.provider, "deepseek");
      const body = state.modelRequests[0];
      strictEqual(body.model, "deepseek-flash");
      strictEqual(body.thinking.type, "disabled");
      strictEqual(body.max_tokens, 4096);
      strictEqual(body.max_completion_tokens, undefined);
      strictEqual(
        body.messages[1].content[0].image_url.url,
        "data:image/jpeg;base64,AA==",
      );
      strictEqual(
        body.messages[1].content[1].text.includes("expression_purpose"),
        true,
      );
      strictEqual(
        state.modelHeaders[0].get("Authorization"),
        "Bearer deepseek-test-key",
      );
      strictEqual(state.modelHeaders[0].get("api-key"), null);
      strictEqual(
        response.headers.get("Server-Timing")?.includes("deepseek;dur="),
        true,
      );
      strictEqual(
        response.headers.get("Server-Timing")?.includes("mimo;dur="),
        false,
      );
      strictEqual((await handler(request())).status, 200);
      strictEqual(state.calls, 1);
      strictEqual(state.debits, 1);
      strictEqual(state.backgroundScopes.length, 1);
      const record = anonymous
        ? state.guests.get(id)
        : [...state.memories.values()][0];
      strictEqual(record.mimo_failure_reason, null);
    }
  }
  for (
    const projectURL of [
      "https://api-staging.sanju.cc.attacker.invalid",
      "http://api-staging.sanju.cc",
      "https://api.sanju.cc.attacker.invalid",
      "http://api.sanju.cc",
      "not a URL",
    ]
  ) {
    reset({
      projectURL,
      localURL: stagingURL,
      deepseekMissingKey: true,
      deepseekMissingURL: true,
    });
    const incoming = request();
    const forged = new Request(
      "https://api-staging.sanju.cc/functions/v1/generate-memory-v2",
      incoming,
    );
    forged.headers.set("X-Generation-Provider", "deepseek");
    const response = await handler(forged);
    strictEqual(response.status, 200);
    strictEqual((await response.json()).memory.provider, "mimo");
    strictEqual(state.modelRequests[0].model, "mimo-v2.6-flash");
    strictEqual(state.modelHeaders[0].get("api-key"), "key");
    strictEqual(state.debits, 1);
  }
});

Deno.test("both environments require DeepSeek configuration before model, job claim or debit", async () => {
  for (const projectURL of [stagingURL, productionURL]) {
    for (const option of ["deepseekMissingKey", "deepseekMissingURL"]) {
      reset({ projectURL, [option]: true });
      const response = await handler(request());
      strictEqual(response.status, 500);
      strictEqual(
        (await response.json()).error,
        "Missing DeepSeek generation configuration",
      );
      strictEqual(state.calls, 0);
      strictEqual(state.jobs.size, 0);
      strictEqual(state.debits, 0);
    }
  }
});

Deno.test("DeepSeek timeout, malformed response and HTTP errors fall back without mislabeling MiMo failure", async () => {
  for (const projectURL of [stagingURL, productionURL]) {
    for (
      const failure of [{ stallDeepseek: true }, { deepseekMalformed: true }, {
        deepseekStatus: 429,
      }, { deepseekStatus: 503 }]
    ) {
      for (const anonymous of [false, true]) {
        reset({ projectURL, anonymous, ...failure });
        const response = await handler(request());
        strictEqual(response.status, 200);
        strictEqual((await response.json()).memory.provider, "mimo");
        strictEqual(
          state.modelRequests.map((body: any) => body.model).join(","),
          "deepseek-flash,mimo-v2.6-flash",
        );
        strictEqual(state.debits, 1);
        const record = anonymous
          ? state.guests.get(id)
          : [...state.memories.values()][0];
        strictEqual(record.mimo_failure_reason, null);
      }
    }
    reset({ projectURL, stallDeepseek: true, stallMimo: true });
    const response = await handler(request());
    strictEqual(response.status, 200);
    strictEqual((await response.json()).memory.provider, "kimi");
    strictEqual(
      state.modelRequests.map((body: any) => body.model).join(","),
      "deepseek-flash,mimo-v2.6-flash,kimi-k2.5",
    );
    strictEqual(
      [...state.memories.values()][0].mimo_failure_reason.includes(
        "MiMo request timeout",
      ),
      true,
    );
    strictEqual(state.debits, 1);
  }
});

Deno.test("both environments reject moderation or complete provider failure without debits", async () => {
  for (const projectURL of [stagingURL, productionURL]) {
    for (const anonymous of [false, true]) {
      reset({ projectURL, anonymous, blocked: true });
      strictEqual((await handler(request())).status, 403);
      strictEqual(state.calls, 0);
      strictEqual(state.debits, 0);
      reset({
        projectURL,
        anonymous,
        stallDeepseek: true,
        stallMimo: true,
        stallKimi: true,
      });
      strictEqual((await handler(request())).status, 500);
      strictEqual(state.calls, 3);
      strictEqual(state.debits, 0);
      strictEqual(
        (anonymous ? state.guests : state.jobs).get(id).status,
        "failed",
      );
      strictEqual(state.released, 1);
    }
  }
});

Deno.test("DeepSeek preserves committed results after a lost finalize response in both environments", async () => {
  for (const projectURL of [stagingURL, productionURL]) {
    for (const anonymous of [false, true]) {
      reset({ projectURL, anonymous, finalizeResponseLost: true });
      strictEqual((await handler(request())).status, 504);
      strictEqual(
        (anonymous ? state.guests : state.jobs).get(id).status,
        "completed",
      );
      strictEqual(state.removed, 0);
      const replay = await handler(request());
      strictEqual(replay.status, 200);
      strictEqual((await replay.json()).memory.provider, "deepseek");
      strictEqual(state.calls, 1);
      strictEqual(state.debits, 1);
    }
  }
});

Deno.test("production DeepSeek keeps legacy three-sentence responses for both account types", async () => {
  for (const anonymous of [false, true]) {
    reset({ projectURL: productionURL, anonymous, dual: false });
    const response = await handler(request("owner", true));
    strictEqual(response.status, 200);
    const result = await response.json();
    strictEqual(result.memory.provider, "deepseek");
    strictEqual(result.memory.sentences.length, 3);
    strictEqual(result.memory.tags.length, 0);
    strictEqual(response.headers.get("Server-Timing"), null);
    strictEqual(state.modelRequests[0].model, "deepseek-flash");
    strictEqual(state.debits, 1);
    strictEqual(state.backgroundScopes.length, 1);
  }
});

Deno.test("overlapping production DeepSeek requests generate and debit once", async () => {
  for (const anonymous of [false, true]) {
    reset({ projectURL: productionURL, anonymous });
    let release!: () => void;
    const started = new Promise<void>((resolve) => {
      state.modelStarted = resolve;
    });
    state.modelWait = new Promise<void>((resolve) => {
      release = resolve;
    });
    const first = handler(request());
    await started;
    try {
      const duplicate = await handler(request());
      strictEqual(duplicate.status, 409);
      strictEqual((await duplicate.json()).code, "generation_in_progress");
    } finally {
      release();
    }
    const response = await first;
    strictEqual(response.status, 200);
    strictEqual((await response.json()).memory.provider, "deepseek");
    strictEqual((await handler(request())).status, 200);
    strictEqual(state.calls, 1);
    strictEqual(state.debits, 1);
    strictEqual(state.backgroundScopes.length, 1);
  }
});
