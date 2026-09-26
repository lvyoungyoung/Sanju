import { deepStrictEqual, ok, strictEqual } from "node:assert";

const source = await Deno.readTextFile(
  new URL(
    "../../supabase/functions/generate-memory-v2/index.ts",
    import.meta.url,
  ),
);
const { buildPromptText, MEMORY_TAGS, parseGeneratedContent } = await import(
  "data:application/typescript," + encodeURIComponent(`
    ${
    source.slice(
      source.indexOf("interface Sentence"),
      source.indexOf("const MIMO_TIMEOUT_MS"),
    )
  }
    export { buildPromptText, MEMORY_TAGS, parseGeneratedContent };
  `)
);
const levels = ["启蒙", "简单", "中等", "高级"];
const styles = ["平铺直叙", "抒情优美"];
const formats = ["legacy_v1", "dual_tabs_v1"];

Deno.test("restored full JSON examples keep all preference and response contracts without metadata", () => {
  for (const format of formats) {
    for (const level of levels) {
      for (const style of styles) {
        const prompt = buildPromptText(level, style, format);
        const example = JSON.parse(prompt.slice(prompt.lastIndexOf("\n{") + 1));
        const groups = format === "legacy_v1"
          ? ["sentences"]
          : ["image_descriptions", "scene_and_feelings"];
        deepStrictEqual(
          Object.keys(example).sort(),
          [...groups, "tags"].sort(),
        );
        for (const group of groups) {
          strictEqual(example[group].length, 3);
          for (const item of example[group]) {
            deepStrictEqual(Object.keys(item).sort(), ["chinese", "english"]);
            for (const field of ["english", "chinese"]) {
              strictEqual(typeof item[field], "string");
            }
          }
        }
        ok(!prompt.includes("expression_purpose"));
        ok(!prompt.includes("learning_topic_ids"));
        ok(!prompt.includes("self_and_style"));
        for (const tag of MEMORY_TAGS) {
          ok(prompt.includes(tag));
        }
        const parsed = parseGeneratedContent(JSON.stringify(example), format);
        strictEqual(parsed.sentences.length, format === "legacy_v1" ? 3 : 6);
        for (const item of parsed.sentences) {
          deepStrictEqual(
            item.learning_topic_ids,
            [],
          );
        }
        if (format === "dual_tabs_v1") {
          deepStrictEqual(
            parsed.sentences.map((item: any) => item.presentation_group),
            [
              "what_i_see",
              "what_i_see",
              "what_i_see",
              "what_i_say",
              "what_i_say",
              "what_i_say",
            ],
          );
          strictEqual(
            parseGeneratedContent(
              JSON.stringify({ ...example, scene_and_feelings: [] }),
              format,
            ),
            null,
          );
        }
      }
    }
  }
});

Deno.test("restored prose preserves detailed difficulty, humor and lyrical boundaries", () => {
  for (const format of formats) {
    const plain = buildPromptText("简单", "平铺直叙", format);
    for (
      const text of [
        "每句尽量控制在 6 到 12 个单词之间",
        "不要使用抽象词、书面词、复杂从句、比喻、拟人、现在分词作状语、过去分词作定语",
        "允许加入轻微的幽默、俏皮观察或令人会心一笑的措辞",
        "幽默必须来自画面中真实可见的对比、动作或细节",
        "不要虚构图片中没有的动作、对话、情绪或细节",
      ]
    ) ok(plain.includes(text), text);
    const lyrical = buildPromptText("高级", "抒情优美", format);
    ok(lyrical.includes("14 到 24 个单词"));
    ok(lyrical.includes("不要写成诗歌，不要过度夸张，不要脱离图片内容"));
    const starter = buildPromptText("启蒙", "抒情优美", format);
    strictEqual(starter, buildPromptText("启蒙", "平铺直叙", format));
    ok(starter.includes("不要用碎片短语凑句"));
    ok(starter.includes("中文翻译也要短、直接、适合儿童理解"));
    ok(!starter.includes("8 到 18 个英文单词"));
  }
});

Deno.test("scene expressions retain everyday priority and grounded hypothetical dialogue", () => {
  const prompt = buildPromptText("高级", "抒情优美", "dual_tabs_v1");
  for (
    const text of [
      "不推测人物关系、事件背景和内心感受",
      "大胆根据画面推测最可能发生的场景",
      "不得编造图片无法支持的具体姓名、地点、时间、经历或事实",
      "不能把假设的对话写成真实发生过的事实",
      "不要因为输入是一张照片就默认请求别人帮忙拍照",
      "生活表达的“日常口语感”优先级高于用户选择的英语级别和语言风格",
      "每句尽量控制在 8 到 18 个英文单词之间",
      "不做数据分析或涨跌解读",
    ]
  ) ok(prompt.includes(text), text);
});
