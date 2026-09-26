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
        ok([...prompt].length <= (format === "legacy_v1" ? 2250 : 3100));
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
        ok(prompt.includes("不把整个对象转义或包成字符串"));
        ok(prompt.includes("必须显式写出 chinese 字段名"));
        ok(prompt.includes("除分类外均为非空字符串"));
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
        "按句意而非照片整体分类",
        "主类在前",
        "最多 2 个不同 ID",
        "仅明确涉及另一独立场景时加第二个",
        "照片只消歧，不以句外背景补分类",
        "返回 []",
        "不凭两个人臆造情侣关系",
        "不凭室内布置臆造工作场景",
        "湖景背景不补 natural_scenery",
        "限下列 ID",
        "依据句子本身，不是照片整体",
        "不增补人物、关系、背景、感受或场景",
        "最多 30 个英文单词且不超过 240 个字符",
        "不是描述山水风景",
        "不写宽泛分类、原句重复/翻译或多个猜测",
        "逐项抄录文字数字",
      ]
    ) {
      ok(prompt.includes(requirement), `${format}: ${requirement}`);
    }
    ok(
      prompt.includes(
        format === "dual_tabs_v1"
          ? "不分析数据、解读涨跌"
          : "不分析、解读涨跌、总结数据",
      ),
    );
  }
});

Deno.test("starter stays shortest and scene expressions remain conversational even in advanced lyrical mode", () => {
  const starter = buildPromptText("启蒙", "抒情优美", "dual_tabs_v1");
  strictEqual(starter, buildPromptText("启蒙", "平铺直叙", "dual_tabs_v1"));
  ok(starter.includes("启蒙词汇/句长限制在所有组中优先于风格、幽默和表达层次"));
  ok(starter.includes("3 到 15 个汉字"));
  ok(!starter.includes("8 到 18 个英文单词"));
  const advanced = buildPromptText("高级", "抒情优美", "dual_tabs_v1");
  for (
    const requirement of [
      "14 到 24 个单词",
      "风格抒情：明显细腻",
      "8 到 18 个英文单词",
      "日常口语为准，优先于难度/风格",
      "高级仅提升搭配、情绪词、节奏，不用复杂从句、书面词、文学修辞",
      "只写可见的人/物/动作/环境/文字，不推测关系、背景或感受",
      "可大胆推测最可能的场景/关系/感受",
      "不编造无依据的具体姓名/地点/时间/经历/事实",
      "仅画面明确涉及拍照才可请求拍照",
      "不限问句或请求",
      "此句允许假设对话，但不得写成已发生的事实",
    ]
  ) {
    ok(advanced.includes(requirement), requirement);
  }
});

Deno.test("terse style rules retain observed humor, restrained lyricism and beginner grammar limits", () => {
  for (const format of formats) {
    const plain = buildPromptText("简单", "平铺直叙", format);
    for (
      const requirement of [
        "风格生动活泼",
        "轻微幽默取自可见对比/动作/细节",
        "不写段子、网络梗、夸张笑话、生硬拟人",
        "不虚构动作/对话/情绪/细节",
        "小学至初中常见词",
        "简单主谓宾或 This is/There is",
        "不用抽象/书面词、复杂从句、比喻、拟人、分词状语/定语",
      ]
    ) ok(plain.includes(requirement), requirement);
    const lyrical = buildPromptText("高级", "抒情优美", format);
    ok(lyrical.includes("自然准确易懂，不写诗、过度夸张或脱离图片"));
    ok(lyrical.includes("可适度修辞、变化节奏"));
    const starter = buildPromptText("启蒙", "平铺直叙", format);
    ok(starter.includes("完整自然，不用碎片短语"));
    ok(starter.includes("比喻、拟人、双关、复杂时态、文学表达"));
    ok(starter.includes("中文适合儿童"));
  }
});
