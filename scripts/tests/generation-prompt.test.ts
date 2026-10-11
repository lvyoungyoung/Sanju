import { deepStrictEqual, ok, strictEqual } from "node:assert";
import { createHash } from "node:crypto";
import {
  buildPromptText,
  parseGeneratedContent,
  selectSceneQuestionType,
} from "../../supabase/functions/generate-memory-v2/content.ts";
import { buildPhotoCategoryRules } from "../../supabase/functions/generate-memory-v2/photo-categories.ts";
import { buildSentenceMetadataRules } from "../../supabase/functions/_shared/sentence-metadata.ts";

const levels = ["启蒙", "简单", "中等", "高级"] as const;
const formats = ["legacy_v1", "dual_tabs_v1"] as const;

// Compare teaching rules independently of the category catalog.
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
      "a24596caf877ce936e24e2dca440598b4facfe701f59d09fc7959ab5c943dacc",
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
      "6289eb03301195084593348d4417c8edfea7c071a8ea1d9bd5fe2ef041bf4613",
    ],
    [
      "dual_tabs_v1",
      "简单",
      "e0eaf248be04517224e19ca72f223b6e2df3303a8624d143a31ab81aa2205d19",
    ],
    [
      "dual_tabs_v1",
      "中等",
      "8d3387be81b0ffb4d64935adcf88c62765c48425be8122f0e692ed5f1a192f53",
    ],
    [
      "dual_tabs_v1",
      "高级",
      "e7ac533693b45102ad0e3bc9d7873fceec6bb110be938775a570f2888d7a5c1f",
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
  const styleStart = prompt.indexOf("场景表达风格自适应：");
  const styleEnd = prompt.indexOf("前两句生成用户在这个场景下自然会说的话");
  ok(styleStart >= 0 && styleEnd > styleStart);
  const styleRules = prompt.slice(styleStart, styleEnd);
  ok(styleRules.length <= 500, `Style rules grew to ${styleRules.length} characters`);
  const originalRules = prompt.replace(styleRules, "");
  const sentenceOnly = sentencePromptBaseline(originalRules);
  ok(sentenceOnly.indexOf("你必须严格遵守以下输出规则：") <= (5066 - 861) / 2);
  ok(sentenceOnly.length <= 2900);
  ok(originalRules.length <= 4000);
  ok(prompt.length <= 4500, `Prompt grew to ${prompt.length} characters`);
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
      "两组遵守同一档难度",
      "难度限制适用于所有 english 字段，优先于风格、幽默和细节",
      "场景表达保持日常口语",
      "不分析数据或涨跌",
    ]
  ) ok(prompt.includes(text), text);
});

Deno.test("only scene question type is sampled with an even open/closed split", () => {
  for (const value of [0, 0.499999, 0.5, 0.999999]) {
    let calls = 0;
    strictEqual(selectSceneQuestionType(() => { calls++; return value; }), value < 0.5 ? "open" : "closed");
    strictEqual(calls, 1);
  }
});

Deno.test("question types affect only scene expressions at every difficulty", () => {
  for (const level of levels) {
    let expectedImageRules: string | undefined;
    for (const type of ["open", "closed"] as const) {
      const prompt = buildPromptText(level, "dual_tabs_v1", type);
      const imageRules = prompt.slice(prompt.indexOf("image_descriptions："), prompt.indexOf("scene_and_feelings："));
      const sceneRules = prompt.slice(prompt.indexOf("scene_and_feelings："));
      expectedImageRules ??= imageRules;
      strictEqual(imageRules, expectedImageRules);
      ok(!imageRules.includes("本次用开放式问题"));
      ok(!imageRules.includes("本次用封闭式问题"));
      ok(sceneRules.includes(type === "open" ? "本次用开放式问题" : "本次用封闭式问题"));
      ok(!sceneRules.includes(type === "open" ? "本次用封闭式问题" : "本次用开放式问题"));
      const example = JSON.parse(prompt.slice(prompt.lastIndexOf("\n{") + 1));
      strictEqual(example.image_descriptions.length, 3);
      strictEqual(example.scene_and_feelings.length, 3);
      ok(prompt.length <= 4500, `Prompt grew to ${prompt.length} characters`);
      strictEqual(buildPromptText(level, "legacy_v1", type), buildPromptText(level, "legacy_v1"));
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
      "前两句生成用户在这个场景下自然会说的话",
      "六句提供不同的表达选择",
    ]) ok(prompt.includes(rule), `${level}: ${rule}`);
    ok(!prompt.includes("1. 我当时的感受："));
    ok(!prompt.includes("2. 发生了什么："));
  }
});

Deno.test("adaptive style applies only to scene expressions and preserves difficulty without restricting intent", () => {
  for (const level of levels) {
    const prompt = buildPromptText(level, "dual_tabs_v1");
    const styleStart = prompt.indexOf("场景表达风格自适应：");
    const sceneStart = prompt.indexOf("scene_and_feelings：");
    const styleEnd = prompt.indexOf("前两句生成用户在这个场景下自然会说的话");
    ok(styleStart > sceneStart && styleEnd > styleStart);
    const style = prompt.slice(styleStart, styleEnd);
    for (const rule of [
      "仅作用于本组", "场景、色调与氛围", "选一种最契合的语气",
      "吐槽/丧萌", "温暖/治愈", "诗意/探索", "标准/轻快",
      "不凭咖啡或阴天单独决定",
      "无明确风格线索时用此项",
      "风格须遵守难度、词数和问题类型", "不写修辞问句",
    ]) ok(style.includes(rule), `${level}: ${rule}`);
    for (const removed of [
      "风格只调整语气", "不改变表达意图", "不强加情绪", "不只写氛围旁白",
      "不强行卖惨", "不猜测周一、深夜或疲惫", "不写社交配文",
      "通过具体感受表达", "不写抽象哲理、比喻或文学独白",
      "不写诗、散文、文艺腔",
    ]) {
      ok(!prompt.includes(removed), `${level}: removed restriction ${removed}`);
    }
    strictEqual(style.includes("启蒙仅用温暖或轻快的儿童口语"), level === "启蒙");
    ok(!prompt.slice(0, sceneStart).includes("风格自适应"));
    ok(!buildPromptText(level, "legacy_v1").includes("风格自适应"));
    ok(!/例如|示例|example/i.test(style));
  }
});

Deno.test("photo descriptions select useful observations instead of a fixed detail checklist", () => {
  for (const level of levels) {
    const prompt = buildPromptText(level, "dual_tabs_v1");
    const descriptionRules = prompt.slice(prompt.indexOf("image_descriptions："), prompt.indexOf("scene_and_feelings："));
    for (const rule of [
      "不推测人物关系、背景和内心感受",
      "前两句是客观陈述，第三句也是客观陈述，或针对客观内容的自然提问",
      "选择两个值得向别人指出或分享的观察",
      "不固定为主体和细节",
      "不为覆盖颜色、材质、光线而罗列细节",
      "增加能表达的意思，不只堆形容词",
      "不做识别或数数测验",
      "前两句不重复",
    ]) ok(descriptionRules.includes(rule), `${level}: ${rule}`);
    ok(!descriptionRules.includes("可直接看出答案"));
    ok(!/例如|示例|example/i.test(descriptionRules));
  }
});

Deno.test("all photo expressions stay objective without forced questions or answer pairing", () => {
  for (const level of levels) {
    for (const type of ["open", "closed"] as const) {
      const prompt = buildPromptText(level, "dual_tabs_v1", type);
      const rules = prompt.slice(prompt.indexOf("image_descriptions："), prompt.indexOf("scene_and_feelings："));
      for (const rule of [
        "三句均以照片中可见的客观内容为依据",
        "第三句围绕照片中的客观内容补充观察或自然提问",
        "不表达主观感受、意愿或建议",
        "只有确实有询问需要时才提问",
        "不强制问句、问题类型或问答配对",
      ]) ok(rules.includes(rule), `${level}/${type}: ${rule}`);
      ok(!rules.includes("特点、变化或关系"));
      ok(!rules.includes("确认一个可见特点或关系"));
      ok(!rules.includes("回应、感叹"));
      ok(!rules.includes("自然的交流表达"));
      ok(!prompt.includes("恰好能作为这个问题的自然回答"));
      ok(!prompt.includes("两组均为前两句陈述、第三句疑问"));
    }
  }
});

Deno.test("scene expressions follow atmosphere without prescribing distinct communication intentions", () => {
  for (const level of levels) {
    const prompt = buildPromptText(level, "dual_tabs_v1");
    for (const rule of [
      "前两句生成用户在这个场景下自然会说的话，贴合照片的氛围，内容有所区别。",
      "不复述画面描述",
      "不替用户断定唯一的情绪或意图",
      "不机械套用 I feel + 形容词",
      "不强制第一人称开头",
      "句式服从难度",
    ]) ok(prompt.includes(rule), `${level}: ${rule}`);
    for (const removed of [
      "选择最有用的两种表达意图",
      "表达需要、偏好或感受，分享经历，提出建议或邀请",
      "不固定为感受加经历", "不必覆盖所有意图", "不要把所有照片都变成点餐、问路",
    ]) ok(!prompt.includes(removed), `${level}: removed intention checklist ${removed}`);
    ok(!prompt.includes("第一、三句优先 I/we"));
    const sceneRules = prompt.slice(prompt.indexOf("scene_and_feelings："), prompt.indexOf(buildSentenceMetadataRules()));
    ok(!/例如|示例|example/i.test(sceneRules), "Do not seed another repeated English opening with an example");
    ok(!sceneRules.includes("第二句优先 I/we"));
    ok(!buildPromptText(level, "legacy_v1").includes("不机械套用 I feel"));
  }
});

Deno.test("only scene expressions require a final question while photo expressions accept either form", () => {
  for (const level of levels) {
    const prompt = buildPromptText(level, "dual_tabs_v1");
    const sceneRules = prompt.slice(prompt.indexOf("scene_and_feelings："), prompt.indexOf(buildSentenceMetadataRules()));
    for (const rule of [
      "仅 scene_and_feelings 必须前两句陈述、第三句疑问",
      "以 ? 结尾，中文也用问句",
      "问题均遵守难度，不附答案或新增字段",
      "问身边的人一句自然的聊天问题，不是看图理解题",
      "本次用开放式问题",
      "不硬凑归属或许可问题",
    ]) ok(sceneRules.includes(rule), `${level}: ${rule}`);
    for (const removed of ["不问翻看私人物品", "仅画面明确涉及拍照才考虑请人拍照", "不能声称对话已发生"]) {
      ok(!sceneRules.includes(removed), `${level}: removed question restriction ${removed}`);
    }
    for (const photoExpression of [
      { english: "The evening light turns the clouds above the station pink.", chinese: "傍晚的光把车站上方的云映成了粉色。" },
      { english: "Are those clouds above the station turning pink in the sunset?", chinese: "车站上方的云是不是被夕阳映成了粉色？" },
    ]) {
      const example = JSON.parse(prompt.slice(prompt.lastIndexOf("\n{") + 1));
      for (const group of ["image_descriptions", "scene_and_feelings"]) {
        example[group][2] = { ...example[group][2], english: group === "image_descriptions"
          ? photoExpression.english : "Would you like to stay here longer?",
          chinese: group === "image_descriptions" ? photoExpression.chinese : "你想在这里多待一会儿吗？" };
      }
      const parsed = parseGeneratedContent(JSON.stringify(example), "dual_tabs_v1");
      ok(parsed);
      strictEqual(parsed.sentences.length, 6);
      for (const [index, group] of [[2, "image_descriptions"], [5, "scene_and_feelings"]] as const) {
        strictEqual(parsed.sentences[index].english, example[group][2].english);
        strictEqual(parsed.sentences[index].chinese, example[group][2].chinese);
      }
    }
    ok(!buildPromptText(level, "legacy_v1").includes("第三句疑问"));
  }
});

Deno.test("beginner word limits remain explicit per sentence in both formats", () => {
  for (const format of formats) {
    const prompt = buildPromptText("简单", format);
    for (
      const rule of [
        "每句必须 8 到 12 个英文单词，逐句限制、不是平均，最多 12 个",
        "难度限制适用于所有 english 字段",
        "优先于风格、幽默和细节",
        "输出前按空格逐句检查",
        "缩写算一个词、标点不计",
        "超长则删次要信息并改写，不直接截断",
        "不输出词数或检查过程",
        "不用从句、完成时、被动语态、分词修饰、抽象书面词、生僻习语、比喻或拟人",
      ]
    ) ok(prompt.includes(rule), `${format}: ${rule}`);
    ok(!prompt.includes("6 到 10 个英文单词"));
    ok(!prompt.includes("最多 10 个"));
    for (const level of ["启蒙", "中等", "高级"] as const) {
      ok(!buildPromptText(level, format).includes("最多 12 个"));
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
    ["简单", "8 到 12 个英文单词", [
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
