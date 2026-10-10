import { deepStrictEqual, ok, strictEqual } from "node:assert";
import { createHash } from "node:crypto";
import {
  buildPromptText,
  parseGeneratedContent,
  selectQuestionTypes,
} from "../../supabase/functions/generate-memory-v2/content.ts";
import { buildPhotoCategoryRules } from "../../supabase/functions/generate-memory-v2/photo-categories.ts";
import { buildSentenceMetadataRules } from "../../supabase/functions/_shared/sentence-metadata.ts";

const levels = ["启蒙", "简单", "中等", "高级"] as const;
const formats = ["legacy_v1", "dual_tabs_v1"] as const;

// Compare the unchanged teaching rules independently of the category catalog.
function sentencePromptBaseline(prompt: string): string {
  return prompt.replace(`\n\n${buildPhotoCategoryRules(false)}`, "")
    .replace(`\n\n${buildSentenceMetadataRules()}`, "")
    .replace(
      "image_descriptions、scene_and_feelings 和 tags；tags 是照片分类 ID 数组",
      "image_descriptions 和 scene_and_feelings",
    )
    .replace("sentences 和 tags；tags 是照片分类 ID 数组", "sentences")
    .replace(/,"tags":\[\](?=\}$)/, "");
}

Deno.test("sentence teaching rules match the reviewed baseline at every difficulty", () => {
  const baseline = [
    [
      "legacy_v1",
      "启蒙",
      "4c3ec5c06d6f306bdd4d0fa180829e7fd78e758ab8ed7d88f85ac7dbffd95563",
    ],
    [
      "legacy_v1",
      "简单",
      "c3323bd27520d0be0e0c1ad62e82d618247714eeb48271a46bd0ec43f70c3fc1",
    ],
    [
      "legacy_v1",
      "中等",
      "74a8fbb7e26a280f0cdca8a1193065768fe0de53cb886c68cf8349c07f65d84a",
    ],
    [
      "legacy_v1",
      "高级",
      "647e45bb7969e2a9a9fa02445e2c49d7adae77724a26f19e399280d19ec08c8f",
    ],
    [
      "dual_tabs_v1",
      "启蒙",
      "1c7020066752d5a775bf66f89a1a2d0a00ffb40c2cb6490a4828342be378c56b",
    ],
    [
      "dual_tabs_v1",
      "简单",
      "e6bcd48aedb27c2fd7bd0a9fbbc4ed2abc9949f422413e7ed39e7b6038811345",
    ],
    [
      "dual_tabs_v1",
      "中等",
      "93cc4c90659a1cc2830808ccf6577f02b257b58797e1f54910ee94e157e2b19e",
    ],
    [
      "dual_tabs_v1",
      "高级",
      "644ea2e7fa029f5e0f4ae5b24ded38139a65a44d1188244c65f9ceb8d4171670",
    ],
  ] as const;
  for (const [format, level, hash] of baseline) {
    strictEqual(
      createHash("sha256").update(
        sentencePromptBaseline(buildPromptText(level, format)),
      ).digest("hex"),
      hash,
      `${format}/${level}`,
    );
  }
});

Deno.test("photo classification preserves all existing sentence output requirements", () => {
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
      const prompt = sentencePromptBaseline(buildPromptText(level, format));
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

Deno.test("natural beginner guidance stays compact without shrinking output rules", () => {
  const prompt = buildPromptText("简单", "dual_tabs_v1");
  const sentenceOnly = sentencePromptBaseline(prompt);
  ok(sentenceOnly.indexOf("你必须严格遵守以下输出规则：") <= (5066 - 861) / 2);
  ok(sentenceOnly.length <= 2900);
  ok(prompt.length <= 4000, `Prompt grew to ${prompt.length} characters`);
});

Deno.test("combined generation preserves sentence groups, categories and purposes", () => {
  for (const format of formats) {
    for (const level of levels) {
      const prompt = buildPromptText(level, format);
      const example = JSON.parse(prompt.slice(prompt.lastIndexOf("\n{") + 1));
      const groups = format === "legacy_v1"
        ? ["sentences"]
        : ["image_descriptions", "scene_and_feelings"];
      deepStrictEqual(Object.keys(example).sort(), [...groups, "tags"].sort());
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
  ok(prompt.includes(buildPhotoCategoryRules(false)));
      const parsed = parseGeneratedContent(JSON.stringify(example), format);
      ok(parsed);
      deepStrictEqual(parsed.tags, []);
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

Deno.test("unknown photo categories are ignored without discarding sentence metadata", () => {
  for (const format of formats) {
    const prompt = buildPromptText("简单", format);
    const example = JSON.parse(prompt.slice(prompt.lastIndexOf("\n{") + 1));
    const parsed = parseGeneratedContent(
      JSON.stringify({ ...example, tags: ["风景", "旅行"] }),
      format,
    );
    ok(parsed);
    deepStrictEqual(parsed.tags, []);
    strictEqual(parsed.sentences.length, format === "legacy_v1" ? 3 : 6);
    strictEqual(
      parsed.sentences.every((s) =>
        s.expression_purpose && Array.isArray(s.learning_topic_ids)
      ),
      true,
    );
  }
});

Deno.test("one natural conversational style keeps grounded humor and child-safe simplicity", () => {
  for (const format of formats) {
    for (const level of levels) {
      const prompt = buildPromptText(level, format);
      ok(!prompt.includes("抒情优美："));
      ok(!prompt.includes("用户选择的风格"));
      if (level === "启蒙") {
        ok(prompt.includes("友好自然直接"));
        ok(prompt.includes("中文短而直接，适合儿童"));
        ok(!prompt.includes("可轻微幽默或俏皮"));
      } else {
        for (
          const text of [
            "自然的日常口语",
            "可轻微幽默或俏皮",
            "须来自可见的对比、动作或细节",
            format === "dual_tabs_v1" ? "不把推测写成已知事实" : "不虚构动作、对话、情绪或细节",
          ]
        ) {
          ok(prompt.includes(text), `${level}: ${text}`);
        }
      }
    }
  }
});

Deno.test("scene expressions retain everyday speech and grounded hypothetical dialogue", () => {
  const prompt = buildPromptText("中等", "dual_tabs_v1");
  for (
    const text of [
      "不推测人物关系、背景和内心感受",
      "提供合理的可能说法",
      "不替用户断定唯一的情绪或意图",
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

Deno.test("question types are sampled independently with an even open/closed split", () => {
  for (const imageValue of [0, 0.499999, 0.5, 0.999999]) {
    for (const sceneValue of [0, 0.499999, 0.5, 0.999999]) {
      const values = [imageValue, sceneValue];
      let calls = 0;
      deepStrictEqual(selectQuestionTypes(() => values[calls++]), {
        imageDescriptions: imageValue < 0.5 ? "open" : "closed",
        sceneAndFeelings: sceneValue < 0.5 ? "open" : "closed",
      });
      strictEqual(calls, 2);
    }
  }
});

Deno.test("both question types reach their own group at every difficulty", () => {
  for (const level of levels) {
    for (const imageValue of [0, 0.5]) {
      for (const sceneValue of [0, 0.5]) {
        const values = [imageValue, sceneValue];
        const types = selectQuestionTypes(() => values.shift()!);
        const prompt = buildPromptText(level, "dual_tabs_v1", types);
        const imageRules = prompt.slice(prompt.indexOf("image_descriptions："), prompt.indexOf("scene_and_feelings："));
        const sceneRules = prompt.slice(prompt.indexOf("scene_and_feelings："));
        for (const [rules, type] of [[imageRules, types.imageDescriptions], [sceneRules, types.sceneAndFeelings]]) {
          ok(rules.includes(type === "open" ? "本次用开放式问题" : "本次用封闭式问题"));
          ok(!rules.includes(type === "open" ? "本次用封闭式问题" : "本次用开放式问题"));
        }
        const example = JSON.parse(prompt.slice(prompt.lastIndexOf("\n{") + 1));
        strictEqual(example.image_descriptions.length, 3);
        strictEqual(example.scene_and_feelings.length, 3);
        ok(prompt.length <= 4000, `Prompt grew to ${prompt.length} characters`);
        strictEqual(buildPromptText(level, "legacy_v1", types), buildPromptText(level, "legacy_v1"));
      }
    }
  }
});

Deno.test("both groups prioritize useful expressions over photo captions at every difficulty", () => {
  for (const level of levels) {
    const prompt = buildPromptText(level, "dual_tabs_v1");
    for (const rule of [
      "照片所示场景中用得上的英语",
      "不是给照片配文",
      "不输出分析过程",
      "用户在这里会对谁说、想表达什么",
      "下次遇到类似场景还能用吗",
      "表达价值优先于细节覆盖、修辞和句式变化",
      "不必覆盖所有意图",
      "不要把所有照片都变成点餐、问路",
      "六句提供不同的表达选择",
    ]) ok(prompt.includes(rule), `${level}: ${rule}`);
    ok(!prompt.includes("1. 我当时的感受："));
    ok(!prompt.includes("2. 发生了什么："));
  }
});

Deno.test("photo descriptions select useful observations instead of a fixed detail checklist", () => {
  for (const level of levels) {
    const prompt = buildPromptText(level, "dual_tabs_v1");
    const descriptionRules = prompt.slice(prompt.indexOf("image_descriptions："), prompt.indexOf("scene_and_feelings："));
    for (const rule of [
      "不推测人物关系、背景和内心感受",
      "两句客观陈述和一个观察问题",
      "把眼前值得注意的东西说清楚",
      "选择两个值得向别人指出或分享的观察",
      "不固定为主体和细节",
      "不为覆盖颜色、材质、光线而罗列细节",
      "增加能表达的意思，不只堆形容词",
      "让现场的人有理由交流",
      "不要求对方描述照片",
      "不做识别或数数测验",
      "不问经历或泛泛感受",
      "三句不重复，问题不只是陈述改问句",
    ]) ok(descriptionRules.includes(rule), `${level}: ${rule}`);
    ok(!descriptionRules.includes("可直接看出答案"));
    ok(!/例如|示例|example/i.test(descriptionRules));
  }
});

Deno.test("scene expressions select communication needs without fixing feelings or events", () => {
  for (const level of levels) {
    const prompt = buildPromptText(level, "dual_tabs_v1");
    for (const rule of [
      "贴合具体对象或活动",
      "按场景选择最有用的两种表达意图",
      "表达需要、偏好或感受，分享经历，提出建议或邀请",
      "不固定为感受加经历",
      "不复述画面描述",
      "不替用户断定唯一的情绪或意图",
      "不机械套用 I feel + 形容词",
      "不强制第一人称开头",
      "句式服从难度",
    ]) ok(prompt.includes(rule), `${level}: ${rule}`);
    ok(!prompt.includes("第一、三句优先 I/we"));
    const sceneRules = prompt.slice(prompt.indexOf("scene_and_feelings："), prompt.indexOf(buildSentenceMetadataRules()));
    ok(!/例如|示例|example/i.test(sceneRules), "Do not seed another repeated English opening with an example");
    ok(!sceneRules.includes("第二句优先 I/we"));
    ok(!buildPromptText(level, "legacy_v1").includes("不机械套用 I feel"));
  }
});

Deno.test("each group ends in a question aligned with its own purpose without changing the schema", () => {
  for (const level of levels) {
    const prompt = buildPromptText(level, "dual_tabs_v1");
    const sceneRules = prompt.slice(prompt.indexOf("scene_and_feelings："), prompt.indexOf(buildSentenceMetadataRules()));
    for (const rule of [
      "两组均为前两句陈述、第三句疑问",
      "以 ? 结尾，中文也用问句",
      "问题遵守难度，不附答案或新增字段",
      "问身边的人一句自然的聊天问题，不是看图理解题",
      "本次用开放式问题",
      "不硬凑归属或许可问题，不问翻看私人物品",
    ]) ok(sceneRules.includes(rule), `${level}: ${rule}`);
    const example = JSON.parse(prompt.slice(prompt.lastIndexOf("\n{") + 1));
    for (const group of ["image_descriptions", "scene_and_feelings"]) {
      example[group][2] = { ...example[group][2], english: group === "image_descriptions"
        ? "What is making the water look so bright?" : "Would you like to stay here longer?",
        chinese: group === "image_descriptions" ? "是什么让水面看起来这么亮？" : "你想在这里多待一会儿吗？" };
    }
    const parsed = parseGeneratedContent(JSON.stringify(example), "dual_tabs_v1");
    ok(parsed);
    strictEqual(parsed.sentences.length, 6);
    for (const [index, group] of [[2, "image_descriptions"], [5, "scene_and_feelings"]] as const) {
      strictEqual(parsed.sentences[index].english, example[group][2].english);
      strictEqual(parsed.sentences[index].chinese, example[group][2].chinese);
    }
    ok(!buildPromptText(level, "legacy_v1").includes("第三句疑问"));
  }
});

Deno.test("beginner word limits remain explicit per sentence in both formats", () => {
  for (const format of formats) {
    const prompt = buildPromptText("简单", format);
    for (
      const rule of [
        "每句必须 6 到 10 个英文单词，逐句限制、不是平均，最多 10 个",
        "难度限制适用于所有 english 字段",
        "优先于风格、幽默和细节",
        "输出前按空格逐句检查",
        "缩写算一个词、标点不计",
        "超长则删次要信息并改写，不直接截断",
        "不输出词数或检查过程",
        "不用从句、完成时、被动语态、分词修饰、抽象书面词、生僻习语、比喻或拟人",
      ]
    ) ok(prompt.includes(rule), `${format}: ${rule}`);
    ok(!prompt.includes("尽量控制在 6 到 10"));
    for (const level of ["启蒙", "中等", "高级"] as const) {
      ok(!buildPromptText(level, format).includes("最多 10 个"));
    }
  }
});

Deno.test("active difficulty tiers keep their length, information and grammar rules", () => {
  const guidance = [
    ["启蒙", "3 到 6 个英文单词", [
      "只表达一个事物、动作或简单感受",
      "不叠加背景细节",
      "极常见的具体词、简单感受词",
      "不用从句、抽象词、习语",
    ]],
    ["简单", "6 到 10 个英文单词", [
      "一个意思及一个具体细节",
      "一个简单分句",
      "常见动词的一般过去时",
      "高频日常词、常见动作和简单感受词",
    ]],
    ["中等", "10 到 16 个英文单词", [
      "常见而准确的动作、感受词和日常搭配",
      "一个意思及一两个细节",
      "一个简短 because/when/that 从句",
      "不强求从句、不嵌套",
      "不靠堆形容词拉长句子",
    ]],
  ] as const;
  for (const [level, range, rules] of guidance) {
    for (const format of formats) {
      const prompt = buildPromptText(level, format);
      deepStrictEqual(prompt.match(/\d+ 到 \d+ 个英文单词/g), [range]);
      for (const rule of rules) ok(prompt.includes(rule), `${level}: ${rule}`);
      for (
        const rule of ["适用于所有 english 字段", "不凑字数", "不省略必要成分"]
      ) ok(prompt.includes(rule));
      if (format === "dual_tabs_v1") ok(prompt.includes("两组遵守同一档难度"));
    }
  }
});

Deno.test("legacy advanced requests retain their description and conversational ranges", () => {
  const legacy = buildPromptText("高级", "legacy_v1");
  ok(legacy.includes("14 到 24 个单词"));
  ok(!legacy.includes("8 到 18 个英文单词"));
  const dual = buildPromptText("高级", "dual_tabs_v1");
  ok(dual.includes("14 到 24 个单词"));
  ok(dual.includes("8 到 18 个英文单词"));
  ok(!dual.includes("中级："));
});
