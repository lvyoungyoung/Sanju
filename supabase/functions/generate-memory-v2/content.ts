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

export type ProviderName = "mimo" | "kimi"

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
      ? "启蒙难度：面向儿童和零基础英语学习者。每句使用 3 到 6 个英文单词，优先 3 到 5 个；用完整、自然的超短句，不要用碎片短语凑句。每句只表达一个意思：一个事物、动作或简单感受，不叠加背景和修饰细节。只用极常见的具体词和简单感受词，例如 cat、dog、red、big、eat、run、happy。优先使用简单的主谓、主谓宾或 be 动词句，主要用一般现在时；表达照片中的事件时可以说正在做什么，不必交代过去的经过。不要使用从句、抽象词、习语、俚语、比喻、拟人、双关、复杂时态或文学表达。中文翻译也要短、直接、适合儿童理解。"
      : englishLevel === "简单"
      ? "初级难度：面向已经认识基础单词、正在学习完整表达的初学者。每句尽量控制在 6 到 10 个英文单词之间。只用高频日常词、常见动作词和简单感受词；围绕一个核心意思，增加一个清楚的细节，例如地点、颜色、方式或时间。每句只用一个简单分句，可以使用一般现在时、现在进行时、常见动词的一般过去时，以及简单疑问句、祈使句或 can。不要使用从句、完成时、被动语态、分词修饰结构、抽象书面词、生僻习语、比喻或拟人。与启蒙相比增加有用的具体细节，不靠难词或复杂语法提高难度。"
      : englishLevel === "高级"
        ? "请使用更丰富、更自然、更有层次感的英语表达，默认面向英语水平较高的学习者。每句尽量控制在 14 到 24 个单词之间，可以使用更细腻的词汇、更加完整的句子结构，以及适度的修辞和节奏变化，但仍要保持自然、准确、可理解，不要写得像诗歌或过度炫技。"
        : "中级难度：面向能理解简单句、希望表达更完整和具体的学习者。每句尽量控制在 10 到 16 个英文单词之间。使用常见但更准确的动作词、感受词和自然日常搭配；围绕一个核心意思，补充一到两个有用的细节，或说清原因、时间、对比等一种关系。可以用 because、when、that 等引导一个简短从句，或使用简单并列结构，但不要求每句都带从句，不嵌套多层从句。与初级相比增加信息层次和表达准确度，而不是只加形容词拉长句子。不要堆砌复杂语法、生僻词、抽象书面词或文学修辞，仍然要像日常会说的话。"

  const difficultyPriorityPrompt = englishLevel === "高级" ? "" :
    "以上难度的词汇、句式和句长要求适用于每一组、每一句，优先于语言风格、幽默和表达层次要求。不要为了凑字数添加空洞修饰，也不要为缩短句子省略必要成分；如果信息太多，减少信息量，保留自然、完整的表达。"

  const languageStylePrompt =
    englishLevel === "启蒙"
      ? "语言风格固定为平铺直叙：友好、自然、直接，不使用抒情优雅风格。即使请求传入抒情风格，也必须遵守启蒙短句和词汇限制。"
      : languageStyle === "抒情优美"
      ? "整体风格请明显更细腻、更有画面感、更有情绪和节奏。可以适度使用温柔、优美、富有氛围感的词语，让句子读起来更柔和、更有美感，但仍然要自然、准确、易懂。允许轻微的抒情和意境表达，但不要写成诗歌，不要过度夸张，不要脱离图片内容。"
      : "整体风格请生动、活泼、自然，像人看到眼前画面时会脱口而出的日常英语。优先使用具体而有动作感的动词、自然的口语化搭配和有节奏感的表达。允许加入轻微的幽默、俏皮观察或令人会心一笑的措辞，让句子更有记忆点，但幽默必须来自画面中真实可见的对比、动作或细节。不要写段子、网络梗、夸张笑话或生硬的拟人化；不要虚构图片中没有的动作、对话、情绪或细节。"

  if (generationFormat === "dual_tabs_v1") {
    return `
请根据这张图片，为语言学习生成两组英文句子，并为每句提供对应的中文翻译。
${englishLevelPrompt}
${languageStylePrompt}
${difficultyPriorityPrompt}

第一组 image_descriptions 必须是三句客观的画面描述：只说图片中直接可见的人、物、动作、环境或文字，不推测人物关系、事件背景和内心感受。
第二组 scene_and_feelings 必须是用户面对这张照片时最可能会脱口而出的三句自然英语。它不是第二组画面描述，而是帮助用户把自己的生活说出来。大胆根据画面推测最可能发生的场景、人物关系或感受；不需要反复说明这是推测，但不得编造图片无法支持的具体姓名、地点、时间、经历或事实。第二句不受前面“不要虚构对话”的限制：它是基于画面的假设性口语示例，不能把假设的对话写成真实发生过的事实。
第二组的三句必须按以下顺序各写一句，三句表达的角度必须明显不同：
1. 我当时的感受：自然说出看到或经历这个画面时的情绪、反应或氛围。
2. 当时会对别人说什么：假设用户正处在照片里的场景中，写一句最自然、最贴合眼前情境、可以直接对别人说的英语。可以分享发现、提出建议、邀请、提问、请求、提醒或回应，不必总是问句或请求。句子要围绕画面中的具体对象或正在进行的活动，不要只写通用寒暄，也不要再写一遍自己的感受或事后的照片配文。不要因为输入是一张照片就默认请求别人帮忙拍照；只有画面本身明确涉及拍照活动时才考虑这种表达。直接输出用户会说的那一句，不要输出双方对话，不加说话人标签或额外引号，不要使用 I would say 等解释性开头；中文也直接翻译这句口语。
3. 发生了什么：用第一人称或第一人称复数，说一个最可能发生的日常场景或动作。
第一句和第三句优先使用 I 或 we，第二句可自然使用 you、we、祈使句或疑问句，不强制第一人称。像人会对朋友说、发照片时会配的日常英语。不要写成客观的物体清单，不要让三句只是同义改写，也不要使用空泛、放之四海皆准的鸡汤。
${englishLevel === "高级" ? '高级的场景表达仍以日常口语为准，每句尽量控制在 8 到 18 个英文单词之间。只能使用更地道的日常搭配、更准确的情绪词和自然的表达节奏，不要使用复杂从句、书面词、文学化修辞或刻意高级的词汇。' : '场景表达与画面描述遵守同一档难度，不另行提高句长或语法要求。用所选难度能说出的自然口语表达感受、对话和事件，内容必须贴合当前照片；口语感不能成为忽略难度限制的理由。'}
- 即使语言风格为“抒情优美”，也只能让语气更温暖、有画面感或更真诚；不能写成诗歌、散文、文艺配文或不符合日常对话的优雅腔调。
- 生活表达的标准是：一位英语母语者会自然地对朋友说、发在社交平台上，或在回想照片时脱口而出的句子。
如果图片是手机截图、应用界面、图表、股票页面、数据面板、网页、文档或任何带有大量文字/数字的信息界面，第二组也应围绕用户看到、记录或分享这个信息时可能说的话，不做数据分析或涨跌解读。

${buildSentenceMetadataRules()}
分类和表达用途仅依据该句本身，不借用其他句子的背景；句子难度限制适用于 english 字段。

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
请根据这张图片，生成三句适合英语学习的英文描述，并为每句提供对应的中文翻译。
如果图片是手机截图、应用界面、图表、股票页面、数据面板、网页、文档或任何带有大量文字/数字的信息界面，你也只能输出三句简洁描述，不要做分析报告，不要解释涨跌原因，不要总结数据，不要逐项抄写图片里的文字。
描述必须围绕图片中最明显、最直接可见的内容，用自然、可学习、可模仿的英语表达。
${englishLevelPrompt}
${languageStylePrompt}
${difficultyPriorityPrompt}

${buildSentenceMetadataRules()}
分类和表达用途仅依据该句本身，不借用其他句子的背景；句子难度限制适用于 english 字段。

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
