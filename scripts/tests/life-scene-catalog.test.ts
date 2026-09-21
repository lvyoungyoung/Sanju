import { deepStrictEqual, ok, strictEqual } from "node:assert";

const root = new URL("../../", import.meta.url);
const read = (path: string) => Deno.readTextFile(new URL(path, root));
const generation = await read("supabase/functions/generate-memory-v2/index.ts");
const recovery = await read(
  "supabase/functions/recover-guest-generation/index.ts",
);
const creation = await read("supabase/functions/create-study-scene/index.ts");
const swift = await read("三句/LearningTopics.swift");
const migration = await read(
  "supabase/migrations/20260920001000_use_photo_life_scenes.sql",
);
const expected = [
  "self_and_style",
  "family_time",
  "children_growing_up",
  "friends_gatherings",
  "romance_and_companionship",
  "pet_life",
  "food_and_drinks",
  "cooking",
  "home_life",
  "city_life",
  "natural_scenery",
  "plants_and_wildlife",
  "travel",
  "transport",
  "sports_and_outdoors",
  "festivals_and_celebrations",
  "arts_and_entertainment",
  "school_and_study",
  "work_life",
  "shopping",
  "health_and_wellness",
];
const quotedIDs = (source: string) =>
  [...source.matchAll(/"([a-z_]+)"/g)].map((match) => match[1]);

Deno.test("all active topic catalogs contain the same 21 life scenes", () => {
  const generatedIDs = [...generation.matchAll(/^  \["([a-z_]+)",/gm)].map((
    match,
  ) => match[1]);
  const clientIDs = [...swift.matchAll(/\.init\(id: "([a-z_]+)"/g)].map((
    match,
  ) => match[1]);
  deepStrictEqual(generatedIDs, expected);
  deepStrictEqual(clientIDs, expected);
  for (const source of [creation, recovery]) {
    const block = source.match(
      /const LEARNING_TOPIC_IDS = new Set\(\[([\s\S]*?)\]\)/,
    );
    ok(block);
    deepStrictEqual(quotedIDs(block[1]), expected);
  }
  const sqlLists = [...migration.matchAll(/array\[([\s\S]*?)\]::text\[\]/g)];
  strictEqual(sqlLists.length, 4);
  for (const [, list] of sqlLists) {
    deepStrictEqual(
      [...list.matchAll(/'([a-z_]+)'/g)].map((match) => match[1]),
      expected,
    );
  }
});

Deno.test("every life scene has matching Chinese and usable English localization", async () => {
  const chinese = await read("三句/zh-Hans.lproj/Localizable.strings");
  const english = await read("三句/en.lproj/Localizable.strings");
  for (const id of expected) {
    for (const source of [chinese, english]) {
      const lines = source.split("\n").filter((line) =>
        line.startsWith(`"learning_topic.${id}" = "`)
      );
      strictEqual(lines.length, 1, id);
      const title = lines[0].split('"')[3];
      ok(title.length >= 2 && title.length <= 24, `RPC name length: ${title}`);
    }
  }
});

function sourceFunction(source: string, name: string) {
  const match = source.match(new RegExp(`function ${name}\\([\\s\\S]*?\\n}`));
  ok(match, name);
  return match[0];
}

Deno.test("generation and anonymous recovery keep up to two distinct ordered scenes", async () => {
  // Compile the actual pure functions without starting Deno.serve or calling providers.
  const source = `
    type SentencePresentationGroup = "what_i_see" | "what_i_say";
    type Sentence = { english: string; chinese: string; learning_topic_ids: string[]; presentation_group?: SentencePresentationGroup };
    const LEARNING_TOPIC_IDS = new Set(${JSON.stringify(expected)});
    export ${sourceFunction(generation, "normalizeLearningTopicIDs")}
    export ${sourceFunction(generation, "normalizeSentenceArray")}
    export ${
    sourceFunction(recovery, "normalizeLearningTopicIDs").replace(
      "normalizeLearningTopicIDs",
      "recoverTopicIDs",
    )
  }
  `;
  const functions = await import(
    "data:application/typescript," + encodeURIComponent(source)
  );
  deepStrictEqual(
    functions.normalizeLearningTopicIDs(["food_and_drinks", "cooking"]),
    ["food_and_drinks", "cooking"],
  );
  deepStrictEqual(functions.recoverTopicIDs(["food_and_drinks", "cooking"]), [
    "food_and_drinks",
    "cooking",
  ]);
  for (
    const normalize of [
      functions.normalizeLearningTopicIDs,
      functions.recoverTopicIDs,
    ]
  ) {
    deepStrictEqual(
      normalize([
        "sports_and_outdoors",
        "sports_and_outdoors",
        "invalid",
        "family_time",
        "natural_scenery",
      ]),
      ["sports_and_outdoors", "family_time"],
    );
    deepStrictEqual(normalize(["pet_life"]), ["pet_life"]);
    deepStrictEqual(normalize([]), []);
  }
  deepStrictEqual(functions.recoverTopicIDs(["food_and_cooking"]), []);
  const sentences = [
    {
      english: "The cake tastes sweet.",
      chinese: "蛋糕很甜。",
      learning_topic_ids: ["food_and_drinks"],
    },
    {
      english: "We went camping with our family.",
      chinese: "我们一家人去露营。",
      learning_topic_ids: ["sports_and_outdoors", "family_time"],
    },
    {
      english: "This is a receipt.",
      chinese: "这是一张票据。",
      learning_topic_ids: [],
    },
  ];
  for (const group of [undefined, "what_i_see", "what_i_say"]) {
    const parsed = functions.normalizeSentenceArray(sentences, group);
    strictEqual(parsed.length, 3);
    deepStrictEqual(
      parsed.map((sentence: any) => sentence.learning_topic_ids),
      [["food_and_drinks"], ["sports_and_outdoors", "family_time"], []],
    );
    strictEqual(parsed[0].presentation_group, group);
  }
  strictEqual(
    functions.normalizeSentenceArray([{
      english: "",
      chinese: "缺少英文",
      learning_topic_ids: [],
    }]).length,
    0,
  );
});
