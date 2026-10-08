import { buildSentenceMetadataRules } from "../_shared/sentence-metadata.ts"

export interface Sentence {
  english: string
  chinese: string
  learning_topic_ids: string[]
  expression_purpose?: string
  presentation_group?: SentencePresentationGroup
}

type SentencePresentationGroup = "what_i_see" | "what_i_say"
export type GenerationFormat = "legacy_v1" | "dual_tabs_v1"

export type FinalizedSentence = Sentence & {
  id: string
  is_favorite: boolean
}

interface GeneratedContent {
  sentences: Sentence[]
}

export type ProviderName = "mimo" | "kimi" | "deepseek"

const LEARNING_TOPICS = [
  ["self_and_style", "自己与穿搭"],
  ["family_time", "家人相处"],
  ["children_growing_up", "孩子成长"],
  ["friends_gatherings", "朋友相聚"],
  ["romance_and_companionship", "恋爱与陪伴"],
  ["pet_life", "宠物日常"],
  ["food_and_drinks", "吃喝"],
  ["cooking", "下厨"],
  ["home_life", "居家"],
  ["city_life", "城市生活"],
  ["natural_scenery", "自然风景"],
  ["plants_and_wildlife", "花草与动物"],
  ["travel", "旅行"],
  ["transport", "交通出行"],
  ["sports_and_outdoors", "运动与户外"],
  ["festivals_and_celebrations", "节日与庆祝"],
  ["arts_and_entertainment", "文化娱乐"],
  ["school_and_study", "学校与学习"],
  ["work_life", "工作"],
  ["shopping", "购物"],
  ["health_and_wellness", "身体与健康"],
] as const

const LEARNING_TOPIC_IDS: Set<string> = new Set(LEARNING_TOPICS.map(([id]) => id))

export function buildPromptText(
  englishLevel: "启蒙" | "简单" | "中等" | "高级",
  languageStyle: "平铺直叙" | "抒情优美",
  generationFormat: GenerationFormat
): string {
  const englishLevelPrompt =
    englishLevel === "启蒙"
      ? "启蒙：儿童及零基础。每句 3 到 6 个英文单词，优先 3 到 5 个；只表达一个事物、动作或简单感受，不叠加背景细节。用极常见的具体词、简单感受词及主谓、主谓宾、be 句，主要用一般现在时，也可描述正在发生的动作。不用从句、抽象词、习语、俚语、比喻、拟人、双关、复杂时态或文学表达。中文短而直接，适合儿童。"
      : englishLevel === "简单"
      ? "初级：每句必须 6 到 10 个英文单词，逐句限制、不是平均，最多 10 个。输出前按空格逐句检查，缩写算一个词、标点不计；超长则删次要信息并改写，不直接截断，不输出词数或检查过程。用高频日常词、常见动作和简单感受词，一个简单分句表达一个意思及一个具体细节。可用一般现在时、现在进行时、常见动词的一般过去时、简单问句、祈使句或 can；不用从句、完成时、被动语态、分词修饰、抽象书面词、生僻习语、比喻或拟人。"
      : englishLevel === "高级"
        ? "高级：每句尽量 14 到 24 个单词；词汇、结构、信息层次更丰富，可适度修辞，但须自然准确易懂，不写诗或炫技。"
        : "中级：每句尽量 10 到 16 个英文单词。用常见而准确的动作、感受词和日常搭配，表达一个意思及一两个细节，或一种原因、时间、对比关系。可用一个简短 because/when/that 从句或简单并列，不强求从句、不嵌套。不靠堆形容词拉长句子，不用生僻词、抽象书面词、复杂语法或文学修辞。"

  const difficultyPriorityPrompt = englishLevel === "高级" ? "" :
    "难度限制适用于所有 english 字段，优先于风格、幽默和细节；信息过多就删减，保持自然完整，不凑字数、不省略必要成分。"

  const languageStylePrompt =
    englishLevel === "启蒙"
      ? "启蒙风格固定为平铺直叙：友好自然直接，不使用抒情风格。"
      : languageStyle === "抒情优美"
      ? "抒情优美：细腻温柔，有画面感、情绪和节奏，可轻微抒情；仍须自然准确易懂，不写诗、不夸张、不脱离图片。"
      : "平铺直叙：生动活泼自然的日常口语，动词具体、搭配自然、有节奏。可轻微幽默或俏皮，但须来自可见的对比、动作或细节；不用段子、网络梗、夸张笑话或生硬拟人，不虚构动作、对话、情绪或细节。"

  if (generationFormat === "dual_tabs_v1") {
    return `
根据图片生成两组英语学习句子及中文翻译。
${englishLevelPrompt}
${languageStylePrompt}
${difficultyPriorityPrompt}

image_descriptions：三句客观描述，只说可见的人、物、动作、环境或文字，不推测关系、背景和内心感受。
scene_and_feelings：三句用户会说的日常英语。此组允许基于画面的推测和假设口语：大胆推测最可能的场景、关系和感受，无须标注推测；不编造无依据的具体姓名、地点、时间、经历或事实。严格依次：
1. 我当时的感受：情绪、反应或氛围。
2. 当时会对别人说什么：围绕具体对象或活动，说一句发现、建议、邀请、提问、请求、提醒或回应，不总是问句或请求。允许假设口语，但不能声称对话已发生；不用通用寒暄、感受复述或事后配文。仅画面明确涉及拍照才考虑请人拍照。只写用户那一句及直译，不写双方对话、标签、额外引号或 I would say 开头。
3. 发生了什么：最可能的日常场景或动作。
第一、三句优先 I/we，第二句可用 you/we、祈使句或问句。三句角度不同，像母语者对朋友说话或发照片配文，不列物体、不换词重复、不写鸡汤。
${englishLevel === "高级" ? '高级场景表达每句尽量 8 到 18 个英文单词；用地道搭配、准确感受词和自然节奏，不用复杂从句、书面词、文学修辞或刻意难词。' : '两组遵守同一档难度。'}抒情风格在场景表达中仅体现温暖、真诚和画面感，不写诗、散文、文艺腔。
截图、界面、图表、股票、网页、文档等信息图，场景表达只说看到、记录或分享信息，不分析数据或涨跌。

${buildSentenceMetadataRules()}

你必须严格遵守以下输出规则：
1. 回复必须是一个 JSON 对象，不能是字符串、markdown 或代码块
2. 顶层字段必须且只能是 image_descriptions 和 scene_and_feelings
3. image_descriptions 和 scene_and_feelings 都必须恰好有 3 项
4. 每一项必须且只能包含 english、chinese、learning_topic_ids 和 expression_purpose 四个字段
5. 每句中文控制在 ${englishLevel === "启蒙" ? "3 到 15" : "8 到 30"} 个汉字之间
6. 不要输出任何多余字段或 JSON 前后的任何字符

严格按照下面的格式返回：
{"image_descriptions":[{"english":"...","chinese":"...","learning_topic_ids":[],"expression_purpose":"..."},{"english":"...","chinese":"...","learning_topic_ids":[],"expression_purpose":"..."},{"english":"...","chinese":"...","learning_topic_ids":[],"expression_purpose":"..."}],"scene_and_feelings":[{"english":"...","chinese":"...","learning_topic_ids":[],"expression_purpose":"..."},{"english":"...","chinese":"...","learning_topic_ids":[],"expression_purpose":"..."},{"english":"...","chinese":"...","learning_topic_ids":[],"expression_purpose":"..."}]}
`.trim()
  }

  return `
根据图片最直接可见的内容生成三句自然、可模仿的英文描述及中文翻译。截图、界面、图表、股票、网页、文档等信息图也只作简洁描述，不分析涨跌、不总结数据、不逐项抄写文字。
${englishLevelPrompt}
${languageStylePrompt}
${difficultyPriorityPrompt}

${buildSentenceMetadataRules()}

你必须严格遵守以下输出规则：
1. 你的回复必须是一个 JSON 对象
2. 不要把 JSON 放在字符串里
3. 不要返回 markdown
4. 不要使用 \`\`\` 或 \`\`\`json 代码块
5. 不要写任何解释、前言、结尾、备注
6. 顶层字段必须且只能是 sentences
7. sentences 必须是长度为 3 的数组
8. 每一项必须且只能包含 english、chinese、learning_topic_ids 和 expression_purpose 四个字段，必须显式写出 chinese 字段名，不能只写中文字符串
9. english、chinese 必须是非空字符串
10. 不要输出任何多余字段
11. 不要转义整个 JSON 对象
12. 不要在 JSON 前后添加任何字符
13. 每句中文控制在 ${englishLevel === "启蒙" ? "3 到 15" : "8 到 30"} 个汉字之间
14. 如果图片里有文字或数字，可以适度提到 "a screen"、"a chart"、"some numbers" 这类概括性表达，但不要逐字抄录内容

你必须严格按照下面这个格式返回：
{"sentences":[{"english":"...","chinese":"...","learning_topic_ids":[],"expression_purpose":"..."},{"english":"...","chinese":"...","learning_topic_ids":[],"expression_purpose":"..."},{"english":"...","chinese":"...","learning_topic_ids":[],"expression_purpose":"..."}]}
`.trim()
}
function parseSentences(content: string): Sentence[] | null {
  const candidate = extractSentencePayload(content)
  if (!candidate || !Array.isArray(candidate.sentences)) {
    return extractSentencesByPattern(content) ?? extractLooseSentencePairs(content)
  }

  const sentences = normalizeSentenceArray(candidate.sentences)
  if (sentences.length === 3) {
    return sentences
  }

  return extractSentencesByPattern(content) ?? extractLooseSentencePairs(content)
}

export function parseGeneratedContent(
  content: string,
  generationFormat: GenerationFormat
): GeneratedContent | null {
  if (generationFormat === "dual_tabs_v1") {
    const payload = parseJSONObject(content)
    if (!payload) {
      return null
    }

    const descriptions = normalizeSentenceArray(payload.image_descriptions, "what_i_see")
    const sceneAndFeelings = normalizeSentenceArray(payload.scene_and_feelings, "what_i_say")

    if (descriptions.length !== 3 || sceneAndFeelings.length !== 3) {
      return null
    }

    return {
      sentences: [...descriptions, ...sceneAndFeelings],
    }
  }

  const sentences = parseSentences(content)
  if (!sentences) {
    return null
  }

  return {
    sentences,
  }
}

export function parseJSONObject(content: string): any | null {
  const normalized = normalizeJSONPayload(content)
  let parsed = tryParseJSON(normalized) ?? tryParseJSON(extractJSONObject(normalized) ?? "")

  for (let attempt = 0; attempt < 2 && typeof parsed === "string"; attempt += 1) {
    parsed = tryParseJSON(parsed)
  }

  return parsed && typeof parsed === "object" && !Array.isArray(parsed) ? parsed : null
}

function extractSentencePayload(content: string): any | null {
  const normalized = normalizeJSONPayload(content)

  const direct = tryParseJSON(normalized)
  const fromDirect = normalizeParsedPayload(direct)
  if (fromDirect) {
    return fromDirect
  }

  const extracted = extractJSONObject(normalized)
  if (extracted) {
    const parsed = tryParseJSON(extracted)
    const normalizedParsed = normalizeParsedPayload(parsed)
    if (normalizedParsed) {
      return normalizedParsed
    }
  }

  return null
}

function normalizeParsedPayload(parsed: any): any | null {
  if (!parsed) {
    return null
  }

  if (typeof parsed === "string") {
    const reparsed = tryParseJSON(parsed)
    if (!reparsed || reparsed === parsed) {
      return null
    }
    return normalizeParsedPayload(reparsed)
  }

  if (Array.isArray(parsed)) {
    const sentences = normalizeSentenceArray(parsed)
    if (sentences.length === 3) {
      return { sentences }
    }
    return null
  }

  if (typeof parsed === "object" && !Array.isArray(parsed)) {
    const rawSentences = parsed.sentences

    if (typeof rawSentences === "string") {
      const reparsedSentences = tryParseJSON(rawSentences)
      const normalizedSentences = normalizeSentenceArray(reparsedSentences)
      if (normalizedSentences.length === 3) {
        return { sentences: normalizedSentences }
      }
    }

    if (Array.isArray(rawSentences)) {
      const normalizedSentences = normalizeSentenceArray(rawSentences)
      if (normalizedSentences.length === 3) {
        return { sentences: normalizedSentences }
      }
    }
  }

  return null
}

function normalizeSentenceArray(
  value: any,
  presentationGroup?: SentencePresentationGroup
): Sentence[] {
  if (!Array.isArray(value)) {
    return []
  }

  return value
    .map((item: any) => ({
      english: String(item?.english ?? "").trim(),
      chinese: String(item?.chinese ?? "").trim(),
      learning_topic_ids: normalizeLearningTopicIDs(item?.learning_topic_ids),
      // Missing/invalid categories must not masquerade as an intentional empty classification.
      expression_purpose: Array.isArray(item?.learning_topic_ids) &&
          item.learning_topic_ids.length <= 2 &&
          normalizeLearningTopicIDs(item.learning_topic_ids).length === item.learning_topic_ids.length
        ? normalizeExpressionPurpose(item?.expression_purpose)
        : undefined,
      ...(presentationGroup ? { presentation_group: presentationGroup } : {}),
    }))
    .filter(
      (item: Sentence) =>
        item.english && item.chinese
    )
}

function normalizeExpressionPurpose(value: unknown): string | undefined {
  if (typeof value !== "string") return undefined
  const purpose = value.trim().replace(/\s+/g, " ")
  return purpose.length > 0 && purpose.length <= 240 && purpose.split(" ").length <= 30
    ? purpose : undefined
}

function normalizeLearningTopicIDs(value: unknown): string[] {
  if (!Array.isArray(value)) {
    return []
  }

  return Array.from(
    new Set(
      value
        .map((item) => String(item ?? "").trim())
        .filter((topicID) => LEARNING_TOPIC_IDS.has(topicID))
    )
  ).slice(0, 2)
}

function extractSentencesByPattern(content: string): Sentence[] | null {
  const normalized = normalizeJSONPayload(content)
  const pairRegex = /"english"\s*:\s*"((?:\\.|[^"\\])*)"\s*,\s*"chinese"\s*:\s*"((?:\\.|[^"\\])*)"/g

  const matches: Sentence[] = []
  let match: RegExpExecArray | null

  while ((match = pairRegex.exec(normalized)) !== null) {
    const english = decodeJSONStringFragment(match[1]).trim()
    const chinese = decodeJSONStringFragment(match[2]).trim()

    if (english && chinese) {
      matches.push({ english, chinese, learning_topic_ids: [] })
    }
  }

  return matches.length === 3 ? matches : null
}

function extractLooseSentencePairs(content: string): Sentence[] | null {
  const normalized = normalizeJSONPayload(content)
  const objectRegex = /\{[^{}]*"english"\s*:\s*"((?:\\.|[^"\\])*)"(?<tail>[^{}]*)\}/g

  const matches: Sentence[] = []
  let match: RegExpExecArray | null

  while ((match = objectRegex.exec(normalized)) !== null) {
    const english = decodeJSONStringFragment(match[1]).trim()
    const tail = match.groups?.tail ?? ""
    const chinese = extractLooseChineseValue(tail)

    if (english && chinese) {
      matches.push({ english, chinese, learning_topic_ids: [] })
    }
  }

  return matches.length === 3 ? matches : null
}

function extractLooseChineseValue(value: string): string {
  const keyedMatch = /"chinese"\s*:\s*"((?:\\.|[^"\\])*)"/.exec(value)
  if (keyedMatch) {
    return decodeJSONStringFragment(keyedMatch[1]).trim()
  }

  const stringRegex = /"((?:\\.|[^"\\])*)"/g
  let match: RegExpExecArray | null

  while ((match = stringRegex.exec(value)) !== null) {
    const candidate = decodeJSONStringFragment(match[1]).trim()
    if (containsCJK(candidate)) {
      return candidate
    }
  }

  return ""
}

function containsCJK(value: string): boolean {
  return /[\u3400-\u9fff]/.test(value)
}

function decodeJSONStringFragment(value: string): string {
  try {
    return JSON.parse(`"${value}"`)
  } catch {
    return value
      .replace(/\\"/g, '"')
      .replace(/\\\\/g, "\\")
      .replace(/\\n/g, " ")
      .replace(/\\r/g, " ")
      .replace(/\\t/g, " ")
  }
}

function tryParseJSON(value: string): any | null {
  try {
    return JSON.parse(value)
  } catch {
    return null
  }
}

function normalizeJSONPayload(content: string): string {
  const trimmed = content.trim()

  if (trimmed.startsWith("```")) {
    return trimmed
      .replace(/^```json\s*/i, "")
      .replace(/^```\s*/i, "")
      .replace(/\s*```$/, "")
      .trim()
  }

  return trimmed
}

function extractJSONObject(content: string): string | null {
  const start = content.indexOf("{")
  const end = content.lastIndexOf("}")

  if (start === -1 || end === -1 || end <= start) {
    return null
  }

  return content.slice(start, end + 1).trim()
}
export function hasSupportedStoredSentenceCount(count: number, generationFormat: GenerationFormat): boolean {
  return generationFormat === "legacy_v1" ? count >= 3 : count === 3 || count === 6
}

function isUUID(value: unknown): value is string {
  return typeof value === "string" &&
    /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value)
}

export function toClientSentences(
  sentences: any[],
  generationFormat: GenerationFormat
): any[] {
  const visibleSentences = generationFormat === "legacy_v1" ? sentences.slice(0, 3) : sentences

  return visibleSentences.map((sentence: any) => {
    const normalized = {
      id: !isUUID(sentence?.id) ? crypto.randomUUID() : sentence.id,
      english: String(sentence?.english ?? "").trim(),
      chinese: String(sentence?.chinese ?? "").trim(),
      learning_topic_ids: normalizeLearningTopicIDs(sentence?.learning_topic_ids),
      is_favorite: sentence?.is_favorite === true,
    }

    return generationFormat === "dual_tabs_v1"
      ? {
          ...normalized,
          presentation_group: sentence?.presentation_group === "what_i_say"
            ? "what_i_say"
            : "what_i_see",
        }
      : normalized
  })
}
