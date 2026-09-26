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

Deno.test("difficulty changes preserve grounded humor and lyrical boundaries", () => {
  for (const format of formats) {
    const plain = buildPromptText("简单", "平铺直叙", format);
    for (
      const text of [
        "每句尽量控制在 6 到 10 个英文单词之间",
        "不要使用从句、完成时、被动语态、分词修饰结构、抽象书面词、生僻习语、比喻或拟人",
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

Deno.test("scene expressions retain everyday speech and grounded hypothetical dialogue", () => {
  const prompt = buildPromptText("中等", "抒情优美", "dual_tabs_v1");
  for (
    const text of [
      "不推测人物关系、事件背景和内心感受",
      "大胆根据画面推测最可能发生的场景",
      "不得编造图片无法支持的具体姓名、地点、时间、经历或事实",
      "不能把假设的对话写成真实发生过的事实",
      "不要因为输入是一张照片就默认请求别人帮忙拍照",
      "场景表达与画面描述遵守同一档难度",
      "口语感不能成为忽略难度限制的理由",
      "不能写成诗歌、散文、文艺配文或不符合日常对话的优雅腔调",
      "不做数据分析或涨跌解读",
    ]
  ) ok(prompt.includes(text), text);
});

Deno.test("active difficulty tiers keep one English length range across styles and formats", () => {
  const ranges: Record<string, string> = {
    "启蒙": "3 到 6 个英文单词",
    "简单": "6 到 10 个英文单词",
    "中等": "10 到 16 个英文单词",
  };
  for (const [level, range] of Object.entries(ranges)) {
    for (const format of formats) {
      for (const style of styles) {
        const prompt = buildPromptText(level, style, format);
        deepStrictEqual(prompt.match(/\d+ 到 \d+ 个英文单词/g), [range]);
        ok(
          prompt.includes(
            "适用于每一组、每一句，优先于语言风格、幽默和表达层次要求",
          ),
        );
        ok(prompt.includes("不要为了凑字数添加空洞修饰"));
        ok(prompt.includes("不要为缩短句子省略必要成分"));
        ok(!prompt.includes("优先级高于用户选择的英语级别"));
        if (format === "dual_tabs_v1") {
          ok(prompt.includes("场景表达与画面描述遵守同一档难度"));
        }
      }
    }
  }
});

Deno.test("difficulty progression changes information and grammar rather than length alone", () => {
  const guidance: Record<string, string[]> = {
    "启蒙": [
      "每句只表达一个意思",
      "不叠加背景和修饰细节",
      "只用极常见的具体词和简单感受词",
      "不要使用从句、抽象词、习语",
    ],
    "简单": [
      "增加一个清楚的细节",
      "每句只用一个简单分句",
      "常见动词的一般过去时",
      "不靠难词或复杂语法提高难度",
    ],
    "中等": [
      "常见但更准确的动作词、感受词和自然日常搭配",
      "补充一到两个有用的细节",
      "一个简短从句",
      "不要求每句都带从句，不嵌套多层从句",
      "不是只加形容词拉长句子",
    ],
  };
  for (const [level, rules] of Object.entries(guidance)) {
    for (const format of formats) {
      for (const style of styles) {
        const prompt = buildPromptText(level, style, format);
        for (const rule of rules) {
          ok(prompt.includes(rule), `${level}: ${rule}`);
        }
      }
    }
  }
});

Deno.test("legacy advanced requests retain their description and conversational ranges", () => {
  for (const style of styles) {
    const legacy = buildPromptText("高级", style, "legacy_v1");
    ok(legacy.includes("14 到 24 个单词"));
    ok(!legacy.includes("8 到 18 个英文单词"));
    const dual = buildPromptText("高级", style, "dual_tabs_v1");
    ok(dual.includes("14 到 24 个单词"));
    ok(dual.includes("8 到 18 个英文单词"));
    ok(!dual.includes("中级难度："));
  }
});
