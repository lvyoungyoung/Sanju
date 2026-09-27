import { deepStrictEqual, ok, strictEqual, throws } from "node:assert";
import { buildBenchmarkPrompts, imageRequest, stats, validateGeneration } from "../benchmark-generation-metadata.ts";

Deno.test("benchmark preserves generation rules and shares full metadata semantics", () => {
  for (const level of ["启蒙", "简单", "中等"]) {
    const { separate, combined, metadata } = buildBenchmarkPrompts(level);
    ok(!separate.includes("expression_purpose"));
    ok(!separate.includes("learning_topic_ids"));
    const rules = metadata.slice(metadata.indexOf("learning_topic_ids 是句子的分类"), metadata.indexOf("\n\n仅返回 JSON"));
    ok(combined.includes(rules));
    const beforeRules = separate.slice(0, separate.indexOf("你必须严格遵守以下输出规则："));
    ok(combined.startsWith(beforeRules));
    const example = JSON.parse(combined.slice(combined.lastIndexOf("\n{")));
    for (const group of ["image_descriptions", "scene_and_feelings"]) {
      strictEqual(example[group].length, 3);
      for (const sentence of example[group]) {
        deepStrictEqual(Object.keys(sentence).sort(), ["chinese", "english", "expression_purpose", "learning_topic_ids"]);
      }
    }
  }
});

Deno.test("both image variants use identical model, limits and image bytes", () => {
  const { combined, separate } = buildBenchmarkPrompts();
  const a = imageRequest(combined, "fixture"), b = imageRequest(separate, "fixture");
  strictEqual(a.model, "mimo-v2.5");
  strictEqual(a.max_completion_tokens, 4096);
  deepStrictEqual(a.thinking, { type: "disabled" });
  const stripPrompt = (body: unknown) => JSON.stringify(body).replace(JSON.stringify(combined), '"PROMPT"').replace(JSON.stringify(separate), '"PROMPT"');
  strictEqual(stripPrompt(a), stripPrompt(b));
});

Deno.test("benchmark rejects incomplete combined outputs rather than counting fast failures as success", () => {
  const sentence = { english: "The soup tastes good.", chinese: "这碗汤很好喝。" };
  const metadata = { learning_topic_ids: ["food_and_drinks"], expression_purpose: "Describing the taste of soup." };
  const response = (extra: object) => JSON.stringify({
    image_descriptions: Array.from({ length: 3 }, () => ({ ...sentence, ...extra })),
    scene_and_feelings: Array.from({ length: 3 }, () => ({ ...sentence, ...extra })),
    tags: ["美食"],
  });
  strictEqual(validateGeneration(response({}), false).length, 6);
  strictEqual(validateGeneration(response(metadata), true).length, 6);
  throws(() => validateGeneration(response({}), true));
  throws(() => validateGeneration(response({ ...metadata, expression_purpose: "" }), true));
  throws(() => validateGeneration(response({ ...metadata, learning_topic_ids: ["invented"] }), true));
  throws(() => validateGeneration("{}", false));
});

Deno.test("benchmark summaries use actual wall time samples", () => {
  strictEqual(stats([]), null);
  deepStrictEqual(stats([3000, 1000, 2000]), { count: 3, medianMs: 2000, meanMs: 2000, minMs: 1000, maxMs: 3000 });
  strictEqual(stats([1000, 3000])?.medianMs, 2000);
});
