import { deepStrictEqual, ok, strictEqual } from "node:assert";

const source = await Deno.readTextFile(
  new URL(
    "../../supabase/functions/generate-memory-v2/index.ts",
    import.meta.url,
  ),
);
// Load the actual catalog and prompt builder without starting an HTTP handler.
const { buildPromptText, LEARNING_TOPICS, MEMORY_TAGS } = await import(
  "data:application/typescript," + encodeURIComponent(`
    type GenerationFormat = "legacy_v1" | "dual_tabs_v1";
    ${
    source.slice(
      source.indexOf("const MEMORY_TAGS"),
      source.indexOf("function serializeGenerationError"),
    )
  }
    export { buildPromptText, LEARNING_TOPICS, MEMORY_TAGS };
  `)
);
const levels = ["启蒙", "简单", "中等", "高级"];
const styles = ["平铺直叙", "抒情优美"];
const formats = ["legacy_v1", "dual_tabs_v1"];

Deno.test("compact prompts keep full JSON examples and every sentence field for all preferences", () => {
  const topicIDs = new Set(LEARNING_TOPICS.map(([id]: string[]) => id));
  for (const format of formats) {
    for (const level of levels) {
      for (const style of styles) {
        const prompt = buildPromptText(level, style, format);
        // Character budgets, not provider token counts or latency guarantees.
        ok([...prompt].length <= (format === "legacy_v1" ? 2500 : 3500));
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
          for (const sentence of example[group]) {
            deepStrictEqual(Object.keys(sentence).sort(), [
              "chinese",
              "english",
              "expression_purpose",
              "learning_topic_ids",
            ]);
            for (const field of ["english", "chinese", "expression_purpose"]) {
              strictEqual(typeof sentence[field], "string");
              ok(sentence[field].length > 0);
            }
            ok(Array.isArray(sentence.learning_topic_ids));
            ok(sentence.learning_topic_ids.length <= 2);
            ok(
              sentence.learning_topic_ids.every((id: string) =>
                topicIDs.has(id)
              ),
            );
          }
        }
        ok(example.tags.length >= 1 && example.tags.length <= 3);
        ok(example.tags.every((tag: string) => MEMORY_TAGS.includes(tag)));
        ok(prompt.includes("不把对象转义或包成字符串"));
        ok(prompt.includes("必须显式写出 chinese 字段名"));
        ok(prompt.includes("learning_topic_ids 数组"));
        ok(prompt.includes("tags：照片分类数组"));
      }
    }
  }
});

Deno.test("compact classification keeps all 21 boundaries, ordered labels and grounded purposes", () => {
  for (const format of formats) {
    const prompt = buildPromptText("中等", "平铺直叙", format);
    for (const [id] of LEARNING_TOPICS) {
      strictEqual(prompt.split(`${id}：`).length - 1, 1, id);
    }
    for (
      const requirement of [
        "按每句实际表达的内容分类，不按照片整体分类",
        "第一个是最匹配的主场景",
        "每句最多 2 个分类",
        "只有句子明确涉及另一独立场景时才加第二个",
        "返回 []",
        "不凭两个人臆造情侣关系",
        "不凭室内布置臆造工作场景",
        "背景有湖也不自动加 natural_scenery",
        "不自创分类",
        "依据句子本身，不是照片整体",
        "不增补人物、关系、背景、感受或场景",
        "最多 30 个英文单词且不超过 240 个字符",
        "不是描述山水风景",
        "不做分析报告",
        "逐项抄写文字数字",
      ]
    ) {
      // Dual-tab information-image instructions use the equivalent shorter verb.
      if (requirement === "不做分析报告" && format === "dual_tabs_v1") {
        ok(prompt.includes("不分析数据、解读涨跌"));
      } else {
        ok(prompt.includes(requirement), `${format}: ${requirement}`);
      }
    }
  }
});

Deno.test("starter stays shortest and scene expressions remain conversational even in advanced lyrical mode", () => {
  const starter = buildPromptText("启蒙", "抒情优美", "dual_tabs_v1");
  strictEqual(starter, buildPromptText("启蒙", "平铺直叙", "dual_tabs_v1"));
  ok(starter.includes("所有组均以启蒙词汇和句长限制为最高优先级"));
  ok(starter.includes("3 到 15 个汉字"));
  ok(!starter.includes("8 到 18 个英文单词"));
  const advanced = buildPromptText("高级", "抒情优美", "dual_tabs_v1");
  for (
    const requirement of [
      "14 到 24 个单词",
      "整体风格请明显更细腻",
      "8 到 18 个英文单词",
      "日常口语感优先于难度和风格",
      "高级也不用复杂从句、书面词或文学修辞",
      "仅限直接可见",
      "可大胆推测最可能的场景、关系和感受",
      "不编造无依据的具体姓名、地点、时间、经历或事实",
      "不要因为输入是一张照片就默认请求别人帮忙拍照",
      "仅画面明确涉及拍照时考虑",
      "不必总是问句或请求",
      "不能把假设的对话写成真实发生过的事实",
    ]
  ) {
    ok(advanced.includes(requirement), requirement);
  }
});
