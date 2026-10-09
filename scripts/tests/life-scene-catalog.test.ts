import { deepStrictEqual, ok, strictEqual } from "node:assert";
import {
  normalizeSceneCategoryIDs,
  SCENE_CATEGORIES,
  SCENE_CATEGORY_IDS,
} from "../../supabase/functions/_shared/scene-categories.ts";
import {
  buildSentenceMetadataRules,
  parseSentenceMetadata,
} from "../../supabase/functions/_shared/sentence-metadata.ts";
import {
  buildPhotoCategoryRules,
  PHOTO_CATEGORIES,
} from "../../supabase/functions/generate-memory-v2/photo-categories.ts";
import {
  buildPromptText,
  parseGeneratedContent,
  toClientSentences,
} from "../../supabase/functions/generate-memory-v2/content.ts";
import {
  CATEGORY_CATALOG_VERSION,
  CATEGORY_DESCRIPTIONS,
} from "../../supabase/functions/create-study-scene/categories.ts";

const root = new URL("../../", import.meta.url);
const read = (path: string) => Deno.readTextFile(new URL(path, root));
const expected = SCENE_CATEGORIES.map(([id]) => id);

Deno.test("photos, sentences and category embeddings share one 25-category catalog", async () => {
  strictEqual(expected.length, 25);
  strictEqual(SCENE_CATEGORY_IDS.size, 25);
  deepStrictEqual(
    PHOTO_CATEGORIES,
    SCENE_CATEGORIES.map(([id, title]) => [id, title]),
  );
  deepStrictEqual(Object.keys(CATEGORY_DESCRIPTIONS), expected);
  deepStrictEqual(
    Object.values(CATEGORY_DESCRIPTIONS),
    SCENE_CATEGORIES.map(([, , description]) => description),
  );
  strictEqual(CATEGORY_CATALOG_VERSION, "unified-scenes-v1");
  const swift = await read("三句/SceneCategories.swift");
  deepStrictEqual(
    [...swift.matchAll(/\.init\(id: "([a-z_]+)", fallbackTitle: "([^"]+)"\)/g)]
      .map((m) => [m[1], m[2]]),
    PHOTO_CATEGORIES,
  );
  for (
    const file of [
      "三句/LearningTopics.swift",
      "三句/MemoryPhotoCategories.swift",
    ]
  ) {
    ok((await read(file)).includes("SceneCategory.all.map"), file);
  }
  const sql = await read(
    "supabase/migrations/20261009003000_unify_scene_categories.sql",
  );
  const catalog = sql.slice(
    sql.indexOf("select array["),
    sql.indexOf("]::text[]"),
  );
  deepStrictEqual(
    [...catalog.matchAll(/'([a-z_]+)'/g)].map((m) => m[1]),
    expected,
  );
  ok(sql.includes("'unified-scenes-v1'"));
  ok(!sql.includes("'photo-life-v1'"));
  ok(!sql.includes("= 21"));
});

Deno.test("each category has one grounded boundary and is listed once in the generation prompt", () => {
  const rules = buildSentenceMetadataRules();
  const catalog = [...rules.matchAll(/^([a-z_]+)：(.+)$/gm)]
    .filter(([, id]) =>
      id !== "learning_topic_ids" && id !== "expression_purpose"
    );
  deepStrictEqual(catalog.map(([, id]) => id), expected);
  for (const [, , boundary] of catalog) ok(boundary.length >= 10);
  for (const format of ["legacy_v1", "dual_tabs_v1"] as const) {
    const prompt = buildPromptText("简单", format);
    ok(prompt.includes(buildPhotoCategoryRules(false)));
    for (const id of expected) strictEqual(prompt.split(id).length - 1, 1, id);
  }
});

Deno.test("shared category names are localized identically for photos and sentences", async () => {
  for (const locale of ["zh-Hans", "en"]) {
    const strings = await read(`三句/${locale}.lproj/SceneCategories.strings`);
    const entries = [
      ...strings.matchAll(/"scene_category\.([a-z_]+)" = "([^"]+)";/g),
    ];
    deepStrictEqual(entries.map((m) => m[1]), expected);
    ok(entries.every((m) => m[2].trim().length > 0));
    if (locale === "zh-Hans") {
      deepStrictEqual(
        entries.map((m) => m[2]),
        SCENE_CATEGORIES.map(([, title]) => title),
      );
    }
  }
});

Deno.test("new categories survive generation parsing, metadata validation and client responses", () => {
  for (const id of expected) {
    const sentence = {
      english: "We are looking at this.",
      chinese: "我们正在看这个。",
      learning_topic_ids: [id],
      expression_purpose: "Describing what we are looking at.",
    };
    const parsed = parseGeneratedContent(
      JSON.stringify({ sentences: [sentence, sentence, sentence], tags: [id] }),
      "legacy_v1",
    );
    ok(parsed);
    deepStrictEqual(parsed.tags, [id]);
    deepStrictEqual(parsed.sentences[0].learning_topic_ids, [id]);
    const metadata = parseSentenceMetadata([{
      sentence_id: "test",
      ...sentence,
    }], [{ id: "test", ...sentence }]);
    deepStrictEqual(metadata[0].learning_topic_ids, [id]);
    deepStrictEqual(
      toClientSentences(
        [{ id: crypto.randomUUID(), ...sentence }],
        "dual_tabs_v1",
      )[0].learning_topic_ids,
      [id],
    );
  }
});

Deno.test("photo and sentence assignments stay independent; obsolete IDs have no aliases", () => {
  const sentence = {
    english: "The soup tastes good.",
    chinese: "这汤很好喝。",
    learning_topic_ids: ["food_and_drinks"],
    expression_purpose: "Describing the taste of soup.",
  };
  const parsed = parseGeneratedContent(
    JSON.stringify({
      sentences: [sentence, sentence, sentence],
      tags: ["restaurants_and_cafes"],
    }),
    "legacy_v1",
  );
  ok(parsed);
  deepStrictEqual(parsed.tags, ["restaurants_and_cafes"]);
  deepStrictEqual(parsed.sentences[0].learning_topic_ids, ["food_and_drinks"]);
  deepStrictEqual(
    normalizeSceneCategoryIDs([
      "sports_and_outdoors",
      "sports_and_outdoors",
      null,
      "family_time",
      "natural_scenery",
    ], 2),
    ["sports_and_outdoors", "family_time"],
  );
  for (
    const id of [
      "pet_life",
      "plants_and_wildlife",
      "cities_and_architecture",
      "work_and_office",
      "clothing_and_style",
      "transportation",
    ]
  ) {
    deepStrictEqual(normalizeSceneCategoryIDs([id], 3), []);
  }
});
