import { deepStrictEqual, ok, strictEqual } from "node:assert";
import { createHash } from "node:crypto";
import {
  buildPromptText,
  parseGeneratedContent,
} from "../../supabase/functions/generate-memory-v2/content.ts";

const levels = ["启蒙", "简单", "中等", "高级"] as const;
const formats = ["legacy_v1", "dual_tabs_v1"] as const;

Deno.test("Gemini template adaptation leaves the entire output contract byte-for-byte unchanged", () => {
  const hashes = {
    dual_tabs_v1: {
      starter:
        "7a1901dc32719c2f93204099aae36c628484be3891036696ff9231c8cf9d29b6",
      other: "7b3d57e92acc2cc1b075e25fd9cb25ea77691ca4feaa00346b8e8933e3a3427b",
    },
    legacy_v1: {
      starter:
        "ac92370ea0cce20653f1de882bbb8e9474b85cba4b51bcd944553eff65649d58",
      other: "f889bc4ef180c2c666c2307af2f4d1dc0e043a8276237dc530f4ab0074f6075d",
    },
  };
  for (const format of formats) {
    for (const level of levels) {
      const prompt = buildPromptText(level, format);
      const start = prompt.indexOf("你必须严格遵守以下输出规则：");
      ok(start >= 0);
      strictEqual(
        createHash("sha256").update(prompt.slice(start)).digest("hex"),
        hashes[format][level === "启蒙" ? "starter" : "other"],
        `${format}/${level}`,
      );
    }
  }
});

Deno.test("only the selected difficulty is injected without duplicating the full template", () => {
  for (const level of levels) {
    const prompt = buildPromptText(level, "dual_tabs_v1");
    const label = level === "启蒙"
      ? "启蒙"
      : level === "简单"
      ? "初级"
      : "中级";
    ok(prompt.includes(`当前用户选择的英语难度级别为：【${label}】`));
    strictEqual(
      prompt.match(
        /\((Beginner \/ Kids|Elementary \/ Daily|Intermediate \/ Native Vibe)\)/g,
      )?.length,
      1,
    );
    ok(prompt.length <= 3600, `Prompt grew to ${prompt.length} characters`);
    ok(!prompt.includes("[User_Selected_Difficulty]"));
  }
});

Deno.test("combined generation preserves sentence groups, categories and purposes", () => {
  for (const format of formats) {
    for (const level of levels) {
      const prompt = buildPromptText(level, format);
      const example = JSON.parse(prompt.slice(prompt.lastIndexOf("\n{") + 1));
      const groups = format === "legacy_v1"
        ? ["sentences"]
        : ["image_descriptions", "scene_and_feelings"];
      deepStrictEqual(Object.keys(example).sort(), [...groups].sort());
      for (const group of groups) {
        strictEqual(example[group].length, 3);
        for (const item of example[group]) {
          deepStrictEqual(Object.keys(item).sort(), [
            "chinese",
            "english",
            "expression_purpose",
            "learning_topic_ids",
          ]);
          strictEqual(typeof item.english, "string");
          strictEqual(typeof item.chinese, "string");
        }
      }
      ok(prompt.includes("self_and_style"));
      ok(!prompt.includes("tags"));
      const parsed = parseGeneratedContent(JSON.stringify(example), format);
      ok(parsed);
      strictEqual("tags" in parsed, false);
      strictEqual(parsed.sentences.length, format === "legacy_v1" ? 3 : 6);
      for (const item of parsed.sentences) {
        deepStrictEqual(item.learning_topic_ids, []);
      }
      if (format === "dual_tabs_v1") {
        deepStrictEqual(
          parsed.sentences.map((item) => item.presentation_group),
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
});

Deno.test("unsolicited photo tags are ignored without discarding sentence metadata", () => {
  for (const format of formats) {
    const prompt = buildPromptText("简单", format);
    const example = JSON.parse(prompt.slice(prompt.lastIndexOf("\n{") + 1));
    const parsed = parseGeneratedContent(
      JSON.stringify({ ...example, tags: ["风景", "旅行"] }),
      format,
    );
    ok(parsed);
    strictEqual("tags" in parsed, false);
    strictEqual(parsed.sentences.length, format === "legacy_v1" ? 3 : 6);
    strictEqual(
      parsed.sentences.every((s) =>
        s.expression_purpose && Array.isArray(s.learning_topic_ids)
      ),
      true,
    );
  }
});

Deno.test("subjective expressions route by scene, palette and atmosphere without a client style setting", () => {
  for (const level of levels) {
    const prompt = buildPromptText(level, "dual_tabs_v1");
    for (
      const text of [
        "极简、克制且懂人性",
        "场景、色调与氛围",
        "吐槽/丧萌风",
        "温暖/治愈风",
        "诗意/探索风",
        "标准/轻快风",
        "办公格子间",
        "咖啡厅探店",
        "空无一人的街道",
        "超市购物",
        "结合整体氛围择一",
        "拒绝千篇一律的机械化翻译",
        "词汇、语法及句长都不能超出当前难度",
        "不要输出风格名称",
      ]
    ) ok(prompt.includes(text), text);
    ok(!prompt.includes("抒情优美："));
    ok(!prompt.includes("用户选择的风格"));
    ok(!prompt.includes("languageStyle"));
  }
});

Deno.test("scene expressions retain everyday speech and grounded hypothetical dialogue", () => {
  const prompt = buildPromptText("中等", "dual_tabs_v1");
  for (
    const text of [
      "严谨、敏锐的摄影师",
      "光线、材质、具体物件、动作、空间关系",
      "避免泛泛而谈的宏观词汇",
      "不推测关系、背景或内心感受",
      "感性、懂用户的朋友",
      "推测拍摄时的心理状态",
      "日常口语或内心独白",
      "不编造无依据的具体姓名、地点、时间、经历或事实",
      "不能声称对话已发生",
      "仅画面明确涉及拍照才考虑请人拍照",
      "两组遵守同一档难度",
      "难度限制优先于风格与细节",
      "不必固定为感受、对话和事件各一句",
      "不分析数据或涨跌",
    ]
  ) ok(prompt.includes(text), text);
});

Deno.test("elementary word limits and everyday detail vocabulary follow the new template", () => {
  for (const format of formats) {
    const prompt = buildPromptText("简单", format);
    for (
      const rule of [
        "每句 7 到 12 个英文单词",
        "每个 english 字段",
        "难度限制优先于风格与细节",
        "词数按空格逐句检查",
        "缩写算一个词、标点不计",
        "不是平均值",
        "超出范围就自然改写，不截断、不凑字数、不输出检查过程",
        "初中核心词汇",
        "condensation, cozy, messy, sunrise",
        "一般过去时、现在进行时及简单的介词短语",
        "避免复杂的定语从句",
      ]
    ) ok(prompt.includes(rule), `${format}: ${rule}`);
    ok(!prompt.includes("6 到 10 个英文单词"));
    for (const level of ["启蒙", "中等", "高级"] as const) {
      ok(!buildPromptText(level, format).includes("7 到 12 个英文单词"));
    }
  }
});

Deno.test("active difficulty tiers keep their length, information and grammar rules", () => {
  const guidance = [
    ["启蒙", "3 到 6 个英文单词", [
      "仅使用极其基础的日常名词和动词",
      "see, like, red, cat, milk, big",
      "仅限一般现在时",
      "主谓宾或主系表极简结构",
      "拒绝任何从句、介词短语堆叠或高级时态",
    ]],
    ["简单", "7 到 12 个英文单词", [
      "初中核心词汇",
      "常见的具体生活细节词",
      "一般过去时、现在进行时",
      "避免复杂的定语从句",
    ]],
    ["中等", "10 到 18 个英文单词", [
      "大学四六级/雅思核心词",
      "母语者地道的口语习语、短语动词",
      "drench, dapple, catch up, run out of",
      "过去完成时、过去进行时、定语从句、分词短语",
      "画面张力和情感深度",
    ]],
  ] as const;
  for (const [level, range, rules] of guidance) {
    for (const format of formats) {
      const prompt = buildPromptText(level, format);
      deepStrictEqual(prompt.match(/\d+ 到 \d+ 个英文单词/g), [range]);
      for (const rule of rules) ok(prompt.includes(rule), `${level}: ${rule}`);
      for (
        const rule of ["每个 english 字段", "不凑字数", "不要脱离照片套用"]
      ) ok(prompt.includes(rule));
      if (format === "dual_tabs_v1") ok(prompt.includes("两组遵守同一档难度"));
    }
  }
});

Deno.test("historical advanced values use the current intermediate tier", () => {
  for (const format of formats) {
    strictEqual(
      buildPromptText("高级", format),
      buildPromptText("中等", format),
    );
  }
});

Deno.test("difficulty examples fit their own word ranges", () => {
  for (
    const [level, min, max] of [["启蒙", 3, 6], ["简单", 7, 12], [
      "中等",
      10,
      18,
    ]] as const
  ) {
    const prompt = buildPromptText(level, "dual_tabs_v1");
    const examples = prompt.match(/- 示例：([^\n]+)/)?.[1].split(" / ");
    ok(examples);
    strictEqual(examples.length, 2);
    for (const example of examples) {
      const count = example.trim().split(/\s+/).length;
      ok(count >= min && count <= max, `${level}: ${example} (${count})`);
    }
  }
});

Deno.test("legacy responses keep only three objective sentences, not subjective routing", () => {
  for (const level of levels) {
    const prompt = buildPromptText(level, "legacy_v1");
    ok(prompt.includes("生成 3 个纯正、地道的英语句子"));
    ok(prompt.includes("仅生成 3 句话"));
    ok(!prompt.includes("生成 6 个"));
    ok(!prompt.includes("# Adaptive Style Routing"));
    ok(!prompt.includes("两组遵守"));
  }
});
