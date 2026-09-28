import { deepStrictEqual, ok, strictEqual } from "node:assert";
import { createHash } from "node:crypto";

import { buildPromptText, parseGeneratedContent } from "../../supabase/functions/generate-memory-v2/content.ts";
const levels = ["启蒙", "简单", "中等", "高级"] as const;
const styles = ["平铺直叙", "抒情优美"] as const;
const formats = ["legacy_v1", "dual_tabs_v1"] as const;

Deno.test("prompt compaction leaves the entire output contract byte-for-byte unchanged", () => {
  // Captured before compaction, including every numbered rule and the JSON example.
  const hashes = {
    dual_tabs_v1: {
      starter: "7a1901dc32719c2f93204099aae36c628484be3891036696ff9231c8cf9d29b6",
      other: "7b3d57e92acc2cc1b075e25fd9cb25ea77691ca4feaa00346b8e8933e3a3427b",
    },
    legacy_v1: {
      starter: "ac92370ea0cce20653f1de882bbb8e9474b85cba4b51bcd944553eff65649d58",
      other: "f889bc4ef180c2c666c2307af2f4d1dc0e043a8276237dc530f4ab0074f6075d",
    },
  };
  for (const format of formats) {
    for (const level of levels) {
      for (const style of styles) {
        const prompt = buildPromptText(level, style, format);
        const start = prompt.indexOf("你必须严格遵守以下输出规则：");
        ok(start >= 0);
        strictEqual(
          createHash("sha256").update(prompt.slice(start)).digest("hex"),
          hashes[format][level === "启蒙" ? "starter" : "other"],
          `${format}/${level}/${style}`,
        );
      }
    }
  }
});

Deno.test("beginner plain guidance is under half its former length without shrinking output rules", () => {
  const prompt = buildPromptText("简单", "平铺直叙", "dual_tabs_v1");
  const oldTotalCharacters = 5066;
  const oldOutputCharacters = 861;
  const bodyLength = prompt.indexOf("你必须严格遵守以下输出规则：");
  ok(bodyLength <= (oldTotalCharacters - oldOutputCharacters) / 2);
  ok(prompt.length <= 2900, `Prompt grew to ${prompt.length} characters`);
});

Deno.test("combined generation requests sentence text, categories and purposes together", () => {
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
          [...groups].sort(),
        );
        for (const group of groups) {
          strictEqual(example[group].length, 3);
          for (const item of example[group]) {
            deepStrictEqual(Object.keys(item).sort(), ["chinese", "english", "expression_purpose", "learning_topic_ids"]);
            for (const field of ["english", "chinese"]) {
              strictEqual(typeof item[field], "string");
            }
          }
        }
        ok(prompt.includes("expression_purpose"));
        ok(prompt.includes("learning_topic_ids"));
        ok(prompt.includes("self_and_style"));
        ok(!prompt.includes("tags"));
        const parsed = parseGeneratedContent(JSON.stringify(example), format);
        ok(parsed);
        strictEqual("tags" in parsed, false);
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

Deno.test("unsolicited photo tags are ignored without discarding sentence metadata", () => {
  for (const format of formats) {
    const prompt = buildPromptText("简单", "平铺直叙", format);
    const example = JSON.parse(prompt.slice(prompt.lastIndexOf("\n{") + 1));
    const parsed = parseGeneratedContent(JSON.stringify({...example, tags: ["风景", "旅行"]}), format);
    ok(parsed);
    strictEqual("tags" in parsed, false);
    strictEqual(parsed.sentences.length, format === "legacy_v1" ? 3 : 6);
    strictEqual(parsed.sentences.every((s: any) => s.expression_purpose && Array.isArray(s.learning_topic_ids)), true);
  }
});

Deno.test("difficulty changes preserve grounded humor and lyrical boundaries", () => {
  for (const format of formats) {
    const plain = buildPromptText("简单", "平铺直叙", format);
    for (
      const text of [
        "每句必须 6 到 10 个英文单词",
        "不用从句、完成时、被动语态、分词修饰、抽象书面词、生僻习语、比喻或拟人",
        "可轻微幽默或俏皮",
        "须来自可见的对比、动作或细节",
        "不虚构动作、对话、情绪或细节",
      ]
    ) ok(plain.includes(text), text);
    const lyrical = buildPromptText("高级", "抒情优美", format);
    ok(lyrical.includes("14 到 24 个单词"));
    ok(lyrical.includes("不写诗、不夸张、不脱离图片"));
    const starter = buildPromptText("启蒙", "抒情优美", format);
    strictEqual(starter, buildPromptText("启蒙", "平铺直叙", format));
    ok(starter.includes("保持自然完整"));
    ok(starter.includes("中文短而直接，适合儿童"));
    ok(!starter.includes("8 到 18 个英文单词"));
  }
});

Deno.test("scene expressions retain everyday speech and grounded hypothetical dialogue", () => {
  const prompt = buildPromptText("中等", "抒情优美", "dual_tabs_v1");
  for (
    const text of [
      "不推测关系、背景和内心感受",
      "大胆推测最可能的场景、关系和感受",
      "不编造无依据的具体姓名、地点、时间、经历或事实",
      "不能声称对话已发生",
      "仅画面明确涉及拍照才考虑请人拍照",
      "两组遵守同一档难度",
      "难度限制适用于所有 english 字段，优先于风格、幽默和细节",
      "不写诗、散文、文艺腔",
      "不分析数据或涨跌",
    ]
  ) ok(prompt.includes(text), text);
});

Deno.test("beginner word limits are explicit per sentence across both styles and formats", () => {
  for (const format of formats) {
    for (const style of styles) {
      const prompt = buildPromptText("简单", style, format);
      for (const rule of [
        "每句必须 6 到 10 个英文单词，逐句限制、不是平均，最多 10 个",
        "难度限制适用于所有 english 字段",
        "优先于风格、幽默和细节",
        "输出前按空格逐句检查",
        "缩写算一个词、标点不计",
        "超长则删次要信息并改写，不直接截断",
        "不输出词数或检查过程",
      ]) ok(prompt.includes(rule), `${format}/${style}: ${rule}`);
      ok(!prompt.includes("尽量控制在 6 到 10"));

      for (const level of ["启蒙", "中等", "高级"] as const) {
        ok(!buildPromptText(level, style, format).includes("最多 10 个"));
      }
    }
  }
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
        const prompt = buildPromptText(level as Parameters<typeof buildPromptText>[0], style, format);
        deepStrictEqual(prompt.match(/\d+ 到 \d+ 个英文单词/g), [range]);
        ok(
          prompt.includes(
            "适用于所有 english 字段，优先于风格、幽默和细节",
          ),
        );
        ok(prompt.includes("不凑字数"));
        ok(prompt.includes("不省略必要成分"));
        ok(!prompt.includes("优先级高于用户选择的英语级别"));
        if (format === "dual_tabs_v1") {
          ok(prompt.includes("两组遵守同一档难度"));
        }
      }
    }
  }
});

Deno.test("difficulty progression changes information and grammar rather than length alone", () => {
  const guidance: Record<string, string[]> = {
    "启蒙": [
      "只表达一个事物、动作或简单感受",
      "不叠加背景细节",
      "极常见的具体词、简单感受词",
      "不用从句、抽象词、习语",
    ],
    "简单": [
      "一个意思及一个具体细节",
      "一个简单分句",
      "常见动词的一般过去时",
      "高频日常词、常见动作和简单感受词",
    ],
    "中等": [
      "常见而准确的动作、感受词和日常搭配",
      "一个意思及一两个细节",
      "一个简短 because/when/that 从句",
      "不强求从句、不嵌套",
      "不靠堆形容词拉长句子",
    ],
  };
  for (const [level, rules] of Object.entries(guidance)) {
    for (const format of formats) {
      for (const style of styles) {
        const prompt = buildPromptText(level as Parameters<typeof buildPromptText>[0], style, format);
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
    ok(!dual.includes("中级："));
  }
});
