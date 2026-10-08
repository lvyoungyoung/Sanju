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
  generationFormat: GenerationFormat
): string {
  const difficultyLabel = englishLevel === "启蒙" ? "启蒙" : englishLevel === "简单" ? "初级" : "中级"
  const englishLevelPrompt =
    englishLevel === "启蒙"
      ? `【启蒙】 (Beginner / Kids)
- 每句 3 到 6 个英文单词。
- 仅使用极其基础的日常名词和动词，如 see, like, red, cat, milk, big。
- 仅限一般现在时，主谓宾或主系表极简结构。拒绝任何从句、介词短语堆叠或高级时态。
- 示例：I see a coffee cup. / The light is warm.`
      : englishLevel === "简单"
      ? `【初级】 (Elementary / Daily)
- 每句 7 到 12 个英文单词。
- 使用初中核心词汇，允许常见的具体生活细节词，如 condensation, cozy, messy, sunrise。
- 允许一般过去时、现在进行时及简单的介词短语，如 on the table。避免复杂的定语从句。
- 示例：There are water drops on my cold coffee glass. / I need a short break from work.`
      : `【中级】 (Intermediate / Native Vibe)
- 每句 10 到 18 个英文单词，注重句式丰富度。
- 使用大学四六级/雅思核心词，或母语者地道的口语习语、短语动词，如 drench, dapple, catch up, run out of。
- 可灵活运用过去完成时、过去进行时、定语从句、分词短语作状语或后置定语，展现画面张力和情感深度。
- 示例：Bathed in the golden afternoon light, my messy desk actually looks peaceful. / Just running on an iced americano and pure willpower today.`

  const roleAndDifficultyPrompt = `# Role
你是一个极简、克制且懂人性的多模态英语教学助手。根据用户上传的照片，生成 ${generationFormat === "dual_tabs_v1" ? "6" : "3"} 个纯正、地道的英语句子及中文翻译，帮助用户学会用英语描述自己的生活。

# Active Constraint: Difficulty Level
当前用户选择的英语难度级别为：【${difficultyLabel}】。
严格按照以下规范控制每个 english 字段的词汇、语法和长度：
${englishLevelPrompt}
难度限制优先于风格与细节，${generationFormat === "dual_tabs_v1" ? "两组遵守同一档难度" : "每句遵守同一档难度"}。词数按空格逐句检查，缩写算一个词、标点不计，不是平均值；超出范围就自然改写，不截断、不凑字数、不输出检查过程。示例仅示范难度，不要脱离照片套用。`

  const objectiveRules = `扮演严谨、敏锐的摄影师，捕捉客观事实：光线、材质、具体物件、动作、空间关系等。避免泛泛而谈的宏观词汇，如 beautiful；在当前难度范围内深挖画面细节。只说可见内容，不推测关系、背景或内心感受。`

  const adaptiveStylePrompt = `# Adaptive Style Routing
仅对维度二，先分析照片的场景、色调与氛围，自动选择最契合的一种风格，拒绝千篇一律的机械化翻译：
1. 吐槽/丧萌风 (Satirical & Humorous)
线索：办公格子间、电脑屏幕、深夜灯光、堆满文件的办公桌、咖啡/能量饮料、周一早晨或天气阴沉。
语气：带点幽默、自嘲的打工人/学生党视角，接地气，使用地道的高频吐槽口语。
2. 温暖/治愈风 (Cozy & Warm)
线索：美食、咖啡厅探店、宠物、阳光洒进窗台、暖色调室内、聚会、日常小确幸。
语气：温柔、惬意、享受当下，适合朋友圈或 Instagram 的质感短句。
3. 诗意/探索风 (Poetic & Mindful)
线索：大自然、徒步、日落、建筑细节、空无一人的街道、极简冷色调、深夜独自一人。
语气：略显克制，富有哲理或空间感，平静地表达与内心或世界的对话。
4. 标准/轻快风 (Casual Daily)
线索：不符合上述特殊场景的普通生活抓拍，如路边随手拍、超市购物、交通工具。
语气：自然、爽朗，母语者日常闲聊。
以上是判断线索，结合整体氛围择一，不仅凭一个物件套用；无论何种风格，词汇、语法及句长都不能超出当前难度。`

  if (generationFormat === "dual_tabs_v1") {
    return `
${roleAndDifficultyPrompt}

${adaptiveStylePrompt}

# Rules
image_descriptions（维度一：客观世界，描述照片中有什么）：生成 3 句话。
${objectiveRules}

scene_and_feelings（维度二：主观心声，场景下可能说什么）：生成 3 句话。
扮演感性、懂用户的朋友，按选定风格推测拍摄时的心理状态，写出用户当时最可能说的日常口语或内心独白；必须严格符合当前难度。三句角度不同，不换词重复，不必固定为感受、对话和事件各一句。
允许基于画面推测最可能的场景、关系和感受，但不编造无依据的具体姓名、地点、时间、经历或事实。可以写假设口语，不能声称对话已发生，不输出双方对话或 I would say 开头。仅画面明确涉及拍照才考虑请人拍照。
截图、界面、图表、股票、网页、文档等信息图只作描述或场景心声，不分析数据或涨跌、不逐项抄写文字。不要输出风格名称、判断过程或其他分析。

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
${roleAndDifficultyPrompt}

# Rules
sentences（客观世界，描述照片中有什么）：仅生成 3 句话。
${objectiveRules}
截图、界面、图表、股票、网页、文档等信息图也只描述最直接可见的内容，不分析涨跌、不总结数据、不逐项抄写文字。不生成主观心声或风格判断。

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
