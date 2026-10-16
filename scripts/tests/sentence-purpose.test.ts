import { deepStrictEqual, ok, strictEqual } from "node:assert";
import { buildPromptText, parseGeneratedContent, toClientSentences } from "../../supabase/functions/_shared/generate-memory-v2/content.ts";

Deno.test("generation no longer requests or returns sentence categories, purposes or embeddings", () => {
  for (const format of ["legacy_v1", "dual_tabs_v1"] as const) {
    const prompt = buildPromptText("中等", format);
    for (const field of ["learning_topic_ids", "expression_purpose", "embedding"]) ok(!prompt.includes(field));
    const json = JSON.parse(prompt.slice(prompt.lastIndexOf("\n{") + 1));
    const items = json.sentences ?? [...json.image_descriptions, ...json.scene_and_feelings];
    strictEqual(items.length, format === "legacy_v1" ? 3 : 6);
    for (const item of items) {
      deepStrictEqual(Object.keys(item).sort(), ["chinese", "english"]);
      // A provider's extra fields must not escape into persistence or recovery.
      item.learning_topic_ids = ["pets_and_animals"];
      item.expression_purpose = "Describe a pet.";
    }
    const parsed = parseGeneratedContent(JSON.stringify(json), format)!;
    for (const sentence of toClientSentences(parsed.sentences, format)) {
      ok(!("learning_topic_ids" in sentence));
      ok(!("expression_purpose" in sentence));
    }
  }
});

Deno.test("scene expressions keep natural atmosphere-led statements followed by a conversation question", () => {
  for (const level of ["启蒙", "简单", "中等", "高级"] as const) {
    {
      const prompt = buildPromptText(level, "dual_tabs_v1");
      const sceneRules = prompt.slice(prompt.indexOf("scene_and_feelings："));
      const statementsIndex = sceneRules.indexOf("前两句生成用户在这个场景下自然会说的话");
      const conversationIndex = sceneRules.indexOf("第三句问身边的人");
      ok(statementsIndex >= 0 && conversationIndex > statementsIndex);
      ok(prompt.includes("只写用户那一句及直译"));
      ok(prompt.includes("不写双方对话、标签、额外引号或 I would say 开头"));
      ok(prompt.includes("此组允许基于画面的推测和假设口语"));
      ok(prompt.includes("贴合照片的氛围，内容有所区别"));
      ok(prompt.includes("不强制第一人称开头"));
      ok(!prompt.includes("第二句优先 I/we"));
      ok(!prompt.includes("第一、三句优先 I/we"));
      ok(prompt.includes("仅 scene_and_feelings 必须前两句陈述、第三句疑问"));
      ok(!prompt.includes("第三句不受前面“不要虚构对话”的限制"));
      ok(!prompt.includes("前两句优先使用 I 或 we"));
      ok(!prompt.includes("3. 我想记住的话："));
      ok(prompt.includes("本次用开放式问题"));
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
