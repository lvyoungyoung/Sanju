import { deepStrictEqual, ok, rejects, strictEqual } from "node:assert";

const source = await Deno.readTextFile(
  new URL(
    "../../supabase/functions/generate-memory-v2/index.ts",
    import.meta.url,
  ),
);
function fn(name: string) {
  const match = source.match(
    new RegExp(`(?:async )?function ${name}\\([\\s\\S]*?\\n}`),
  );
  if (!match) throw new Error(name);
  return match[0];
}
const helper = new URL(
  "../../supabase/functions/_shared/fetch-with-timeout.ts",
  import.meta.url,
).href;
const api = await import(
  "data:application/typescript," + encodeURIComponent(`
  import { fetchWithTimeout } from ${JSON.stringify(helper)};
  type Sentence = any; type FinalizedSentence = any;
  type SentencePresentationGroup = "what_i_see" | "what_i_say";
  type GenerationFormat = "legacy_v1" | "dual_tabs_v1";
  const Deno = {env:{get:()=>"test"}};
  const LEARNING_TOPIC_IDS = new Set(["natural_scenery"]);
  const LEARNING_TOPIC_PROMPT = "test";
  const LEARNING_TOPIC_CLASSIFICATION_GUIDANCE = "test";
  ${source.match(/^const EXPRESSION_PURPOSE_PROMPT = .*$/m)?.[0]}
  ${
    [
      "normalizeExpressionPurpose",
      "normalizeLearningTopicIDs",
      "normalizeSentenceArray",
      "buildSentenceEmbeddingRows",
      "fetchSentenceEmbeddings",
      "isUUID",
      "toClientSentences",
      "buildPromptText",
      "indexGeneratedSentencesForStudyScenes",
      "stageGuestSentenceEmbeddings",
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

Deno.test("both generation formats request grounded short expression purposes", () => {
  for (const format of ["legacy_v1", "dual_tabs_v1"]) {
    const prompt = api.buildPromptText("中等", "平铺直叙", format);
    ok(prompt.includes("expression_purpose 四个字段"));
    ok(prompt.includes("依据句子本身，不是照片整体"));
    ok(prompt.includes("最多 30 个英文单词"));
    const json = JSON.parse(prompt.slice(prompt.lastIndexOf("\n{") + 1));
    const items = json.sentences ??
      [...json.image_descriptions, ...json.scene_and_feelings];
    strictEqual(items.length, format === "legacy_v1" ? 3 : 6);
    ok(items.every((item: any) => typeof item.expression_purpose === "string"));
  }
});
Deno.test("scene expressions follow feeling, conversation, event order at every difficulty", () => {
  for (const level of ["启蒙", "简单", "中等", "高级"]) {
    for (const style of ["平铺直叙", "抒情优美"]) {
      const prompt = api.buildPromptText(level, style, "dual_tabs_v1");
      const feelingIndex = prompt.indexOf("1. 我当时的感受：");
      const conversationIndex = prompt.indexOf("2. 当时会对别人说什么：");
      const eventIndex = prompt.indexOf("3. 发生了什么：");
      ok(feelingIndex >= 0 && conversationIndex > feelingIndex);
      ok(eventIndex > conversationIndex);
      ok(prompt.includes("直接输出用户会说的那一句"));
      ok(prompt.includes("不要输出双方对话"));
      ok(prompt.includes("不要使用 I would say 等解释性开头"));
      ok(prompt.includes("不能把假设的对话写成真实发生过的事实"));
      ok(prompt.includes("第二句不受前面“不要虚构对话”的限制"));
      ok(prompt.includes("第一句和第三句优先使用 I 或 we"));
      ok(prompt.includes("第二句可自然使用 you、we、祈使句或疑问句"));
      ok(!prompt.includes("第三句不受前面“不要虚构对话”的限制"));
      ok(!prompt.includes("前两句优先使用 I 或 we"));
      ok(!prompt.includes("3. 我想记住的话："));
      ok(prompt.includes("不必总是问句或请求"));
      ok(prompt.includes("不要因为输入是一张照片就默认请求别人帮忙拍照"));
      for (const example of [
        "I had such a lovely time with my friends.",
        "This little moment made my whole day.",
        "Would you like to try a sip of my coffee?",
        "Could you take a photo of me with this view?",
        "I am at a party.",
        "I am happy.",
        "Come and sit with me.",
      ]) {
        ok(!prompt.includes(example));
      }
    }
  }
});
Deno.test("starter conversational guidance keeps short sentences and difficulty over style", () => {
  const prompt = api.buildPromptText("启蒙", "抒情优美", "dual_tabs_v1");
  ok(prompt.includes("每句只表达一个意思，使用极常见的具体词和简单句型"));
  ok(prompt.includes("启蒙的生活表达也必须使用 3 到 6 个单词"));
  ok(!prompt.includes("I like this day."));
  strictEqual(prompt, api.buildPromptText("启蒙", "平铺直叙", "dual_tabs_v1"));
});
Deno.test("legacy image descriptions do not gain the hypothetical dialogue instruction", () => {
  for (const level of ["启蒙", "简单", "中等", "高级"]) {
    for (const style of ["平铺直叙", "抒情优美"]) {
      const prompt = api.buildPromptText(level, style, "legacy_v1");
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
  }]);
  strictEqual(parsed[0].expression_purpose, "Describing a lake.");
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
Deno.test("authenticated and anonymous indexing persist both vectors under the stable sentence IDs", async () => {
  for (const guest of [false, true]) {
    let table = "", rows: any[] = [];
    let matches = 0;
    const admin = {
      from: (name: string) => ({
        upsert: async (data: any[]) => {
          table = name;
          rows = data;
          return { error: null };
        },
      }),
      rpc: async () => {
        matches++;
        return { error: null };
      },
    };
    if (guest) {
      await api.stageGuestSentenceEmbeddings(
        admin,
        "owner",
        "job",
        sentences,
        makeFetcher(),
      );
    } else {await api.indexGeneratedSentencesForStudyScenes(
        admin,
        "owner",
        sentences,
        makeFetcher(),
      );}
    strictEqual(
      table,
      guest ? "guest_sentence_embeddings" : "sentence_embeddings",
    );
    strictEqual(rows[0].sentence_id, sentences[0].id);
    strictEqual(rows[0].purpose_embedding[0], 10);
    strictEqual(rows[0][guest ? "guest_user_id" : "user_id"], "owner");
    strictEqual(matches, guest ? 0 : 3);
  }
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
