import { deepStrictEqual, ok, strictEqual } from "node:assert";
import {
  buildPhotoCategoryRules,
  normalizePhotoCategories,
  PHOTO_CATEGORIES,
} from "../../supabase/functions/generate-memory-v2/photo-categories.ts";
import {
  buildPromptText,
  parseGeneratedContent,
} from "../../supabase/functions/generate-memory-v2/content.ts";
import { readFunctionSource } from "./helpers/function-source.ts";

const root = new URL("../../", import.meta.url);

Deno.test("the 17 photo categories agree across AI, client, SQL and both languages", async () => {
  strictEqual(PHOTO_CATEGORIES.length, 17);
  strictEqual(new Set(PHOTO_CATEGORIES.map(([id]) => id)).size, 17);
  const swift = await Deno.readTextFile(
    new URL("三句/MemoryPhotoCategories.swift", root),
  );
  const entries = [
    ...swift.matchAll(/\.init\(id: "([a-z_]+)", fallbackTitle: "([^"]+)"\)/g),
  ].map((m) => [m[1], m[2]]);
  deepStrictEqual(entries, PHOTO_CATEGORIES);
  const sql = await Deno.readTextFile(
    new URL(
      "supabase/migrations/20261009000000_add_photo_scene_categories.sql",
      root,
    ),
  );
  const helper = sql.slice(0, sql.indexOf("-- Keep the existing signatures"));
  deepStrictEqual(
    [...helper.matchAll(/'([a-z_]+)'/g)].map((m) => m[1]),
    PHOTO_CATEGORIES.map(([id]) => id),
  );
  for (const locale of ["en", "zh-Hans"]) {
    const strings = await Deno.readTextFile(
      new URL(`三句/${locale}.lproj/Localizable.strings`, root),
    );
    const localized = [
      ...strings.matchAll(/"photo_category\.([a-z_]+)" = "([^"]+)";/g),
    ];
    deepStrictEqual(
      localized.map((m) => m[1]),
      PHOTO_CATEGORIES.map(([id]) => id),
    );
    ok(localized.every((m) => m[2].trim().length > 0));
    if (locale === "zh-Hans") {
      deepStrictEqual(
        localized.map((m) => m[2]),
        PHOTO_CATEGORIES.map(([, name]) => name),
      );
    }
  }
});

Deno.test("photo categories retain primary-first order and ignore invalid or invented labels", () => {
  deepStrictEqual(
    normalizePhotoCategories([
      null,
      7,
      {},
      "unknown",
      "自然风景",
      " natural_scenery ",
      "natural_scenery",
      "flowers_and_plants",
      "pets_and_animals",
      "home_life",
    ]),
    ["natural_scenery", "flowers_and_plants", "pets_and_animals"],
  );
  for (const value of [undefined, null, "natural_scenery", {}, []]) {
    deepStrictEqual(normalizePhotoCategories(value), []);
  }
  for (const [id] of PHOTO_CATEGORIES) {
    deepStrictEqual(normalizePhotoCategories([id]), [id]);
  }
  const rules = buildPhotoCategoryRules();
  for (
    const text of [
      "直接根据图片本身",
      "不能从句子反推",
      "主分类",
      "两个",
      "不凑满",
      "忽略偶然背景",
      "不推测旅行意图",
      "无法确定则 tags 为 []",
    ]
  ) ok(rules.includes(text));
});

Deno.test("photo categories parse independently without changing sentence metadata or groups", () => {
  for (const format of ["legacy_v1", "dual_tabs_v1"] as const) {
    const prompt = buildPromptText("简单", format);
    const example = JSON.parse(prompt.slice(prompt.lastIndexOf("\n{") + 1));
    const groups = format === "legacy_v1"
      ? ["sentences"]
      : ["image_descriptions", "scene_and_feelings"];
    for (const group of groups) {
      example[group] = example[group].map(() => ({
        english: "This is a cat.",
        chinese: "这是一只猫。",
        learning_topic_ids: ["pet_life"],
        expression_purpose: "Describing a cat.",
      }));
    }
    for (
      const tags of [undefined, null, {}, "pets_and_animals", ["unknown"], [
        "restaurants_and_cafes",
        "food_and_drinks",
      ]]
    ) {
      const parsed = parseGeneratedContent(
        JSON.stringify({ ...example, tags }),
        format,
      );
      ok(parsed);
      deepStrictEqual(parsed.tags, normalizePhotoCategories(tags));
      deepStrictEqual(parsed.sentences[0].learning_topic_ids, ["pet_life"]);
      strictEqual(parsed.sentences[0].expression_purpose, "Describing a cat.");
      strictEqual(parsed.sentences.length, format === "legacy_v1" ? 3 : 6);
    }
  }
});

Deno.test("the migration changes only tag normalization in both finalization transactions", async () => {
  const current = await Deno.readTextFile(
    new URL(
      "supabase/migrations/20261009000000_add_photo_scene_categories.sql",
      root,
    ),
  );
  for (
    const [name, file] of [
      [
        "finalize_authenticated_generation",
        "20260927000000_reuse_generated_sentence_metadata.sql",
      ],
      [
        "finalize_guest_generation",
        "20260925001000_defer_generation_enrichment.sql",
      ],
    ]
  ) {
    const old = await Deno.readTextFile(
      new URL(`supabase/migrations/${file}`, root),
    );
    const extract = (source: string) => {
      const definition = source.match(
        new RegExp(
          `create or replace function public\\.${name}\\([\\s\\S]*?\\$\\$;`,
        ),
      );
      ok(definition, name);
      return definition[0];
    };
    const expected = extract(old).replace(
      /coalesce\(array\([\s\S]*?unique_tags order by position limit 3\s*\), '\{\}'::text\[\]\)/,
      "public.normalize_memory_photo_categories(p_tags)",
    );
    ok(expected.includes("public.normalize_memory_photo_categories(p_tags)"));
    const compact = (value: string) => value.replace(/\s+/g, " ").trim();
    strictEqual(compact(extract(current)), compact(expected), name);
  }
});

Deno.test("guest recovery returns photo categories unchanged and preserves owner isolation", async () => {
  const source = await readFunctionSource(
    new URL("supabase/functions/recover-guest-generation/index.ts", root),
  );
  const harness = `
    export let handler: (req:Request) => Promise<Response>;
    export const job:any = {id:'guest-job', user_id:'owner', status:'completed', created_at:'2026-10-09T00:00:00Z',
      remaining_credits:9, tags:['restaurants_and_cafes','food_and_drinks'], sentences:Array.from({length:6},()=>({english:'This is a cat.',chinese:'这是一只猫。',learning_topic_ids:['pet_life']}))};
    const Deno = {env:{get:(name:string)=>name==='SUPABASE_LOCAL_URL'?undefined:name},serve:(fn:typeof handler)=>handler=fn};
    class Query {
      filters:[string,any][]=[]; patch:any;
      select(){return this;} eq(k:string,v:any){this.filters.push([k,v]);return this;} update(p:any){this.patch=p;return this;}
      then(resolve:any,reject:any){return this.maybeSingle().then(resolve,reject);}
      async maybeSingle(){const row=this.filters.every(([k,v])=>job[k]===v)?job:null; if(row&&this.patch)Object.assign(row,this.patch); return {data:row,error:null};}
    }
    function createClient(_url:string,key:string):any {return key==='SUPABASE_ANON_KEY'
      ?{auth:{getUser:async(token:string)=>({data:{user:{id:token,is_anonymous:true}},error:null})}}
      :{from:()=>new Query()};}
  `;
  const { handler, job } = await import(
    "data:application/typescript," + encodeURIComponent(harness + source)
  );
  const request = (token: string) =>
    new Request("https://example.invalid/recover", {
      method: "POST",
      headers: { Authorization: `Bearer ${token}` },
      body: JSON.stringify({
        guestJobID: "guest-job",
        generationFormat: "dual_tabs_v1",
      }),
    });
  for (let i = 0; i < 2; i++) {
    const result = await (await handler(request("owner"))).json();
    strictEqual(result.recovered, true);
    deepStrictEqual(result.memory.tags, job.tags);
    deepStrictEqual(result.memory.sentences[0].learning_topic_ids, [
      "pet_life",
    ]);
    strictEqual(result.remainingCredits, 9);
  }
  deepStrictEqual(await (await handler(request("other"))).json(), {
    recovered: false,
  });
});
