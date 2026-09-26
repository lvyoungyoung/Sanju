import { deepStrictEqual, ok, strictEqual } from "node:assert";

const source = await Deno.readTextFile(
  new URL(
    "../../supabase/functions/generate-memory-v2/index.ts",
    import.meta.url,
  ),
);
// Load the actual catalog and prompt builder without starting an HTTP handler.
const { buildPromptText, LEARNING_TOPICS, MEMORY_TAGS, parseGeneratedContent } =
  await import(
    "data:application/typescript," + encodeURIComponent(`
    ${
      source.slice(
        source.indexOf("interface Sentence"),
        source.indexOf("const MIMO_TIMEOUT_MS"),
      )
    }
    export { buildPromptText, LEARNING_TOPICS, MEMORY_TAGS, parseGeneratedContent };
  `)
  );
const levels = ["启蒙", "简单", "中等", "高级"];
const styles = ["平铺直叙", "抒情优美"];
const formats = ["legacy_v1", "dual_tabs_v1"];

Deno.test("two-thousand-character prompts keep one complete sentence schema and explicit output counts", () => {
  const topicIDs = new Set(LEARNING_TOPICS.map(([id]: string[]) => id));
  for (const format of formats) {
    for (const level of levels) {
      for (const style of styles) {
        const prompt = buildPromptText(level, style, format);
        // Character budgets, not provider token counts or latency guarantees.
        ok([...prompt].length <= 2100, `${format}/${level}/${style}`);
        const sentence = JSON.parse(
          prompt.slice(prompt.lastIndexOf("\n{") + 1),
        );
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
        ok(sentence.learning_topic_ids.every((id: string) => topicIDs.has(id)));
        ok(
          prompt.includes(
            format === "legacy_v1"
              ? "顶层仅 sentences、tags；sentences 数组固定 3 项"
              : "顶层仅 image_descriptions、scene_and_feelings、tags；两组句子数组各 3 项",
          ),
        );
        ok(prompt.includes("非完整回答，须填满上述数组"));
        ok(prompt.includes("勿将对象包成转义字符串"));
        ok(prompt.includes("不能省略chinese键"));
        ok(prompt.includes("分类为数组，其余为非空字符串"));
        ok(prompt.includes("tags：1–3个不同照片分类字符串，数组"));
        for (const tag of MEMORY_TAGS) ok(prompt.includes(tag), tag);
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
        "按句意非照片整体分类",
        "主类在前",
        "最多2个不同ID",
        "仅句中明确涉及另一独立场景才加第二个",
        "照片只消歧，不以句外背景补分类",
        "返回[]",
        "双人≠情侣",
        "室内≠工作",
        "只选下列ID",
        "简短英文用途",
        "只据句意，保留关键对象/动作/感受/限制",
        "不从照片补人物/关系/背景/感受/场景",
        "最多30词且≤240字符",
        "不写宽泛分类、复述、翻译或猜测列表",
        "逐项抄录文字数字",
      ]
    ) {
      ok(prompt.includes(requirement), `${format}: ${requirement}`);
    }
    ok(
      prompt.includes(
        format === "dual_tabs_v1"
          ? "不分析数据/解读涨跌"
          : "不分析、解读涨跌、总结数据",
      ),
    );
  }
});

Deno.test("starter stays shortest and scene expressions remain conversational even in advanced lyrical mode", () => {
  const starter = buildPromptText("启蒙", "抒情优美", "dual_tabs_v1");
  strictEqual(starter, buildPromptText("启蒙", "平铺直叙", "dual_tabs_v1"));
  ok(starter.includes("启蒙词汇/句长限制在所有组中优先于风格、幽默和表达层次"));
  ok(starter.includes("3 到 15个汉字"));
  ok(!starter.includes("8 到 18 个英文单词"));
  const advanced = buildPromptText("高级", "抒情优美", "dual_tabs_v1");
  for (
    const requirement of [
      "14 到 24 个单词",
      "风格抒情：明显细腻",
      "8 到 18 个英文单词",
      "口语，优先于难度/风格",
      "高级仅提升搭配/情绪词/节奏，不用复杂从句/书面词/文学修辞",
      "客观描述可见人/物/动作/环境/文字，不推测关系/背景/感受",
      "以用户视角大胆推测最可能的场景/关系/感受",
      "不编造无依据的姓名/地点/时间/经历/事实",
      "仅画面明确涉及拍照才可请求拍照",
      "不限问句或请求",
      "可假设对话，非已发生事实",
    ]
  ) {
    ok(advanced.includes(requirement), requirement);
  }
});

Deno.test("single sentence examples still compose valid legacy and dual-tab responses for the real parser", () => {
  for (const format of formats) {
    const prompt = buildPromptText("中等", "平铺直叙", format);
    const example = JSON.parse(prompt.slice(prompt.lastIndexOf("\n{") + 1));
    const sentence = {
      ...example,
      english: "The soup tastes good.",
      chinese: "汤很好喝。",
      expression_purpose: "Describing the taste of soup.",
    };
    const group = Array.from({ length: 3 }, () => ({ ...sentence }));
    const payload = format === "legacy_v1"
      ? { sentences: group, tags: ["美食"] }
      : {
        image_descriptions: group,
        scene_and_feelings: group,
        tags: ["美食"],
      };
    const parsed = parseGeneratedContent(JSON.stringify(payload), format);
    ok(parsed);
    strictEqual(parsed.sentences.length, format === "legacy_v1" ? 3 : 6);
    deepStrictEqual(parsed.tags, ["美食"]);
    for (const item of parsed.sentences) {
      strictEqual(item.english, sentence.english);
      strictEqual(item.chinese, sentence.chinese);
      strictEqual(item.expression_purpose, sentence.expression_purpose);
      deepStrictEqual(item.learning_topic_ids, sentence.learning_topic_ids);
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
          JSON.stringify({ ...payload, scene_and_feelings: group.slice(0, 2) }),
          format,
        ),
        null,
      );
    }
    strictEqual(parseGeneratedContent(JSON.stringify(sentence), format), null);
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
