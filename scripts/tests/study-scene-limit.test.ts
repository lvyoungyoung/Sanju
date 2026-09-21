import { strictEqual } from "node:assert";

// Run the actual endpoint with local auth/database/embedding doubles, never a
// live account or billable model. Database enforcement is tested separately.
const source = await Deno.readTextFile(
  new URL(
    "../../supabase/functions/create-study-scene/index.ts",
    import.meta.url,
  ),
);
const harness = `
  export let handler: (req: Request) => Promise<Response>;
  export const state = {
    count: 20, existing: false, raceLimit: false, embeddingCalls: 0, rpcCalls: 0,
    intentCalls: 0, intentFails: false, embeddingInput: null, savedName: null
  };
  const Deno = {
    env: { get: (name: string) => name === "SUPABASE_ANON_KEY" ? "anon" : "test-value" },
    serve: (callback: typeof handler) => { handler = callback; }
  };
  function createClient(_url: string, key: string, _options?: unknown): any {
    if (key === "anon") return { auth: { getUser: async () => ({ data: { user: { id: "owner", is_anonymous: false } }, error: null }) } };
    return {
      from: () => ({
        select() { return this; }, eq() { return this; },
        then(resolve: any, reject: any) { return Promise.resolve({count: state.count, error: null}).then(resolve,reject); },
        maybeSingle: async () => ({data: state.existing ? {id:"existing"} : null, error: null})
      }),
      rpc: async (_name: string, args: any) => {
        state.rpcCalls++;
        state.savedName = args.p_name;
        return state.raceLimit
          ? {data:null, error:{code:"P0001",message:"study_scene_limit_reached"}}
          : {data:[{id:"scene"}], error:null};
      }
    };
  }
  const fetch = async (_input: string, init: RequestInit) => {
    if (new Headers(init.headers).has("api-key")) {
      state.intentCalls++;
      if (state.intentFails) return new Response("Unavailable", {status:503});
      return Response.json({choices:[{finish_reason:"stop",message:{content:JSON.stringify({search_description:"Describing the taste of food."})}}]});
    }
    state.embeddingCalls++;
    state.embeddingInput = JSON.parse(init.body as string).input.texts;
    return Response.json({output:{embeddings:[{embedding:[1,...Array(1023).fill(0)]}]}});
  };
`;
const { handler, state } = await import(
  "data:application/typescript," + encodeURIComponent(
    harness + source.replace(/^import .*createClient.*\n/, "").replace(
      '"./intent.ts"',
      JSON.stringify(
        new URL(
          "../../supabase/functions/create-study-scene/intent.ts",
          import.meta.url,
        ).href,
      ),
    ),
  )
);
const request = (predefined = false) =>
  new Request("https://example.invalid/create-study-scene", {
    method: "POST",
    headers: {
      Authorization: "Bearer test",
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      name: "New theme",
      ...(predefined ? { learning_topic_id: "food_and_drinks" } : {}),
    }),
  });

Deno.test("topic capacity rejects before embedding and localizes a concurrent database rejection", async () => {
  for (const predefined of [false, true]) {
    Object.assign(state, {
      count: 20,
      existing: false,
      raceLimit: false,
      embeddingCalls: 0,
      rpcCalls: 0,
      intentCalls: 0,
      intentFails: false,
    });
    const response = await handler(request(predefined));
    strictEqual(response.status, 409);
    strictEqual((await response.json()).code, "study_scene_limit_reached");
    strictEqual(state.embeddingCalls, 0);
    strictEqual(state.rpcCalls, 0);
    strictEqual(state.intentCalls, 0);

    state.count = 19;
    state.raceLimit = true;
    const raced = await handler(request(predefined));
    strictEqual(raced.status, 409);
    strictEqual((await raced.json()).error, "最多可以创建20个学习主题");
    strictEqual(state.rpcCalls, 1);
    strictEqual(state.intentCalls, predefined ? 0 : 1);
  }
});

Deno.test("twentieth topic and same-name requests still succeed", async () => {
  for (
    const scenario of [{ count: 19, existing: false }, {
      count: 20,
      existing: true,
    }]
  ) {
    Object.assign(state, scenario, {
      raceLimit: false,
      embeddingCalls: 0,
      rpcCalls: 0,
      intentCalls: 0,
      intentFails: false,
    });
    const response = await handler(request());
    strictEqual(response.status, 200);
    strictEqual(state.embeddingCalls, 1);
    strictEqual(state.rpcCalls, 1);
    strictEqual(state.intentCalls, 1);
  }
});

Deno.test("custom creation embeds the intent but saves the original name; predefined themes skip AI", async () => {
  Object.assign(state, {
    count: 0,
    existing: false,
    raceLimit: false,
    embeddingCalls: 0,
    rpcCalls: 0,
    intentCalls: 0,
    intentFails: false,
  });
  strictEqual((await handler(request())).status, 200);
  strictEqual(state.embeddingInput[0], "Describing the taste of food.");
  strictEqual(state.savedName, "New theme");
  strictEqual(state.intentCalls, 1);
  strictEqual((await handler(request(true))).status, 200);
  strictEqual(state.intentCalls, 1);
  strictEqual(state.embeddingCalls, 1);
});

Deno.test("intent provider failure falls back to the name and still creates the theme", async () => {
  Object.assign(state, {
    count: 0,
    existing: false,
    raceLimit: false,
    embeddingCalls: 0,
    rpcCalls: 0,
    intentCalls: 0,
    intentFails: true,
  });
  strictEqual((await handler(request())).status, 200);
  strictEqual(state.embeddingInput[0], "New theme");
  strictEqual(state.savedName, "New theme");
  strictEqual(state.intentCalls, 1);
  strictEqual(state.rpcCalls, 1);
});
