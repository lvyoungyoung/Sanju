import { strictEqual } from "node:assert";

const source = await Deno.readTextFile(
  new URL(
    "../../supabase/functions/create-study-scene/index.ts",
    import.meta.url,
  ),
);
const categories = await Deno.readTextFile(
  new URL(
    "../../supabase/functions/create-study-scene/categories.ts",
    import.meta.url,
  ),
);
const harness = `
  export let handler: (req: Request) => Promise<Response>;
  export const state: any = {count:0,existing:false,raceLimit:false,calls:0,rpcs:0,anonymous:false};
  const Deno = {
    env:{get:(name:string)=>name==='SUPABASE_ANON_KEY'?'anon':name.startsWith('MIMO')?undefined:'test'},
    serve:(callback:typeof handler)=>{handler=callback;}
  };
  function createClient(_url:string,key:string):any {
    if(key==='anon')return {auth:{getUser:async()=>({data:{user:{id:'owner',is_anonymous:state.anonymous}},error:null})}};
    return {
      from:(table:string)=>{
        if(!['study_scenes','study_scene_embeddings','learning_topic_embeddings'].includes(table))throw new Error('Unexpected lookup');
        return {select(){return this;},eq(column:string,value:unknown){(state.filters??=[]).push([table,column,value]);return this;},
          then(resolve:any,reject:any){return Promise.resolve(table==='learning_topic_embeddings'
            ? {data:state.cacheComplete?Object.keys(CATEGORY_DESCRIPTIONS).map(topic_id=>({topic_id,embedding:[1,...Array(1023).fill(0)]})):[],error:null}
            : {count:state.count,error:null}).then(resolve,reject);},
          upsert:async(rows:any[])=>{state.writes+=rows.length;return {error:state.cacheFail?{message:'cache unavailable'}:null};},
          maybeSingle:async()=>({data:table==='study_scene_embeddings'
            ?(state.queryExists?{scene_id:'existing'}:null)
            :(state.existing?{id:'existing',name:'Stored theme'}:null),error:null})};
      },
      rpc:async(name:string,args:any)=>{state.rpcs++;state.rpcName=name;state.savedName=args.p_name;state.rpcArgs=args;return state.raceLimit
        ?{data:null,error:{message:'study_scene_limit_reached'}}:{data:[{id:'scene'}],error:null};}
    };
  }
  const fetch=async(_url:string,init:RequestInit)=>{
    if(new Headers(init.headers).has('api-key'))throw new Error('MiMo must not be called');
    state.calls++;const body=JSON.parse(init.body as string);state.input=body.input.texts;state.textType=body.parameters.text_type;
    return Response.json({output:{embeddings:body.input.texts.map((_text:string,index:number)=>({text_index:index,embedding:[1,...Array(1023).fill(0)]}))}});
  };
`;
const { handler, state } = await import(
  "data:application/typescript," +
    encodeURIComponent(
      harness + categories + source.replace(/^import .*\n/gm, ""),
    )
);
const request = (name = "  描述风景的句子  ", predefined = false) =>
  new Request("https://example.invalid/create-study-scene", {
    method: "POST",
    headers: {
      Authorization: "Bearer test",
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      name,
      ...(predefined ? { learning_topic_id: "natural_scenery" } : {}),
    }),
  });
const reset = () =>
  Object.assign(state, {
    count: 0,
    existing: false,
    raceLimit: false,
    calls: 0,
    rpcs: 0,
    anonymous: false,
    cacheComplete: true,
    cacheFail: false,
    queryExists: true,
    writes: 0,
    filters: [],
  });

Deno.test("custom topics embed user text directly without MiMo and reuse category vectors", async () => {
  for (
    const name of [
      "描述风景的句子",
      "雨天喝咖啡",
      "学习介词",
      "Nature and lakes",
    ]
  ) {
    reset();
    strictEqual((await handler(request(`  ${name}  `))).status, 200);
    strictEqual(state.input[0], name);
    strictEqual(state.savedName, name);
    strictEqual(state.textType, "query");
    strictEqual(state.calls, 1);
    strictEqual(state.rpcName, "create_study_scene_with_embedding");
  }
});
Deno.test("predefined topics use the same name embedding and creation RPC", async () => {
  reset();
  strictEqual((await handler(request("自然风景", true))).status, 200);
  strictEqual(state.calls, 1);
  strictEqual(state.input[0], "自然风景");
  strictEqual(state.rpcName, "create_study_scene_with_embedding");
});
Deno.test("capacity and concurrent rejections preserve the existing message", async () => {
  for (const predefined of [false, true]) {
    reset();
    state.count = 20;
    const response = await handler(request("New theme", predefined));
    strictEqual(response.status, 409);
    strictEqual((await response.json()).code, "study_scene_limit_reached");
    strictEqual(state.calls, 0);
    strictEqual(state.rpcs, 0);
    state.count = 19;
    state.raceLimit = true;
    const raced = await handler(request("New theme", predefined));
    strictEqual(raced.status, 409);
    strictEqual((await raced.json()).error, "最多可以创建20个学习主题");
  }
});
Deno.test("same-name requests at capacity and the twentieth topic still succeed", async () => {
  for (const existing of [false, true]) {
    reset();
    state.count = existing ? 20 : 19;
    state.existing = existing;
    strictEqual((await handler(request())).status, 200);
    strictEqual(state.calls, 1);
  }
});
Deno.test("anonymous users cannot create topics or spend embedding tokens", async () => {
  reset();
  state.anonymous = true;
  strictEqual((await handler(request())).status, 401);
  strictEqual(state.calls, 0);
});

Deno.test("category cache initializes once and fails closed rather than silently changing matching", async () => {
  reset();
  state.cacheComplete = false;
  strictEqual((await handler(request())).status, 200);
  strictEqual(state.writes, 21);
  strictEqual(state.calls, 4);
  reset();
  state.cacheComplete = false;
  state.cacheFail = true;
  strictEqual((await handler(request())).status, 500);
  strictEqual(state.rpcs, 0);
});

Deno.test("existing themes prepare by owned ID, reuse query vectors and cannot recreate missing themes", async () => {
  const id = "10000000-0000-0000-0000-000000000001";
  const prepare = () =>
    new Request("https://example.invalid/create-study-scene", {
      method: "POST",
      headers: {
        Authorization: "Bearer test",
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ prepare_only: true, scene_id: id }),
    });
  reset();
  strictEqual((await handler(prepare())).status, 404);
  strictEqual(state.calls, 0);
  state.existing = true;
  state.count = 20;
  strictEqual((await handler(prepare())).status, 200);
  strictEqual(state.calls, 0);
  strictEqual(state.rpcName, "prepare_study_scene_matching");
  strictEqual(state.rpcArgs.p_scene_id, id);
  strictEqual(state.rpcArgs.p_embedding, null);
  strictEqual(
    state.filters.some((f: string[]) =>
      f[0] === "study_scenes" && f[1] === "user_id" && f[2] === "owner"
    ),
    true,
  );
  state.queryExists = false;
  strictEqual((await handler(prepare())).status, 200);
  strictEqual(state.calls, 1);
  strictEqual(state.input[0], "Stored theme");
});
