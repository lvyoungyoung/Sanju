import { deepStrictEqual, ok, rejects, strictEqual } from "node:assert";
import { buildPromptText } from "../../supabase/functions/generate-memory-v2/content.ts";

const source = (await Deno.readTextFile(
  new URL(
    "../../supabase/functions/generate-memory-v2/content.ts",
    import.meta.url,
  ),
)).replace(/^export /gm, "");
const indexingSource = await Deno.readTextFile(
  new URL(
    "../../supabase/functions/_shared/generation-enrichment.ts",
    import.meta.url,
  ),
);
function fn(name: string) {
  const match = (source + "\n" + indexingSource).match(
    new RegExp(`(?:async )?function ${name}\\([\\s\\S]*?\\n}`),
  );
  if (!match) throw new Error(name);
  return match[0];
}
const helper = new URL(
  "../../supabase/functions/_shared/fetch-with-timeout.ts",
  import.meta.url,
).href;
const sceneCategories = new URL(
  "../../supabase/functions/_shared/scene-categories.ts",
  import.meta.url,
).href;
const api = await import(
  "data:application/typescript," + encodeURIComponent(`
  import { fetchWithTimeout } from ${JSON.stringify(helper)};
  import { normalizeSceneCategoryIDs } from ${JSON.stringify(sceneCategories)};
  import type { EnrichmentTiming, EnrichmentStage } from ${
    JSON.stringify(
      new URL(
        "../../supabase/functions/_shared/generation-enrichment-timing.ts",
        import.meta.url,
      ).href,
    )
  };
  type Sentence = any; type FinalizedSentence = any; type IndexableSentence = any;
  type SentencePresentationGroup = "what_i_see" | "what_i_say";
  type GenerationFormat = "legacy_v1" | "dual_tabs_v1";
  const Deno = {env:{get:()=>"test"}};
  ${
    [
      "normalizeExpressionPurpose",
      "normalizeLearningTopicIDs",
      "normalizeSentenceArray",
      "buildSentenceEmbeddingRows",
      "fetchSentenceEmbeddings",
      "isUUID",
      "toClientSentences",
    ].map((name) => `export ${fn(name)}`).join("\n")
  }
`)
);
const vector = (n = 1) => [n, ...Array(1023).fill(0)];
const sentences = Array.from({ length: 3 }, (_, i) => ({
  id: `10000000-0000-4000-8000-00000000000${i}`,
  english: `Sentence ${i}`,
  chinese: `句子${i}`,
  expression_purpose: `Describing activity ${i}.`,
  learning_topic_ids: [],
  is_favorite: false,
}));
const makeFetcher = (fail?: "sentence" | "purpose" | "both") =>
  (async (_url: unknown, init: RequestInit) => {
    const body = JSON.parse(init.body as string);
    strictEqual(body.model, "qwen3.7-text-embedding");
    strictEqual(body.parameters.text_type, "document");
    const original = body.input.texts[0].startsWith("English:");
    if (fail === "both" || fail === (original ? "sentence" : "purpose")) {
      return new Response("unavailable", { status: 503 });
    }
    return Response.json({
      output: {
        embeddings: body.input.texts.map((_: string, i: number) => ({
          text_index: i,
          embedding: vector((original ? 1 : 10) + i),
        })).reverse(),
      },
    });
  }) as typeof fetch;

Deno.test("foreground generation requests metadata without changing the sentence groups", () => {
  for (const format of ["legacy_v1", "dual_tabs_v1"] as const) {
    const prompt = buildPromptText("中等", format);
    ok(prompt.includes("expression_purpose"));
    ok(prompt.includes("learning_topic_ids"));
    const json = JSON.parse(prompt.slice(prompt.lastIndexOf("\n{") + 1));
    deepStrictEqual(
      Object.keys(json).sort(),
      format === "legacy_v1"
        ? ["sentences", "tags"]
        : ["image_descriptions", "scene_and_feelings", "tags"],
    );
    deepStrictEqual(json.tags, []);
    const items = json.sentences ??
      [...json.image_descriptions, ...json.scene_and_feelings];
    strictEqual(items.length, format === "legacy_v1" ? 3 : 6);
    for (const item of items) {
      deepStrictEqual(Object.keys(item).sort(), [
        "chinese",
        "english",
        "expression_purpose",
        "learning_topic_ids",
      ]);
    }
  }
});
Deno.test("scene expressions follow feeling, event, conversation question order at every difficulty", () => {
  for (const level of ["启蒙", "简单", "中等", "高级"] as const) {
    {
      const prompt = buildPromptText(level, "dual_tabs_v1");
      const feelingIndex = prompt.indexOf("1. 我当时的感受：");
      const eventIndex = prompt.indexOf("2. 发生了什么：");
      const conversationIndex = prompt.indexOf("3. 当时会问别人什么：");
      ok(feelingIndex >= 0 && eventIndex > feelingIndex);
      ok(conversationIndex > eventIndex);
      ok(prompt.includes("只写用户那一句及直译"));
      ok(prompt.includes("不写双方对话、标签、额外引号或 I would say 开头"));
      ok(prompt.includes("不能声称对话已发生"));
      ok(prompt.includes("此组允许基于画面的推测和假设口语"));
      ok(prompt.includes("第一句按场景自然选择主语和句式"));
      ok(prompt.includes("第二句优先 I/we"));
      ok(!prompt.includes("第一、三句优先 I/we"));
      ok(prompt.includes("两组均为前两句陈述、第三句疑问"));
      ok(!prompt.includes("第三句不受前面“不要虚构对话”的限制"));
      ok(!prompt.includes("前两句优先使用 I 或 we"));
      ok(!prompt.includes("3. 我想记住的话："));
      ok(prompt.includes("可开放或封闭，不强制类型"));
      ok(prompt.includes("仅画面明确涉及拍照才考虑请人拍照"));
      for (
        const example of [
          "I had such a lovely time with my friends.",
          "This little moment made my whole day.",
          "Would you like to try a sip of my coffee?",
          "Could you take a photo of me with this view?",
          "I am at a party.",
          "I am happy.",
          "Come and sit with me.",
        ]
      ) {
        ok(!prompt.includes(example));
      }
    }
  }
});
Deno.test("starter conversational guidance keeps short sentences and difficulty over style", () => {
  const prompt = buildPromptText("启蒙", "dual_tabs_v1");
  ok(prompt.includes("只表达一个事物、动作或简单感受"));
  ok(prompt.includes("极常见的具体词、简单感受词"));
  ok(prompt.includes("3 到 6 个英文单词"));
  ok(prompt.includes("两组遵守同一档难度"));
  ok(prompt.includes("优先于风格、幽默和细节"));
  ok(!prompt.includes("I like this day."));
  ok(prompt.includes("友好自然直接"));
});
Deno.test("legacy image descriptions do not gain the hypothetical dialogue instruction", () => {
  for (const level of ["启蒙", "简单", "中等", "高级"] as const) {
    {
      const prompt = buildPromptText(level, "legacy_v1");
      ok(!prompt.includes("当时会对别人说什么"));
      ok(prompt.includes("最直接可见的内容"));
      const payload = JSON.parse(prompt.slice(prompt.lastIndexOf("\n{") + 1));
      deepStrictEqual(Object.keys(payload).sort(), ["sentences", "tags"]);
      strictEqual(payload.sentences.length, 3);
    }
  }
});
Deno.test("purpose parsing is bounded and missing purposes do not discard valid legacy sentences", () => {
  strictEqual(
    api.normalizeExpressionPurpose("  Describe\n a lake. "),
    "Describe a lake.",
  );
  for (const value of [null, {}, "", "x".repeat(241), "word ".repeat(31)]) {
    strictEqual(api.normalizeExpressionPurpose(value), undefined);
  }
  const parsed = api.normalizeSentenceArray([{
    english: "A lake.",
    chinese: "湖。",
    expression_purpose: "Describing a lake.",
    learning_topic_ids: ["natural_scenery"],
  }]);
  strictEqual(parsed[0].expression_purpose, "Describing a lake.");
  deepStrictEqual(parsed[0].learning_topic_ids, ["natural_scenery"]);
  for (
    const topics of [undefined, null, ["invalid"], [
      "natural_scenery",
      "natural_scenery",
    ]]
  ) {
    const incomplete = api.normalizeSentenceArray([{
      english: "A lake.",
      chinese: "湖。",
      expression_purpose: "Describing a lake.",
      learning_topic_ids: topics,
    }]);
    strictEqual(incomplete.length, 1);
    strictEqual(
      incomplete[0].expression_purpose,
      undefined,
      "incomplete metadata must be repaired, not mistaken for intentional empty categories",
    );
  }
  strictEqual(
    api.normalizeSentenceArray([{
      english: "A lake.",
      chinese: "湖。",
      expression_purpose: "Describing a lake.",
      learning_topic_ids: [],
    }])[0].expression_purpose,
    "Describing a lake.",
  );
  strictEqual(
    api.normalizeSentenceArray([{ english: "A lake.", chinese: "湖。" }])
      .length,
    1,
  );
});
Deno.test("sentence and purpose batches remain correctly paired despite provider reordering", async () => {
  const rows = await api.buildSentenceEmbeddingRows(sentences, makeFetcher());
  for (let i = 0; i < 3; i++) {
    strictEqual(rows[i].sentence_id, sentences[i].id);
    strictEqual(rows[i].embedding[0], 1 + i);
    strictEqual(rows[i].purpose_embedding[0], 10 + i);
    strictEqual(rows[i].expression_purpose, sentences[i].expression_purpose);
  }
});
Deno.test("one failed vector route never drops the successful route or purpose text", async () => {
  for (const fail of ["sentence", "purpose", "both"] as const) {
    const rows = await api.buildSentenceEmbeddingRows(
      sentences,
      makeFetcher(fail),
    );
    strictEqual(rows[0].embedding === null, fail !== "purpose");
    strictEqual(rows[0].purpose_embedding === null, fail !== "sentence");
    strictEqual(rows[0].expression_purpose, sentences[0].expression_purpose);
  }
});
Deno.test("missing purposes are skipped without shifting other sentences' vectors", async () => {
  const input = sentences.map((s, i) => ({
    ...s,
    expression_purpose: i === 1 ? undefined : s.expression_purpose,
  }));
  const rows = await api.buildSentenceEmbeddingRows(input, makeFetcher());
  strictEqual(rows[0].purpose_embedding[0], 10);
  strictEqual(rows[1].purpose_embedding, null);
  strictEqual(rows[2].purpose_embedding[0], 11);
  let calls = 0;
  await api.buildSentenceEmbeddingRows(
    sentences.map((s) => ({ ...s, expression_purpose: undefined })),
    async (...args: any[]) => {
      calls++;
      return await (makeFetcher() as any)(...args);
    },
  );
  strictEqual(calls, 1);
});
Deno.test("background indexing preserves stable sentence IDs", async () => {
  const rows = await api.buildSentenceEmbeddingRows(sentences, makeFetcher());
  strictEqual(rows[0].sentence_id, sentences[0].id);
  strictEqual(rows[0].purpose_embedding[0], 10);
});
Deno.test("client responses keep old fields and stable IDs without exposing indexing metadata", () => {
  for (const format of ["legacy_v1", "dual_tabs_v1"]) {
    const rows = api.toClientSentences([...sentences, ...sentences], format);
    strictEqual(rows.length, format === "legacy_v1" ? 3 : 6);
    strictEqual(rows[0].id, sentences[0].id);
    strictEqual(rows[0].expression_purpose, undefined);
  }
});
Deno.test("malformed or zero vector batches are rejected before storage", async () => {
  for (
    const item of [{ index: 4, embedding: vector() }, {
      index: 0,
      embedding: [],
    }, { index: 0, embedding: Array(1024).fill(0) }]
  ) {
    await rejects(() =>
      api.fetchSentenceEmbeddings(
        ["test"],
        async () => Response.json({ data: [item] }),
      )
    );
  }
  await rejects(() =>
    api.fetchSentenceEmbeddings(
      ["a", "b"],
      async () =>
        Response.json({
          data: [{ index: 0, embedding: vector() }, {
            index: 0,
            embedding: vector(),
          }],
        }),
    )
  );
});
