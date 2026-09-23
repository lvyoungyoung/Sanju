import { strictEqual } from "node:assert";

// Exercise the actual HTTP handler with overlapping requests. All auth, storage,
// database and model calls are local doubles; transaction rules are tested in PG.
const source = await Deno.readTextFile(
  new URL(
    "../../supabase/functions/generate-memory-v2/index.ts",
    import.meta.url,
  ),
);
const httpHelper = new URL(
  "../../supabase/functions/_shared/fetch-with-timeout.ts",
  import.meta.url,
).href;
const harness = `
import { fetchWithTimeout as boundedFetch, fetchWithinDeadline as deadlineFetch } from ${
  JSON.stringify(httpHelper)
};
export let handler: (req: Request) => Promise<Response>;
export const state: any = { jobs: new Map(), guests: new Map(), memories: new Map(), balance: 10, calls: 0, removed: 0, debits: 0 };
const Deno = {
  env: { get(name: string) {
    const values: any = { SUPABASE_ANON_KEY:'anon', SUPABASE_SERVICE_ROLE_KEY:'service', SUPABASE_URL:'https://db.invalid',
      MIMO_API_KEY:'key', KIMI_API_KEY:'key', MIMO_BASE_URL:'https://model.invalid/mimo', KIMI_BASE_URL:'https://model.invalid/kimi' };
    if (name === 'IMAGE_MODERATION_ENABLED') return state.blocked ? 'true' : 'false';
    return values[name];
  } },
  serve(callback: typeof handler) { handler = callback; }
};
const fetch = (async (input: any, init?: RequestInit) => {
  if (String(input).includes('moderate-image-v1')) return Response.json({ allowed:false, policyViolation:true, countedViolation:false,
    statusCode:403, code:'generation_policy_violation', publicError:{error:'Blocked',code:'generation_policy_violation'} });
  state.calls++;
  if ((state.stallMimo && String(input).endsWith('/mimo')) || (state.stallKimi && String(input).endsWith('/kimi'))) {
    return new Response(new ReadableStream({start(controller) {
      init?.signal?.addEventListener('abort',()=>controller.error(init.signal?.reason),{once:true});
      controller.enqueue(new TextEncoder().encode('{'));
    }}));
  }
  state.modelStarted?.();
  if (state.modelWait) await state.modelWait;
  const sentence = { english:'This is a cat.', chinese:'这是一只猫。', learning_topic_ids:['pet_life'], expression_purpose:'Identifying a cat.' };
  const payload = state.dual
    ? {image_descriptions:[sentence,sentence,sentence],scene_and_feelings:[sentence,sentence,sentence],tags:['动物']}
    : {sentences:[sentence,sentence,sentence],tags:['动物']};
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
    upload:async()=>({error:null}), remove:async()=>{state.removed++;return {error:null};}
  })}, rpc:async(name:string,args:any)=>{
    if (name==='try_acquire_generation_slot') return {data:true,error:null};
    if (name==='release_generation_slot' || name==='refresh_semantic_study_scene_matches_for_sentence') return {data:null,error:null};
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
      const guest=name==='finalize_guest_generation';
      const job=(guest?state.guests:state.jobs).get(guest?args.p_guest_job_id:args.p_client_request_id);
      state.debits++; state.balance--;
      const id=state.canonicalID ?? args.p_memory_id;
      if (!guest) state.memories.set(id,{id,user_id:args.p_user_id,image_url:args.p_image_path,
        created_at:args.p_created_at,provider:args.p_provider,tags:args.p_tags,
        memory_sentences:args.p_sentences.map((s:any,i:number)=>({...s,sort_order:i}))});
      if (job) Object.assign(job,{status:'completed',memory_id:id,image_path:args.p_image_path ?? job.image_path,
        sentences:args.p_sentences,tags:args.p_tags,provider:args.p_provider,remaining_credits:state.balance});
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
    removed: 0,
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
  }, options);
}
function request(token = "owner", legacy = false) {
  return new Request("https://example.invalid/generate", {
    method: "POST",
    headers: { Authorization: `Bearer ${token}` },
    body: JSON.stringify({
      imageBase64: "AA==",
      ...(legacy
        ? {}
        : { clientRequestID: id, generationFormat: "dual_tabs_v1" }),
      ...(state.anonymous ? { guestJobID: id } : {}),
    }),
  });
}

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
    const delivered = (await completed.json()).memory.sentences;
    strictEqual(delivered.length, 6);
    strictEqual(
      state.embeddingRows[0].expression_purpose,
      "Identifying a cat.",
    );
    strictEqual(state.embeddingRows[0].sentence_id, delivered[0].id);
    if (anonymous) {
      strictEqual(state.guests.get(id).sentences[0].id, delivered[0].id);
    }
    const replay = await handler(request());
    strictEqual(replay.status, 200);
    strictEqual((await replay.json()).memory.sentences[0].id, delivered[0].id);
    strictEqual(state.calls, 1);
    strictEqual(state.debits, 1);
    strictEqual(state.balance, 9);
  }
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
