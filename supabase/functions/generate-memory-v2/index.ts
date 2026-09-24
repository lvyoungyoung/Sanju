import { createClient } from "npm:@supabase/supabase-js@2"
import { fetchWithTimeout, fetchWithinDeadline } from "../_shared/fetch-with-timeout.ts"

interface Sentence {
  english: string
  chinese: string
  learning_topic_ids: string[]
  expression_purpose?: string
  presentation_group?: SentencePresentationGroup
}

type SentencePresentationGroup = "what_i_see" | "what_i_say"
type GenerationFormat = "legacy_v1" | "dual_tabs_v1"

type FinalizedSentence = Sentence & {
  id: string
  is_favorite: boolean
}

interface GeneratedContent {
  sentences: Sentence[]
  tags: string[]
}

type ProviderName = "mimo" | "kimi"

const MEMORY_TAGS = [
  "人物",
  "风景",
  "旅行",
  "美食",
  "生活场景",
  "动物",
  "植物",
  "建筑",
  "活动",
  "物品",
  "截图/信息",
] as const

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
const LEARNING_TOPIC_PROMPT = LEARNING_TOPICS.map(([id, title]) => `${id}（${title}）`).join("、")
const EXPRESSION_PURPOSE_PROMPT = "expression_purpose：为每句写一条简短的英文表达用途，说明用户可以用这句话表达什么，最多 30 个英文单词且不超过 240 个字符。依据句子本身，不是照片整体，不得加入原句没有表达的人物、关系、背景、感受或场景。保留关键对象、动作、感受及限制；不要只写宽泛分类，不要简单重复或翻译原句，不要罗列多个猜测用途。例如 The lake reflected the snow-covered mountains. 的用途是 Describing a lake reflecting snow-covered mountains.；We enjoyed a delicious meal by the lake. 的用途是 Sharing an enjoyable meal beside a lake.，不是描述山水风景。每句必须返回非空的 expression_purpose 字符串。"
const LEARNING_TOPIC_CLASSIFICATION_GUIDANCE = [
  "self_and_style：自拍、个人形象、衣着、发型或配饰；只是出现人物不等于这个场景",
  "family_time：家人相伴、家庭合影、陪伴父母；重点是孩子成长选 children_growing_up",
  "children_growing_up：孩子玩耍、成长里程碑、亲子活动；学校课程本身选 school_and_study",
  "friends_gatherings：朋友见面、相伴、普通聚餐或一起活动；明确庆生过节选 festivals_and_celebrations",
  "romance_and_companionship：约会、情侣相处、恋爱或亲密陪伴；不要仅凭照片中有两个人臆造情侣关系",
  "pet_life：宠物睡觉、玩耍、喂养或遛宠物；野生或动物园动物选 plants_and_wildlife",
  "food_and_drinks：菜品、饮料、咖啡、甜品的外观、味道、口感或吃喝体验；制作过程选 cooking",
  "cooking：备菜、烹调、烘焙及制作过程；只描述成品味道选 food_and_drinks",
  "home_life：房间、家具、家居布置、搬家、家务或居家日常；强调家人互动选 family_time",
  "city_life：街道、建筑、商店外观或城市夜景；购买行为选 shopping",
  "natural_scenery：山川、湖海、日落、天气、季节、雪景等自然环境；具体花草动物选 plants_and_wildlife",
  "plants_and_wildlife：鲜花、树木、鸟、野生动物或动物园；宠物相处选 pet_life",
  "travel：旅行经历、景点游览、酒店住宿、当地见闻；交通过程选 transport，不因旅游照片就把所有句子归旅行",
  "transport：机场、车站、乘车、通勤、自驾或旅途中的交通过程",
  "sports_and_outdoors：健身、跑步、骑行、徒步、露营或其他户外活动；单纯描写山景选 natural_scenery",
  "festivals_and_celebrations：生日、婚礼、过节、纪念日庆祝或毕业庆典；普通朋友见面选 friends_gatherings",
  "arts_and_entertainment：演出、展览、电影、游乐园、阅读、音乐、游戏或其他文化娱乐活动",
  "school_and_study：课堂、校园、书本、课程、作业或学习过程；毕业庆祝选 festivals_and_celebrations",
  "work_life：工位、同事、会议、任务或工作成果；只描述室内布置不能据此臆造工作场景",
  "shopping：买东西、挑选商品、试穿、价格、购买体验或新购物品；单纯描述穿着选 self_and_style",
  "health_and_wellness：身体状况、医院、体检、康复、休息或健康照护；锻炼动作选 sports_and_outdoors",
].join("；")

function buildPromptText(
  englishLevel: "启蒙" | "简单" | "中等" | "高级",
  languageStyle: "平铺直叙" | "抒情优美",
  generationFormat: GenerationFormat
): string {
  const englishLevelPrompt =
    englishLevel === "启蒙"
      ? "启蒙难度：面向儿童和零基础英语学习者。两组中的每一句都使用 3 到 6 个英文单词，优先 3 到 5 个；用完整、自然的超短句，不要用碎片短语凑句。每句只表达一个意思，只用极常见、具体的词，例如 cat、dog、red、big、eat、run、happy。优先使用 This is a cat.、I like this cake.、We are happy. 这样的简单句型，主要用一般现在时和简单的 be 动词句。不要使用从句、抽象词、习语、俚语、比喻、拟人、双关、复杂时态或文学表达，不为幽默或风格牺牲易懂程度。中文翻译也要短、直接、适合儿童理解。这些难度限制高于下面的风格、生活表达范例和表达层次要求，适用于每一组句子。"
      : englishLevel === "简单"
      ? "请使用非常简单、非常常见的英语词汇和句式，默认面向英语初学者。每句尽量控制在 6 到 12 个单词之间，优先使用小学到初中阶段常见词，不要使用抽象词、书面词、复杂从句、比喻、拟人、现在分词作状语、过去分词作定语等复杂结构。尽量多用简单主谓宾句型，例如 This is..., There is..., A girl is..., The cat is...。"
      : englishLevel === "高级"
        ? "请使用更丰富、更自然、更有层次感的英语表达，默认面向英语水平较高的学习者。每句尽量控制在 14 到 24 个单词之间，可以使用更细腻的词汇、更加完整的句子结构，以及适度的修辞和节奏变化，但仍要保持自然、准确、可理解，不要写得像诗歌或过度炫技。"
        : "请使用自然、日常、适合中等英语水平学习者的表达。每句尽量控制在 10 到 18 个单词之间，可以使用常见但稍丰富一些的日常表达，允许适度使用定语、状语和更完整的句子结构，但不要过于书面或艰深。"

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

第一组 image_descriptions 必须是三句客观的画面描述：只说图片中直接可见的人、物、动作、环境或文字，不推测人物关系、事件背景和内心感受。
第二组 scene_and_feelings 必须是用户面对这张照片时最可能会脱口而出的三句自然英语。它不是第二组画面描述，而是帮助用户把自己的生活说出来。大胆根据画面推测最可能发生的场景、人物关系或感受；不需要反复说明这是推测，但不得编造图片无法支持的具体姓名、地点、时间、经历或事实。第二句不受前面“不要虚构对话”的限制：它是基于画面的假设性口语示例，不能把假设的对话写成真实发生过的事实。
第二组的三句必须按以下顺序各写一句，三句表达的角度必须明显不同：
1. 我当时的感受：自然说出看到或经历这个画面时的情绪、反应或氛围。
2. 当时会对别人说什么：假设用户正处在照片里的场景中，写一句最自然、最贴合眼前情境、可以直接对别人说的英语。可以分享发现、提出建议、邀请、提问、请求、提醒或回应，不必总是问句或请求。句子要围绕画面中的具体对象或正在进行的活动，不要只写通用寒暄，也不要再写一遍自己的感受或事后的照片配文。不要因为输入是一张照片就默认请求别人帮忙拍照；只有画面本身明确涉及拍照活动时才考虑这种表达。直接输出用户会说的那一句，不要输出双方对话，不加说话人标签或额外引号，不要使用 I would say 等解释性开头；中文也直接翻译这句口语。
3. 发生了什么：用第一人称或第一人称复数，说一个最可能发生的日常场景或动作。
第一句和第三句优先使用 I 或 we，第二句可自然使用 you、we、祈使句或疑问句，不强制第一人称。像人会对朋友说、发照片时会配的日常英语。不要写成客观的物体清单，不要让三句只是同义改写，也不要使用空泛、放之四海皆准的鸡汤。
${englishLevel === "启蒙" ? '启蒙的生活表达也必须使用 3 到 6 个单词的超短句，每句只表达一个意思，使用极常见的具体词和简单句型，内容必须贴合当前照片。启蒙词汇和句长限制优先于表达层次和风格。' : '生活表达的“日常口语感”优先级高于用户选择的英语级别和语言风格：'}
- 即使英语级别为“高级”，也只能使用更地道的日常搭配、更准确的情绪词和自然的表达节奏；不要使用复杂从句、书面词、文学化修辞或刻意高级的词汇。每句尽量控制在 8 到 18 个英文单词之间。
- 即使语言风格为“抒情优美”，也只能让语气更温暖、有画面感或更真诚；不能写成诗歌、散文、文艺配文或不符合日常对话的优雅腔调。
- 生活表达的标准是：一位英语母语者会自然地对朋友说、发在社交平台上，或在回想照片时脱口而出的句子。
如果图片是手机截图、应用界面、图表、股票页面、数据面板、网页、文档或任何带有大量文字/数字的信息界面，第二组也应围绕用户看到、记录或分享这个信息时可能说的话，不做数据分析或涨跌解读。

你必须严格遵守以下输出规则：
1. 回复必须是一个 JSON 对象，不能是字符串、markdown 或代码块
2. 顶层字段必须且只能是 image_descriptions、scene_and_feelings 和 tags
3. image_descriptions 和 scene_and_feelings 都必须恰好有 3 项
4. 每一项必须且只能包含 english、chinese、learning_topic_ids 和 expression_purpose 四个字段
5. 每句中文控制在 ${englishLevel === "启蒙" ? "3 到 15" : "8 到 30"} 个汉字之间
6. learning_topic_ids 是句子的分类，不是照片的分类。每句选择 1–2 个不重复的生活场景 ID，只能来自：${LEARNING_TOPIC_PROMPT}。第一个必须是最匹配的主场景；只有句子本身明确涉及另一个独立场景时才添加第二个，否则只返回一个，不强行凑数。不要自创 ID，不要因为图片整体内容而机械地给所有句子相同分类。分类边界用于优先确定主场景：${LEARNING_TOPIC_CLASSIFICATION_GUIDANCE}。例如同一张生日聚餐照，单纯描述蛋糕味道的句子只选 food_and_drinks，表达庆生的句子选 festivals_and_celebrations；“We went camping with our family.” 可选 ["sports_and_outdoors","family_time"]，但没有提到家人的露营句子不要添加 family_time。对于 scene_and_feelings，也以该句实际表达的活动或关系为准；照片只能辅助消除歧义，不能用照片中未在句子表达的细节强行归类。没有合适场景的句子（如仅记录票据、证件、备忘截图或无场景指向的感叹）返回空数组 []；不要新增“实用记录”分类。每句最多 2 个分类
7. tags 必须是长度为 1 到 3 的数组，只能从以下分类中选择且不可重复：人物、风景、旅行、美食、生活场景、动物、植物、建筑、活动、物品、截图/信息
8. 不要输出任何多余字段或 JSON 前后的任何字符
9. ${EXPRESSION_PURPOSE_PROMPT}

严格按照下面的格式返回：
{"image_descriptions":[{"english":"...","chinese":"...","learning_topic_ids":["self_and_style"],"expression_purpose":"..."},{"english":"...","chinese":"...","learning_topic_ids":["natural_scenery"],"expression_purpose":"..."},{"english":"...","chinese":"...","learning_topic_ids":["home_life"],"expression_purpose":"..."}],"scene_and_feelings":[{"english":"...","chinese":"...","learning_topic_ids":["festivals_and_celebrations"],"expression_purpose":"..."},{"english":"...","chinese":"...","learning_topic_ids":["sports_and_outdoors","family_time"],"expression_purpose":"..."},{"english":"...","chinese":"...","learning_topic_ids":[],"expression_purpose":"..."}],"tags":["人物","生活场景"]}
`.trim()
  }

  return `
请根据这张图片，生成三句适合英语学习的英文描述，并为每句提供对应的中文翻译。
如果图片是手机截图、应用界面、图表、股票页面、数据面板、网页、文档或任何带有大量文字/数字的信息界面，你也只能输出三句简洁描述，不要做分析报告，不要解释涨跌原因，不要总结数据，不要逐项抄写图片里的文字。
描述必须围绕图片中最明显、最直接可见的内容，用自然、可学习、可模仿的英语表达。
${englishLevelPrompt}
${languageStylePrompt}

你必须严格遵守以下输出规则：
1. 你的回复必须是一个 JSON 对象
2. 不要把 JSON 放在字符串里
3. 不要返回 markdown
4. 不要使用 \`\`\` 或 \`\`\`json 代码块
5. 不要写任何解释、前言、结尾、备注
6. 顶层字段必须且只能是 sentences 和 tags
7. sentences 必须是长度为 3 的数组
8. 每一项必须且只能包含 english、chinese、learning_topic_ids 和 expression_purpose 四个字段，必须显式写出 chinese 字段名，不能只写中文字符串
9. english、chinese 必须是字符串；learning_topic_ids 必须是数组
10. tags 必须是长度为 1 到 3 的数组，只能从以下分类中选择：人物、风景、旅行、美食、生活场景、动物、植物、建筑、活动、物品、截图/信息
11. tags 中不要重复分类，不要自创分类
12. 不要输出任何多余字段
13. 不要转义整个 JSON 对象
14. 不要在 JSON 前后添加任何字符
15. learning_topic_ids 按每个句子实际表达的重点选择 1–2 个不重复的生活场景 ID，只能来自：${LEARNING_TOPIC_PROMPT}。第一个是最匹配的主场景；只有句子本身明确涉及另一个独立场景时才添加第二个，否则只返回一个，不强行凑数。分类对象是句子，不是照片；同一张照片可以生成不同分类的句子。例如生日聚餐照中，单纯描述蛋糕味道只选 food_and_drinks，表达庆生选 festivals_and_celebrations；“A family is camping by the lake.” 可选 ["sports_and_outdoors","family_time"]，但不要仅因背景里有湖就再加 natural_scenery。分类边界用于优先确定主场景：${LEARNING_TOPIC_CLASSIFICATION_GUIDANCE}。无合适场景的句子（如仅记录票据、证件、备忘截图）返回 []，不要强行分类，不要自创“实用记录”等 ID。每句最多 2 个分类。
16. 每句中文控制在 ${englishLevel === "启蒙" ? "3 到 15" : "8 到 30"} 个汉字之间
17. 如果图片里有文字或数字，可以适度提到 "a screen"、"a chart"、"some numbers" 这类概括性表达，但不要逐字抄录内容
18. ${EXPRESSION_PURPOSE_PROMPT}

你必须严格按照下面这个格式返回：
{"sentences":[{"english":"...","chinese":"...","learning_topic_ids":["pet_life"],"expression_purpose":"..."},{"english":"...","chinese":"...","learning_topic_ids":["home_life"],"expression_purpose":"..."},{"english":"...","chinese":"...","learning_topic_ids":["sports_and_outdoors","family_time"],"expression_purpose":"..."}],"tags":["动物","生活场景"]}
`.trim()
}

function serializeGenerationError(args: {
  provider?: ProviderName
  code?: string
  statusCode?: number
  internalError: string
}) {
  return JSON.stringify({
    provider: args.provider ?? null,
    code: args.code ?? null,
    statusCode: args.statusCode ?? null,
    internalError: args.internalError,
    at: new Date().toISOString(),
  })
}

function summarizeProviderFailure(args: {
  code?: string
  statusCode: number
  rateLimited?: boolean
  internalError: string
}): string {
  const parts = [
    args.code ? `code=${args.code}` : null,
    `status=${args.statusCode}`,
    args.rateLimited ? "rate_limited=true" : null,
    args.internalError,
  ].filter((part): part is string => Boolean(part))

  return truncateDiagnosticText(parts.join(" | "))
}

function truncateDiagnosticText(value: string, maxLength = 500): string {
  const normalized = value.replace(/\s+/g, " ").trim()
  return normalized.length > maxLength
    ? `${normalized.slice(0, maxLength - 1)}…`
    : normalized
}

function appendDiagnosticSnippet(
  message: string,
  label: string,
  value: unknown,
  maxLength = 300
): string {
  const snippet = makeDiagnosticSnippet(value, maxLength)
  return snippet ? `${message}; ${label}=${snippet}` : message
}

function makeDiagnosticSnippet(value: unknown, maxLength = 300): string {
  let text: string

  if (typeof value === "string") {
    text = value
  } else {
    try {
      text = JSON.stringify(value)
    } catch {
      text = String(value)
    }
  }

  return truncateDiagnosticText(text, maxLength)
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

function parseGeneratedContent(
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
      tags: parseMemoryTagsFromPayload(payload),
    }
  }

  const sentences = parseSentences(content)
  if (!sentences) {
    return null
  }

  return {
    sentences,
    tags: parseMemoryTags(content),
  }
}

function parseMemoryTags(content: string): string[] {
  return parseMemoryTagsFromPayload(parseJSONObject(content))
}

function parseMemoryTagsFromPayload(payload: any): string[] {
  const rawTags = Array.isArray(payload?.tags) ? payload.tags : []
  const validTags = new Set<string>(MEMORY_TAGS)
  const tags: string[] = []

  for (const rawTag of rawTags) {
    const tag = String(rawTag ?? "").trim()
    if (validTags.has(tag) && !tags.includes(tag)) {
      tags.push(tag)
    }
    if (tags.length == 3) {
      break
    }
  }

  return tags
}

function parseJSONObject(content: string): any | null {
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
      expression_purpose: normalizeExpressionPurpose(item?.expression_purpose),
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

function decodeBase64(base64: string): Uint8Array {
  const binary = atob(base64)
  const bytes = new Uint8Array(binary.length)
  for (let index = 0; index < binary.length; index += 1) {
    bytes[index] = binary.charCodeAt(index)
  }
  return bytes
}

function jsonResponse(data: unknown, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      "Content-Type": "application/json; charset=utf-8",
    },
  })
}

function normalizeOptionalUUID(value: unknown): string | undefined {
  if (typeof value !== "string") {
    return undefined
  }

  const trimmed = value.trim().toLowerCase()
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(trimmed)
    ? trimmed
    : undefined
}



interface RequestBody {
  imageBase64: string
  englishLevel?: "启蒙" | "简单" | "中等" | "高级"
  languageStyle?: "平铺直叙" | "抒情优美"
  guestJobID?: string
  clientRequestID?: string
  generationFormat?: string
}

const MIMO_TIMEOUT_MS = 20000
const KIMI_TIMEOUT_MS = 20000
const GENERATION_CONCURRENCY_LIMIT = 50
const GENERATION_SLOT_TTL_SECONDS = 180
const GENERATION_VIOLATION_WINDOW_SECONDS = 24 * 60 * 60
const GENERATION_VIOLATION_LIMIT = 20
const GENERATION_VIOLATION_BAN_SECONDS = 24 * 60 * 60
const IMAGE_MODERATION_FUNCTION_TIMEOUT_MS = 10000
const GENERATION_REQUEST_BUDGET_MS = 90000

Deno.serve(async (req) => {
  let adminClient: any = null
  let generationSlotRequestID: string | null = null
  let generationSlotAcquired = false
  let authenticatedClientRequestID: string | null = null
  let ownedGuestJobID: string | null = null
  let generationUserID: string | null = null
  let ownsAuthenticatedJob = false
  let finalizationStarted = false
  let cleanupClient: any = null
  const generationDeadline = Date.now() + GENERATION_REQUEST_BUDGET_MS
  const generationFetch = fetchWithinDeadline(generationDeadline)

  try {
    if (req.method !== "POST") {
      return jsonResponse({ error: "Method Not Allowed" }, 405)
    }

    const mimoApiKey = Deno.env.get("MIMO_API_KEY")
    const mimoBaseURL = Deno.env.get("MIMO_BASE_URL")
    const kimiApiKey = Deno.env.get("KIMI_API_KEY")
    const kimiBaseURL = Deno.env.get("KIMI_BASE_URL")
    // Use the project-local gateway inside Edge Runtime. Public URL loopback
    // can time out after infrastructure upgrades even while client traffic works.
    const supabaseUrl = Deno.env.get("SUPABASE_LOCAL_URL") ?? Deno.env.get("SUPABASE_URL")
    const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY")
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")

    if (
      !mimoApiKey ||
      !mimoBaseURL ||
      !kimiApiKey ||
      !kimiBaseURL ||
      !supabaseUrl ||
      !supabaseAnonKey ||
      !serviceRoleKey
    ) {
      return jsonResponse({ error: "Missing server configuration" }, 500)
    }

    const authHeader = req.headers.get("Authorization")
    if (!authHeader?.startsWith("Bearer ")) {
      return jsonResponse({ error: "Missing Authorization header" }, 401)
    }

    const accessToken = authHeader.replace("Bearer ", "").trim()

    const userClient = createClient(supabaseUrl, supabaseAnonKey, { global: { fetch: generationFetch } })
    adminClient = createClient(supabaseUrl, serviceRoleKey, { global: { fetch: generationFetch } })
    cleanupClient = createClient(supabaseUrl, serviceRoleKey, {
      global: { fetch: (input, init) => fetchWithTimeout(input, init, 5000) },
    })

    const {
      data: { user },
      error: userError,
    } = await userClient.auth.getUser(accessToken)

    if (userError || !user) {
      if (Date.now() >= generationDeadline) return generationPendingResponse(true)
      return jsonResponse(
        {
          error: "Invalid JWT",
          details: userError?.message ?? null,
        },
        401
      )
    }

    generationUserID = user.id
    const { data: profile, error: profileError } = await adminClient
      .from("profiles")
      .select("available_generations, generation_banned_until")
      .eq("id", user.id)
      .single()

    if (profileError || !profile) {
      if (Date.now() >= generationDeadline) return generationPendingResponse(true)
      return jsonResponse({ error: "Profile not found" }, 404)
    }

    const body = (await req.json()) as RequestBody
    const imageBase64 = body.imageBase64?.replace(/\s+/g, "").trim()

    if (!imageBase64) {
      return jsonResponse({ error: "imageBase64 is required" }, 400)
    }

    const imageBytes = decodeBase64(imageBase64)
    const englishLevel = body.englishLevel ?? "中等"
    const languageStyle = body.languageStyle ?? "平铺直叙"
    const generationFormat: GenerationFormat = body.generationFormat === "dual_tabs_v1"
      ? "dual_tabs_v1"
      : "legacy_v1"
    const isAnonymous = user.is_anonymous === true
    const guestJobID = isAnonymous ? body.guestJobID?.trim() : undefined
    authenticatedClientRequestID = isAnonymous
      ? null
      : normalizeOptionalUUID(body.clientRequestID) ?? null

    if (isAnonymous && !guestJobID) {
      return jsonResponse({ error: "guestJobID is required for anonymous users" }, 400)
    }

    const createdAt = new Date().toISOString()
    let existingGuestJob: { id: string; status: string; provider?: string | null } | null = null

    if (!isAnonymous && authenticatedClientRequestID) {
      const completedResponse = await loadCompletedAuthenticatedGenerationResponseIfNeeded(
        adminClient,
        {
          clientRequestID: authenticatedClientRequestID,
          userID: user.id,
          fallbackRemainingCredits: profile.available_generations,
          generationFormat,
        }
      )

      if (completedResponse) {
        return completedResponse
      }
    }

    if (isAnonymous) {
      const { data: loadedGuestJob, error: existingGuestJobError } = await adminClient
        .from("guest_generation_jobs")
        .select("id, status, provider")
        .eq("id", guestJobID)
        .eq("user_id", user.id)
        .maybeSingle()

      if (existingGuestJobError) {
        return jsonResponse(
          {
            error: "Failed to load guest generation job",
            details: existingGuestJobError.message,
          },
          500
        )
      }

      existingGuestJob = loadedGuestJob

      if (
        existingGuestJob?.status === "completed" ||
        existingGuestJob?.status === "acknowledged"
      ) {
        const completedResponse = await loadCompletedGuestGenerationResponseIfNeeded(
          adminClient,
          {
            guestJobID: guestJobID!,
            userID: user.id,
            fallbackCreatedAt: createdAt,
            fallbackRemainingCredits: profile.available_generations,
            generationFormat,
          }
        )

        if (completedResponse) {
          return completedResponse
        }
      }

      if (existingGuestJob?.status === "pending") {
        return jsonResponse(
          {
            error: "生成仍在处理中，请稍后查看回忆。",
            code: "generation_in_progress",
            provider: "generation_job",
          },
          409
        )
      }

      if (existingGuestJob?.status === "failed") {
        return jsonResponse(
          {
            error: "生成失败，请重新生成。",
            code: "generation_failed",
            provider: "generation_job",
          },
          500
        )
      }
    }

    if ((profile.available_generations ?? 0) <= 0) {
      return jsonResponse({ error: "No credits left" }, 403)
    }

    if (isGenerationViolationBanEnabled() && isFutureTimestamp(profile.generation_banned_until)) {
      return jsonResponse(
        {
          error: "当前账号暂时无法生成，请稍后再试。",
          code: "generation_banned",
          bannedUntil: profile.generation_banned_until,
        },
        403
      )
    }

    generationSlotRequestID = crypto.randomUUID()
    generationSlotAcquired = await tryAcquireGenerationSlot(adminClient, {
      requestID: generationSlotRequestID,
      userID: user.id,
    })

    if (!generationSlotAcquired) {
      return jsonResponse(
        {
          error: "当前使用人数过多，请稍后重试。",
          code: "rate_limited",
          provider: "concurrency_gate",
        },
        429
      )
    }

    const guestImagePath = isAnonymous ? `${user.id}/guest/${guestJobID}.jpg` : null
    let guestImageUploaded = false
    const requestID = isAnonymous ? guestJobID! : authenticatedClientRequestID
    if (requestID) {
      const { data: claim, error: claimError } = await adminClient.rpc("claim_generation_job", {
        p_user_id: user.id,
        p_request_id: requestID,
        p_is_anonymous: isAnonymous,
        p_image_path: guestImagePath,
      })
      if (claimError) throw new Error(`Generation claim failed: ${claimError.message}`)
      if (claim !== "acquired") {
        if (claim === "completed" || claim === "acknowledged") {
          const completed = isAnonymous
            ? await loadCompletedGuestGenerationResponseIfNeeded(adminClient, {
                guestJobID: requestID, userID: user.id, fallbackCreatedAt: createdAt,
                fallbackRemainingCredits: profile.available_generations, generationFormat,
              })
            : await loadCompletedAuthenticatedGenerationResponseIfNeeded(adminClient, {
                clientRequestID: requestID, userID: user.id,
                fallbackRemainingCredits: profile.available_generations, generationFormat,
              })
          return completed ?? generationPendingResponse()
        }
        if (claim === "pending") return generationPendingResponse()
        if (claim === "failed") return jsonResponse({ error: "生成失败，请重新生成。", code: "generation_failed" }, 500)
        throw new Error("Invalid generation claim response")
      }
      ownsAuthenticatedJob = !isAnonymous
      ownedGuestJobID = isAnonymous ? requestID : null
    }

    if (isAnonymous && guestImagePath) {
      const { error: uploadError } = await adminClient.storage
        .from("memories")
        .upload(guestImagePath, imageBytes, {
          contentType: "image/jpeg",
          upsert: false,
        })

      if (uploadError) {
        await markGuestGenerationJobFailed(cleanupClient, guestJobID!, user.id, `upload image failed: ${uploadError.message}`)

        return jsonResponse(
          {
            error: "upload image failed",
            details: uploadError.message,
          },
          500
        )
      }

      guestImageUploaded = true
    }

    const moderationResult = await moderateImageBeforeGeneration({
      userID: user.id,
      imageBase64,
      existingImagePath: isAnonymous ? guestImagePath : null,
      requestID: generationSlotRequestID,
      fetcher: generationFetch,
    })

    if (!moderationResult.allowed) {
      const serializedError = serializeGenerationError({
        code: moderationResult.code,
        statusCode: moderationResult.statusCode,
        internalError: moderationResult.internalError,
      })

      console.error("[generate-memory-v2]", serializedError)

      let violationRecord: GenerationViolationRecord | null = null
      if (isGenerationViolationBanEnabled() && moderationResult.countedViolation) {
        violationRecord = await recordGenerationViolation(adminClient, user.id)
      }

      if (guestJobID) {
        await markGuestGenerationJobFailed(cleanupClient, guestJobID!, user.id, serializedError)
      }

      if (guestImagePath) {
        await removeStoragePathQuietly(adminClient, guestImagePath)
      }

      if (authenticatedClientRequestID) {
        await markAuthenticatedGenerationJobFailed(
          cleanupClient,
          authenticatedClientRequestID,
          user.id,
          serializedError
        )
      }

      return jsonResponse(
        moderationResult.policyViolation
          ? buildGenerationPolicyViolationError(violationRecord)
          : moderationResult.publicError,
        moderationResult.statusCode
      )
    }

    const promptText = buildPromptText(englishLevel, languageStyle, generationFormat)

    const completionResult = await requestWithFallback({
      imageBase64,
      promptText,
      mimoBaseURL,
      mimoApiKey,
      kimiBaseURL,
      kimiApiKey,
      generationFormat,
      fetcher: generationFetch,
    })

    if (!completionResult.ok) {
      const serializedError = serializeGenerationError({
        provider: completionResult.provider,
        code: completionResult.code,
        statusCode: completionResult.statusCode,
        internalError: completionResult.internalError,
      })

      console.error("[generate-memory-v2]", serializedError)

      let violationRecord: GenerationViolationRecord | null = null
      if (isGenerationViolationBanEnabled() && completionResult.policyViolation) {
        violationRecord = await recordGenerationViolation(adminClient, user.id)
      }

      if (guestJobID) {
        await markGuestGenerationJobFailed(cleanupClient, guestJobID!, user.id, serializedError)
      }

      if (guestImageUploaded && guestImagePath) {
        await adminClient.storage.from("memories").remove([guestImagePath])
      }

      if (authenticatedClientRequestID) {
        await markAuthenticatedGenerationJobFailed(
          cleanupClient,
          authenticatedClientRequestID,
          user.id,
          serializedError
        )
      }

      if (completionResult.policyViolation) {
        return jsonResponse(buildGenerationPolicyViolationError(violationRecord), 403)
      }

      return jsonResponse(completionResult.publicError, completionResult.statusCode)
    }

    const { sentences, tags, provider, mimoFailureReason } = completionResult
    const finalizedSentences: FinalizedSentence[] = sentences.map((sentence) => ({
      id: crypto.randomUUID(),
      english: sentence.english,
      chinese: sentence.chinese,
      learning_topic_ids: sentence.learning_topic_ids,
      expression_purpose: sentence.expression_purpose,
      presentation_group: sentence.presentation_group ?? "what_i_see",
      is_favorite: false,
    }))

    if (isAnonymous) {
      finalizationStarted = true
      const finalizeResult = await finalizeGuestGeneration(adminClient, {
        guestJobID: guestJobID!,
        userID: user.id,
        createdAt,
        provider,
        sentences: finalizedSentences,
        tags,
      })

      if (!finalizeResult.ok) {
        if (finalizeResult.outcomeUnknown) return generationPendingResponse(true)
        const serializedError = serializeGenerationError({
          provider,
          code: finalizeResult.code,
          statusCode: finalizeResult.statusCode,
          internalError: finalizeResult.internalError,
        })

        console.error("[generate-memory-v2]", serializedError)

        await markGuestGenerationJobFailed(cleanupClient, guestJobID!, user.id, serializedError)

        if (guestImageUploaded && guestImagePath) {
          await adminClient.storage.from("memories").remove([guestImagePath])
        }

        return jsonResponse(finalizeResult.publicError, finalizeResult.statusCode)
      }

      await updateGuestGenerationDiagnostics(adminClient, {
        guestJobID: guestJobID!,
        provider,
        mimoFailureReason,
      })

      // Anonymous memories do not have memory_sentences rows until they are
      // copied into an account. Keep vectors by their stable sentence IDs now;
      // the database promotes them automatically when that copy is inserted.
      await stageGuestSentenceEmbeddings(adminClient, user.id, guestJobID!, finalizedSentences, generationFetch)

      return await loadCompletedGuestGenerationResponseIfNeeded(adminClient, {
        guestJobID: guestJobID!, userID: user.id, fallbackCreatedAt: createdAt,
        fallbackRemainingCredits: finalizeResult.remainingCredits, generationFormat,
      }) ?? generationPendingResponse(true)
    }

    const memoryID = crypto.randomUUID()
    const imagePath = `${user.id}/${crypto.randomUUID().toLowerCase()}.jpg`

    const { error: uploadError } = await adminClient.storage
      .from("memories")
      .upload(imagePath, imageBytes, {
        contentType: "image/jpeg",
        upsert: false,
      })

    if (uploadError) {
      if (authenticatedClientRequestID) {
        await markAuthenticatedGenerationJobFailed(
          cleanupClient,
          authenticatedClientRequestID,
          user.id,
          `upload image failed: ${uploadError.message}`
        )
      }

      return jsonResponse(
        {
          error: "upload image failed",
          details: uploadError.message,
        },
        500
      )
    }

    finalizationStarted = true
    const finalizeResult = await finalizeAuthenticatedGeneration(adminClient, {
      memoryID,
      userID: user.id,
      clientRequestID: authenticatedClientRequestID,
      imagePath,
      createdAt,
      provider,
      sentences: finalizedSentences,
      tags,
    })

    if (!finalizeResult.ok) {
      if (finalizeResult.outcomeUnknown) return generationPendingResponse(true)
      const serializedError = serializeGenerationError({
        provider,
        code: finalizeResult.code,
        statusCode: finalizeResult.statusCode,
        internalError: finalizeResult.internalError,
      })

      console.error("[generate-memory-v2]", serializedError)
      await adminClient.storage.from("memories").remove([imagePath])

      if (authenticatedClientRequestID) {
        await markAuthenticatedGenerationJobFailed(
          cleanupClient,
          authenticatedClientRequestID,
          user.id,
          serializedError
        )
      }

      return jsonResponse(finalizeResult.publicError, finalizeResult.statusCode)
    }

    await updateMemoryGenerationDiagnostics(adminClient, {
      memoryID,
      userID: user.id,
      provider,
      mimoFailureReason,
    })

    // Search indexing is intentionally best-effort. The atomic generation
    // transaction has already persisted the memory and deducted one credit.
    await indexGeneratedSentencesForStudyScenes(adminClient, user.id, finalizedSentences, generationFetch)

    if (authenticatedClientRequestID) {
      await updateAuthenticatedGenerationDiagnostics(adminClient, {
        clientRequestID: authenticatedClientRequestID,
        userID: user.id,
        memoryID,
        mimoFailureReason,
      })
      // The transaction owns the canonical memory ID and response, not this worker.
      return await loadCompletedAuthenticatedGenerationResponseIfNeeded(adminClient, {
        clientRequestID: authenticatedClientRequestID, userID: user.id,
        fallbackRemainingCredits: finalizeResult.remainingCredits, generationFormat,
      }) ?? generationPendingResponse(true)
    }

    return jsonResponse({
      memory: {
        id: memoryID,
        imagePath,
        createdAt,
        provider,
        tags,
        sentences: toClientSentences(finalizedSentences, generationFormat),
      },
      remainingCredits: finalizeResult.remainingCredits,
      clientRequestID: authenticatedClientRequestID,
    })
  } catch (error) {
    // A transport failure during finalization cannot prove that the DB rolled back.
    if (cleanupClient && generationUserID && !finalizationStarted) {
      const message = error instanceof Error ? error.message : String(error)
      if (ownsAuthenticatedJob && authenticatedClientRequestID) {
        await markAuthenticatedGenerationJobFailed(cleanupClient, authenticatedClientRequestID, generationUserID, message)
      }
      if (ownedGuestJobID) {
        await markGuestGenerationJobFailed(cleanupClient, ownedGuestJobID, generationUserID, message)
      }
    }

    console.error(
      "[generate-memory-v2]",
      JSON.stringify({
        provider: null,
        code: "unexpected_server_error",
        statusCode: 500,
        internalError: error instanceof Error ? error.message : String(error),
        at: new Date().toISOString(),
      })
    )

    if (finalizationStarted || isTimeoutError(error) || Date.now() >= generationDeadline) {
      return generationPendingResponse(true)
    }
    return jsonResponse({ error: "生成失败，请稍后再试" }, 500)
  } finally {
    if (generationSlotAcquired && generationSlotRequestID && adminClient) {
      try {
        await releaseGenerationSlot(cleanupClient ?? adminClient, generationSlotRequestID)
      } catch (error) {
        console.error(
          "[generate-memory-v2]",
          JSON.stringify({
            code: "generation_slot_release_failed",
            internalError: error instanceof Error ? error.message : String(error),
            requestID: generationSlotRequestID,
            at: new Date().toISOString(),
          })
        )
      }
    }
  }
})

async function requestWithFallback(args: {
  imageBase64: string
  promptText: string
  generationFormat: GenerationFormat
  mimoBaseURL: string
  mimoApiKey: string
  kimiBaseURL: string
  kimiApiKey: string
  fetcher: typeof fetch
}): Promise<
  | {
      ok: true
      sentences: Sentence[]
      tags: string[]
      provider: ProviderName
      mimoFailureReason: string | null
    }
  | {
      ok: false
      provider?: ProviderName
      code?: string
      policyViolation?: boolean
      statusCode: number
      internalError: string
      publicError: Record<string, unknown>
    }
> {
  const mimoRequestBody = {
    model: "mimo-v2.5",
    messages: [
      {
        role: "system",
        content: "You are MiMo, an AI assistant developed by Xiaomi.",
      },
      {
        role: "user",
        content: [
          {
            type: "image_url",
            image_url: {
              url: `data:image/jpeg;base64,${args.imageBase64}`,
            },
          },
          {
            type: "text",
            text: args.promptText,
          },
        ],
      },
    ],
    thinking: {
      type: "disabled",
    },
    max_completion_tokens: 4096,
  }

  const mimoResult = await requestMimoOnce(
    args.mimoBaseURL,
    args.mimoApiKey,
    mimoRequestBody,
    args.generationFormat,
    args.fetcher
  )

  if (mimoResult.ok) {
    return {
      ...mimoResult,
      mimoFailureReason: null,
    }
  }

  console.error(
    "[generate-memory-v2]",
    serializeGenerationError({
      provider: mimoResult.provider,
      code: mimoResult.code,
      statusCode: mimoResult.statusCode,
      internalError: `[MiMo fallback candidate] ${mimoResult.internalError}`,
    })
  )

  const shouldFallbackToKimi = mimoResult.fallbackable || mimoResult.rateLimited

  if (!shouldFallbackToKimi) {
    return {
      ok: false,
      provider: mimoResult.provider,
      code: mimoResult.code,
      policyViolation: mimoResult.policyViolation,
      statusCode: mimoResult.statusCode,
      internalError: `[MiMo] ${mimoResult.internalError}`,
      publicError: mimoResult.publicError,
    }
  }

  const kimiRequestBody = {
    model: "kimi-k2.5",
    messages: [
      {
        role: "system",
        content: "你是 Kimi，由 Moonshot AI 提供的人工智能助手，你更擅长中文和英文的对话。你会为用户提供安全、有帮助、准确的回答。",
      },
      {
        role: "user",
        content: [
          {
            type: "image_url",
            image_url: {
              url: `data:image/jpeg;base64,${args.imageBase64}`,
            },
          },
          {
            type: "text",
            text: args.promptText,
          },
        ],
      },
    ],
    thinking: {
      type: "disabled",
    },
  }

  const kimiResult = await requestKimiOnce(
    args.kimiBaseURL,
    args.kimiApiKey,
    kimiRequestBody,
    args.generationFormat,
    args.fetcher
  )

  if (kimiResult.ok) {
    return {
      ...kimiResult,
      mimoFailureReason: summarizeProviderFailure(mimoResult),
    }
  }

  console.error(
    "[generate-memory-v2]",
    serializeGenerationError({
      provider: kimiResult.provider,
      code: kimiResult.code,
      statusCode: kimiResult.statusCode,
      internalError: `[Kimi fallback failed] ${kimiResult.internalError}`,
    })
  )

  return {
    ok: false,
    provider: kimiResult.provider ?? mimoResult.provider,
    code: kimiResult.code,
    policyViolation: kimiResult.policyViolation,
    statusCode: kimiResult.statusCode,
    internalError: `[MiMo] ${mimoResult.internalError} | [Kimi] ${kimiResult.internalError}`,
    publicError: kimiResult.publicError,
  }
}

async function requestMimoOnce(
  mimoBaseURL: string,
  mimoApiKey: string,
  requestBody: unknown,
  generationFormat: GenerationFormat,
  fetcher: typeof fetch
): Promise<
  | { ok: true; sentences: Sentence[]; tags: string[]; provider: ProviderName }
  | {
      ok: false
      provider: ProviderName
      code?: string
      policyViolation?: boolean
      fallbackable: boolean
      rateLimited: boolean
      statusCode: number
      internalError: string
      publicError: Record<string, unknown>
    }
> {
  let response: Response

  try {
    response = await fetchWithTimeout(
      mimoBaseURL,
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "api-key": mimoApiKey,
        },
        body: JSON.stringify(requestBody),
      },
      MIMO_TIMEOUT_MS,
      fetcher
    )
  } catch (error) {
    const isTimeout = error instanceof DOMException && error.name === "AbortError"

    return {
      ok: false,
      provider: "mimo",
      fallbackable: true,
      rateLimited: false,
      statusCode: 500,
      internalError: isTimeout ? "MiMo request timeout" : `MiMo fetch failed: ${String(error)}`,
      publicError: {
        error: "生成失败，请稍后再试",
      },
    }
  }

  const rawText = await response.text()

  let data: any
  try {
    data = JSON.parse(rawText)
  } catch {
    data = null
  }

  if (!response.ok) {
    if (response.status === 429) {
      return {
        ok: false,
        provider: "mimo",
        code: "rate_limited",
        fallbackable: false,
        rateLimited: true,
        statusCode: 429,
        internalError: "MiMo rate limited",
        publicError: {
          error: "当前使用人数过多，请稍后重试。",
          code: "rate_limited",
          provider: "mimo",
        },
      }
    }

    return {
      ok: false,
      provider: "mimo",
      fallbackable: true,
      rateLimited: false,
      statusCode: response.status,
      internalError: appendDiagnosticSnippet(
        `MiMo request failed: HTTP ${response.status} ${response.statusText}`,
        "response_snippet",
        rawText
      ),
      publicError: {
        error: "生成失败，请稍后再试",
      },
    }
  }

  const content = data?.choices?.[0]?.message?.content

  if (!content || typeof content !== "string") {
    return {
      ok: false,
      provider: "mimo",
      fallbackable: true,
      rateLimited: false,
      statusCode: 500,
      internalError: appendDiagnosticSnippet(
        "Invalid MiMo response content",
        "response_snippet",
        rawText
      ),
      publicError: { error: "生成结果格式异常，请重试" },
    }
  }

  const generatedContent = parseGeneratedContent(content, generationFormat)
  if (!generatedContent) {
    return {
      ok: false,
      provider: "mimo",
      fallbackable: true,
      rateLimited: false,
      statusCode: 500,
      internalError: appendDiagnosticSnippet(
        "Failed to parse sentences",
        "content_snippet",
        content
      ),
      publicError: { error: "生成结果格式异常，请重试" },
    }
  }

  return {
    ok: true,
    sentences: generatedContent.sentences,
    tags: generatedContent.tags,
    provider: "mimo",
  }
}

async function requestKimiOnce(
  kimiBaseURL: string,
  kimiApiKey: string,
  requestBody: unknown,
  generationFormat: GenerationFormat,
  fetcher: typeof fetch
): Promise<
  | { ok: true; sentences: Sentence[]; tags: string[]; provider: ProviderName }
  | {
      ok: false
      provider: ProviderName
      code?: string
      policyViolation?: boolean
      rateLimited: boolean
      statusCode: number
      internalError: string
      publicError: Record<string, unknown>
    }
> {
  let response: Response

  try {
    response = await fetchWithTimeout(
      kimiBaseURL,
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${kimiApiKey}`,
        },
        body: JSON.stringify(requestBody),
      },
      KIMI_TIMEOUT_MS,
      fetcher
    )
  } catch (error) {
    const isTimeout = error instanceof DOMException && error.name === "AbortError"

    return {
      ok: false,
      provider: "kimi",
      rateLimited: false,
      statusCode: 500,
      internalError: isTimeout ? "Kimi request timeout" : `Kimi fetch failed: ${String(error)}`,
      publicError: {
        error: "生成失败，请稍后再试",
      },
    }
  }

  const rawText = await response.text()

  let data: any
  try {
    data = JSON.parse(rawText)
  } catch {
    data = null
  }

  if (!response.ok) {
    if (response.status === 429) {
      return {
        ok: false,
        provider: "kimi",
        code: "rate_limited",
        rateLimited: true,
        statusCode: 429,
        internalError: "Kimi rate limited",
        publicError: {
          error: "当前使用人数过多，请稍后重试。",
          code: "rate_limited",
          provider: "kimi",
        },
      }
    }

    return {
      ok: false,
      provider: "kimi",
      rateLimited: false,
      statusCode: response.status,
      internalError: "Kimi request failed",
      publicError: {
        error: "生成失败，请稍后再试",
      },
    }
  }

  const content = data?.choices?.[0]?.message?.content

  if (!content || typeof content !== "string") {
    return {
      ok: false,
      provider: "kimi",
      rateLimited: false,
      statusCode: 500,
      internalError: "Invalid Kimi response content",
      publicError: { error: "生成结果格式异常，请重试" },
    }
  }

  const generatedContent = parseGeneratedContent(content, generationFormat)
  if (!generatedContent) {
    return {
      ok: false,
      provider: "kimi",
      rateLimited: false,
      statusCode: 500,
      internalError: "Failed to parse sentences",
      publicError: { error: "生成结果格式异常，请重试" },
    }
  }

  return {
    ok: true,
    sentences: generatedContent.sentences,
    tags: generatedContent.tags,
    provider: "kimi",
  }
}

async function finalizeAuthenticatedGeneration(
  adminClient: any,
  args: {
    memoryID: string
    userID: string
    clientRequestID: string | null
    imagePath: string
    createdAt: string
    provider: ProviderName
    sentences: Sentence[]
    tags: string[]
  }
): Promise<
  | { ok: true; remainingCredits: number }
  | {
      ok: false
      code?: string
      outcomeUnknown?: boolean
      statusCode: number
      internalError: string
      publicError: Record<string, unknown>
    }
> {
  const { data, error } = await adminClient.rpc("finalize_authenticated_generation", {
    p_memory_id: args.memoryID,
    p_user_id: args.userID,
    p_client_request_id: args.clientRequestID,
    p_image_path: args.imagePath,
    p_created_at: args.createdAt,
    p_provider: args.provider,
    p_sentences: args.sentences,
    p_tags: args.tags,
  })

  if (error) {
    return { ...buildRpcErrorResponse(error, "Authenticated finalize failed"), outcomeUnknown: !/^[0-9A-Z]{5}$/.test(error.code ?? "") }
  }

  return {
    ok: true,
    remainingCredits: normalizeRPCInteger(data),
  }
}

async function finalizeGuestGeneration(
  adminClient: any,
  args: {
    guestJobID: string
    userID: string
    createdAt: string
    provider: ProviderName
    sentences: Sentence[]
    tags: string[]
  }
): Promise<
  | { ok: true; remainingCredits: number }
  | {
      ok: false
      code?: string
      outcomeUnknown?: boolean
      statusCode: number
      internalError: string
      publicError: Record<string, unknown>
    }
> {
  const { data, error } = await adminClient.rpc("finalize_guest_generation", {
    p_guest_job_id: args.guestJobID,
    p_user_id: args.userID,
    p_completed_at: args.createdAt,
    p_provider: args.provider,
    p_sentences: args.sentences,
    p_tags: args.tags,
  })

  if (error) {
    return { ...buildRpcErrorResponse(error, "Guest finalize failed"), outcomeUnknown: !/^[0-9A-Z]{5}$/.test(error.code ?? "") }
  }

  return {
    ok: true,
    remainingCredits: normalizeRPCInteger(data),
  }
}

async function indexGeneratedSentencesForStudyScenes(
  adminClient: any,
  userID: string,
  sentences: FinalizedSentence[],
  fetcher: typeof fetch
): Promise<void> {
  if (sentences.length === 0) {
    return
  }

  try {
    const embeddingRows = await buildSentenceEmbeddingRows(sentences, fetcher)

    const { error: upsertError } = await adminClient.from("sentence_embeddings").upsert(
      embeddingRows.map((row) => ({
        ...row,
        user_id: userID,
      })),
      { onConflict: "sentence_id" }
    )
    if (upsertError) {
      throw new Error(`Embedding storage failed: ${upsertError.message}`)
    }

    await Promise.all(
      sentences.map(async (sentence) => {
        const { error } = await adminClient.rpc(
          "refresh_semantic_study_scene_matches_for_sentence",
          {
            p_sentence_id: sentence.id,
            p_user_id: userID,
          }
        )
        if (error) {
          throw new Error(`Scene matching failed: ${error.message}`)
        }
      })
    )
  } catch (error) {
    console.error(
      "[generate-memory-v2] semantic sentence indexing failed",
      error instanceof Error ? error.message : String(error)
    )
  }
}

async function stageGuestSentenceEmbeddings(
  adminClient: any,
  userID: string,
  guestJobID: string,
  sentences: FinalizedSentence[],
  fetcher: typeof fetch
): Promise<void> {
  if (sentences.length === 0) {
    return
  }

  try {
    const embeddingRows = await buildSentenceEmbeddingRows(sentences, fetcher)
    const { error } = await adminClient.from("guest_sentence_embeddings").upsert(
      embeddingRows.map((row) => ({
        ...row,
        guest_user_id: userID,
        guest_job_id: guestJobID,
      })),
      { onConflict: "sentence_id" }
    )
    if (error) {
      throw new Error(`Guest embedding storage failed: ${error.message}`)
    }
  } catch (error) {
    console.error(
      "[generate-memory-v2] anonymous semantic sentence staging failed",
      error instanceof Error ? error.message : String(error)
    )
  }
}

async function buildSentenceEmbeddingRows(sentences: FinalizedSentence[], fetcher: typeof fetch) {
  const purposes = sentences.flatMap((sentence, index) => {
    const text = normalizeExpressionPurpose(sentence.expression_purpose)
    return text ? [{ index, text }] : []
  })
  if (purposes.length !== sentences.length) {
    console.warn("[generate-memory-v2] missing expression purposes", sentences.length - purposes.length)
  }
  // Independent requests: one provider failure must not discard the other route.
  const [original, purpose] = await Promise.allSettled([
    fetchSentenceEmbeddings(sentences.map((sentence) => `English: ${sentence.english}\nChinese: ${sentence.chinese}`), fetcher),
    purposes.length ? fetchSentenceEmbeddings(purposes.map((item) => item.text), fetcher) : Promise.resolve([]),
  ])
  for (const [route, result] of [["sentence", original], ["purpose", purpose]] as const) {
    if (result.status === "rejected") {
      console.error(`[generate-memory-v2] ${route} embedding failed`, result.reason instanceof Error ? result.reason.message : String(result.reason))
    }
  }
  const purposeVectors = new Map(purposes.map((item, i) => [item.index, purpose.status === "fulfilled" ? purpose.value[i] : null]))
  return sentences.map((sentence, index) => ({
    sentence_id: sentence.id,
    embedding: original.status === "fulfilled" ? original.value[index] : null,
    expression_purpose: normalizeExpressionPurpose(sentence.expression_purpose) ?? null,
    purpose_embedding: purposeVectors.get(index) ?? null,
    model: "qwen3.7-text-embedding",
    updated_at: new Date().toISOString(),
  }))
}

async function fetchSentenceEmbeddings(texts: string[], fetcher: typeof fetch): Promise<number[][]> {
  const apiKey = Deno.env.get("DASHSCOPE_API_KEY")
  const embeddingURL = Deno.env.get("DASHSCOPE_EMBEDDING_URL")
  if (!apiKey || !embeddingURL) {
    throw new Error("Missing DashScope embedding configuration")
  }

  const response = await fetchWithTimeout(
    embeddingURL,
    {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${apiKey}`,
      },
      body: JSON.stringify({
        model: "qwen3.7-text-embedding",
        input: {
          texts,
        },
        parameters: {
          dimension: 1024,
          output_type: "dense",
          text_type: "document",
        },
      }),
    },
    8_000,
    fetcher
  )
  const rawText = await response.text()
  if (!response.ok) {
    throw new Error(`Embedding request failed: HTTP ${response.status}`)
  }

  const payload = JSON.parse(rawText)
  const items = payload?.data ?? payload?.output?.embeddings
  if (!Array.isArray(items) || items.length !== texts.length) throw new Error("Invalid embedding count")
  const embeddings: unknown[] = Array(texts.length)
  const seen = new Set<number>()
  for (let i = 0; i < items.length; i++) {
    const index = items[i]?.text_index ?? items[i]?.index ?? i
    if (!Number.isInteger(index) || index < 0 || index >= texts.length || seen.has(index)) throw new Error("Invalid embedding index")
    seen.add(index)
    embeddings[index] = items[i]?.embedding
  }

  if (
    embeddings.length !== texts.length ||
    embeddings.some(
      (embedding: unknown) =>
        !Array.isArray(embedding) ||
        embedding.length !== 1024 ||
        !embedding.every((value) => typeof value === "number" && Number.isFinite(value)) ||
        !embedding.some((value) => value !== 0)
    )
  ) {
    throw new Error("Embedding response had an invalid vector")
  }

  return embeddings as number[][]
}

async function updateMemoryGenerationDiagnostics(
  adminClient: any,
  args: {
    memoryID: string
    userID: string
    provider: ProviderName
    mimoFailureReason: string | null
  }
): Promise<void> {
  try {
    const { error } = await adminClient
      .from("memories")
      .update({
        provider: args.provider,
        mimo_failure_reason: args.mimoFailureReason,
      })
      .eq("id", args.memoryID)
      .eq("user_id", args.userID)

    if (error) {
      throw error
    }
  } catch (error) {
    console.error(
      "[generate-memory-v2]",
      serializeGenerationError({
        provider: args.provider,
        code: "generation_diagnostics_update_failed",
        statusCode: 500,
        internalError: error instanceof Error ? error.message : String(error),
      })
    )
  }
}

async function updateGuestGenerationDiagnostics(
  adminClient: any,
  args: {
    guestJobID: string
    provider: ProviderName
    mimoFailureReason: string | null
  }
): Promise<void> {
  try {
    const { error } = await adminClient
      .from("guest_generation_jobs")
      .update({
        provider: args.provider,
        mimo_failure_reason: args.mimoFailureReason,
      })
      .eq("id", args.guestJobID)

    if (error) {
      throw error
    }
  } catch (error) {
    console.error(
      "[generate-memory-v2]",
      serializeGenerationError({
        provider: args.provider,
        code: "guest_generation_diagnostics_update_failed",
        statusCode: 500,
        internalError: error instanceof Error ? error.message : String(error),
      })
    )
  }
}

async function loadCompletedAuthenticatedGenerationResponseIfNeeded(
  adminClient: any,
  args: {
    clientRequestID: string
    userID: string
    fallbackRemainingCredits: number
    generationFormat: GenerationFormat
  }
): Promise<Response | null> {
  const { data: job, error: jobError } = await adminClient
    .from("generation_jobs")
    .select("status, memory_id, remaining_credits")
    .eq("client_request_id", args.clientRequestID)
    .eq("user_id", args.userID)
    .maybeSingle()

  if (jobError) {
    console.error("[generate-memory-v2] generation lookup failed", jobError.message)
    return generationPendingResponse(true)
  }
  if (job?.status !== "completed") return null
  if (!job.memory_id) return jsonResponse({ error: "生成结果已不可用。", code: "generation_result_unavailable" }, 410)

  const { data: memory, error: memoryError } = await adminClient
    .from("memories")
    .select(
      `
      id,
      image_url,
      created_at,
      provider,
      tags,
      memory_sentences (
        id,
        english,
        chinese,
        learning_topic_ids,
        presentation_group,
        is_favorite,
        sort_order
      )
    `
    )
    .eq("id", job.memory_id)
    .eq("user_id", args.userID)
    .maybeSingle()

  if (memoryError) return generationPendingResponse(true)
  if (!memory) return jsonResponse({ error: "生成结果已不可用。", code: "generation_result_unavailable" }, 410)

  const sentences = Array.isArray(memory.memory_sentences)
    ? [...memory.memory_sentences].sort(
        (left: any, right: any) => (left.sort_order ?? 0) - (right.sort_order ?? 0)
      )
    : []

  if (!hasSupportedStoredSentenceCount(sentences.length, args.generationFormat)) {
    return generationPendingResponse(true)
  }

  return jsonResponse({
    memory: {
      id: memory.id,
      imagePath: memory.image_url ?? "",
      createdAt: memory.created_at,
      provider: memory.provider ?? null,
      tags: Array.isArray(memory.tags) ? memory.tags : [],
      sentences: toClientSentences(sentences, args.generationFormat),
    },
    remainingCredits: job.remaining_credits ?? args.fallbackRemainingCredits,
    clientRequestID: args.clientRequestID,
  })
}

async function loadCompletedGuestGenerationResponseIfNeeded(
  adminClient: any,
  args: {
    guestJobID: string
    userID: string
    fallbackCreatedAt: string
    fallbackRemainingCredits: number
    generationFormat: GenerationFormat
  }
): Promise<Response | null> {
  const { data: completedJob, error: completedJobError } = await adminClient
    .from("guest_generation_jobs")
    .select("id, created_at, remaining_credits, sentences, provider, tags")
    .eq("id", args.guestJobID)
    .eq("user_id", args.userID)
    .maybeSingle()

  if (completedJobError) {
    console.error("[generate-memory-v2] completed guest lookup failed", completedJobError.message)
    return generationPendingResponse(true)
  }

  const sentences = Array.isArray(completedJob?.sentences) ? completedJob.sentences : []
  if (!hasSupportedStoredSentenceCount(sentences.length, args.generationFormat)) {
    return generationPendingResponse(true)
  }

  return jsonResponse({
    memory: {
      id: crypto.randomUUID(),
      imagePath: "",
      createdAt: completedJob?.created_at ?? args.fallbackCreatedAt,
      provider: completedJob?.provider ?? null,
      tags: Array.isArray(completedJob?.tags) ? completedJob.tags : [],
      sentences: toClientSentences(sentences, args.generationFormat),
    },
    remainingCredits: completedJob?.remaining_credits ?? args.fallbackRemainingCredits,
    guestJobID: args.guestJobID,
  })
}

function hasSupportedStoredSentenceCount(count: number, generationFormat: GenerationFormat): boolean {
  return generationFormat === "legacy_v1" ? count >= 3 : count === 3 || count === 6
}

function isUUID(value: unknown): value is string {
  return typeof value === "string" &&
    /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value)
}

function toClientSentences(
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

async function updateAuthenticatedGenerationDiagnostics(
  adminClient: any,
  args: { clientRequestID: string; userID: string; memoryID: string; mimoFailureReason: string | null }
): Promise<void> {
  try {
    const { error } = await adminClient.from("generation_jobs")
      .update({ mimo_failure_reason: args.mimoFailureReason })
      .eq("client_request_id", args.clientRequestID)
      .eq("user_id", args.userID)
      .eq("memory_id", args.memoryID)
      .eq("status", "completed")
    if (error) throw error
  } catch (error) {
    console.error("[generate-memory-v2] job diagnostics failed", String(error))
  }
}

async function markAuthenticatedGenerationJobFailed(
  adminClient: any,
  clientRequestID: string,
  userID: string,
  errorMessage: string
): Promise<void> {
  try {
    const now = new Date().toISOString()
    const { error } = await adminClient
      .from("generation_jobs")
      .update({
        status: "failed",
        error_message: truncateDiagnosticText(errorMessage, 1000),
        updated_at: now,
        failed_at: now,
      })
      .eq("client_request_id", clientRequestID)
      .eq("user_id", userID)
      .eq("status", "pending")

    if (error) {
      throw error
    }
  } catch (error) {
    console.error(
      "[generate-memory-v2]",
      serializeGenerationError({
        code: "authenticated_generation_job_fail_update_failed",
        statusCode: 500,
        internalError: error instanceof Error ? error.message : String(error),
      })
    )
  }
}

async function tryAcquireGenerationSlot(
  adminClient: any,
  args: {
    requestID: string
    userID: string
  }
): Promise<boolean> {
  const { data, error } = await adminClient.rpc("try_acquire_generation_slot", {
    p_request_id: args.requestID,
    p_user_id: args.userID,
    p_max_slots: GENERATION_CONCURRENCY_LIMIT,
    p_ttl_seconds: GENERATION_SLOT_TTL_SECONDS,
  })

  if (error) {
    throw new Error(`Acquire generation slot failed: ${error.message}`)
  }

  return data === true
}

async function releaseGenerationSlot(adminClient: any, requestID: string): Promise<void> {
  const { error } = await adminClient.rpc("release_generation_slot", {
    p_request_id: requestID,
  })

  if (error) {
    throw new Error(`Release generation slot failed: ${error.message}`)
  }
}

function buildRpcErrorResponse(
  error: {
    message: string
    details?: string | null
    hint?: string | null
    code?: string
  },
  fallbackMessage: string
): {
  ok: false
  code?: string
  statusCode: number
  internalError: string
  publicError: Record<string, unknown>
} {
  const normalizedMessage = `${error.message} ${error.details ?? ""}`.trim().toLowerCase()
  const isNoCredits = normalizedMessage.includes("no credits left")

  if (isNoCredits) {
    return {
      ok: false,
      code: "no_credits_left",
      statusCode: 403,
      internalError: error.message,
      publicError: {
        error: "No credits left",
      },
    }
  }

  return {
    ok: false,
    code: error.code,
    statusCode: 500,
    internalError: `${fallbackMessage}: ${error.message}`,
    publicError: {
      error: "生成失败，请稍后再试",
    },
  }
}

function normalizeRPCInteger(value: unknown): number {
  if (typeof value === "number" && Number.isFinite(value)) {
    return value
  }

  if (typeof value === "string") {
    const parsed = Number.parseInt(value, 10)
    if (Number.isFinite(parsed)) {
      return parsed
    }
  }

  throw new Error(`Unexpected RPC integer result: ${JSON.stringify(value)}`)
}

type ImageModerationResult =
  | { allowed: true }
  | {
      allowed: false
      code: string
      policyViolation: boolean
      countedViolation: boolean
      statusCode: number
      internalError: string
      publicError: Record<string, unknown>
    }

type GenerationViolationRecord = {
  violationCount: number
  bannedUntil: string | null
}

async function moderateImageBeforeGeneration(args: {
  userID: string
  imageBase64: string
  existingImagePath: string | null
  requestID: string
  fetcher: typeof fetch
}): Promise<ImageModerationResult> {
  if (!isEnabledEnvFlag(Deno.env.get("IMAGE_MODERATION_ENABLED"))) {
    return { allowed: true }
  }

  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")?.trim()
  const functionURL = buildModerationFunctionURL()

  if (!serviceRoleKey || !functionURL) {
    return buildImageModerationAllowResult("missing moderation function configuration")
  }

  const requestBody: Record<string, unknown> = {
    userID: args.userID,
    requestID: args.requestID,
    existingImagePath: args.existingImagePath,
    imageBase64: args.imageBase64,
  }

  try {
    const response = await fetchWithTimeout(
      functionURL,
      {
        method: "POST",
        headers: {
          Authorization: `Bearer ${serviceRoleKey}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify(requestBody),
      },
      IMAGE_MODERATION_FUNCTION_TIMEOUT_MS,
      args.fetcher
    )
    const rawText = await response.text()
    let data: unknown = null
    try {
      data = rawText ? JSON.parse(rawText) : null
    } catch {
      data = null
    }

    if (!response.ok) {
      return buildImageModerationAllowResult(
        `moderation function HTTP ${response.status}: ${rawText.slice(0, 1000)}`
      )
    }

    return normalizeModerationFunctionResult(data, rawText)
  } catch (error) {
    if (isTimeoutError(error)) {
      console.warn(
        "[generate-memory-v2]",
        serializeGenerationError({
          code: "image_moderation_timeout_allow",
          statusCode: 200,
          internalError: "image moderation did not return within 10s; allowing generation",
        })
      )
      return { allowed: true }
    }

    return buildImageModerationAllowResult(
      error instanceof Error ? error.message : String(error)
    )
  }
}

function isTimeoutError(error: unknown): boolean {
  return error instanceof DOMException && error.name === "AbortError"
}

function buildModerationFunctionURL(): string | null {
  const configuredURL = Deno.env.get("IMAGE_MODERATION_FUNCTION_URL")?.trim()
  if (configuredURL) {
    return configuredURL
  }

  const supabaseURL = (Deno.env.get("SUPABASE_LOCAL_URL") ?? Deno.env.get("SUPABASE_URL"))?.trim()
  if (!supabaseURL) {
    return null
  }
  return `${supabaseURL.replace(/\/$/, "")}/functions/v1/moderate-image-v1`
}

function normalizeModerationFunctionResult(
  data: unknown,
  rawText: string
): ImageModerationResult {
  if (typeof data === "object" && data !== null && "allowed" in data) {
    const result = data as Record<string, unknown>
    if (result.allowed === true) {
      return { allowed: true }
    }

    if (result.allowed === false) {
      const policyViolation = result.policyViolation === true
      if (!policyViolation) {
        return buildImageModerationAllowResult(
          String(result.internalError ?? result.code ?? "moderation function unavailable")
        )
      }

      const publicError =
        typeof result.publicError === "object" && result.publicError !== null
          ? (result.publicError as Record<string, unknown>)
          : {
              error: "图片安全检查失败，请稍后再试。",
              code: "image_moderation_unavailable",
            }

      return {
        allowed: false,
        code: String(result.code ?? "image_moderation_unavailable"),
        policyViolation,
        countedViolation: result.countedViolation === true,
        statusCode:
          typeof result.statusCode === "number" && Number.isFinite(result.statusCode)
            ? result.statusCode
            : 503,
        internalError: String(result.internalError ?? "missing moderation internal error"),
        publicError,
      }
    }
  }

  return buildImageModerationAllowResult(
    `invalid moderation function response: ${rawText.slice(0, 1000)}`
  )
}

function buildImageModerationAllowResult(internalError: string): ImageModerationResult {
  console.warn(
    "[generate-memory-v2]",
    serializeGenerationError({
      code: "image_moderation_unavailable_allow",
      statusCode: 200,
      internalError: `image moderation unavailable; allowing generation: ${internalError}`,
    })
  )

  return { allowed: true }
}

async function removeStoragePathQuietly(adminClient: any, path: string): Promise<void> {
  try {
    await adminClient.storage.from("memories").remove([path])
  } catch (error) {
    console.error(
      "[generate-memory-v2]",
      serializeGenerationError({
        code: "storage_cleanup_failed",
        statusCode: 500,
        internalError: error instanceof Error ? error.message : String(error),
      })
    )
  }
}

function isEnabledEnvFlag(value: string | undefined | null): boolean {
  return ["1", "true", "yes", "on"].includes(value?.trim().toLowerCase() ?? "")
}

function isGenerationViolationBanEnabled(): boolean {
  const value = Deno.env.get("GENERATION_VIOLATION_BAN_ENABLED")?.trim().toLowerCase()
  if (!value) {
    return true
  }
  return !["0", "false", "no", "off"].includes(value)
}

function isFutureTimestamp(value: unknown): boolean {
  if (typeof value !== "string" || !value.trim()) {
    return false
  }

  const timestamp = Date.parse(value)
  return Number.isFinite(timestamp) && timestamp > Date.now()
}

async function recordGenerationViolation(
  adminClient: any,
  userID: string
): Promise<GenerationViolationRecord | null> {
  const { data, error } = await adminClient.rpc("record_generation_violation", {
    p_user_id: userID,
    p_window_seconds: GENERATION_VIOLATION_WINDOW_SECONDS,
    p_limit: GENERATION_VIOLATION_LIMIT,
    p_ban_seconds: GENERATION_VIOLATION_BAN_SECONDS,
  })

  if (error) {
    console.error(
      "[generate-memory-v2]",
      serializeGenerationError({
        code: "record_generation_violation_failed",
        statusCode: 500,
        internalError: error.message,
      })
    )
    return null
  }

  const record = Array.isArray(data) ? data[0] : data
  if (!record) {
    return null
  }

  const rawCount = record.violation_count ?? record.violationCount
  const violationCount =
    typeof rawCount === "number" ? rawCount : Number.parseInt(String(rawCount ?? "0"), 10)
  const bannedUntil =
    typeof record.banned_until === "string"
      ? record.banned_until
      : typeof record.bannedUntil === "string"
        ? record.bannedUntil
        : null

  return {
    violationCount: Number.isFinite(violationCount) ? violationCount : 0,
    bannedUntil,
  }
}

function buildGenerationPolicyViolationError(
  record: GenerationViolationRecord | null
): Record<string, unknown> {
  const isBanned = isFutureTimestamp(record?.bannedUntil)

  return {
    error: isBanned
      ? "当前账号暂时无法生成，请稍后再试。"
      : "这张图片暂时无法生成，请更换图片后再试。",
    code: isBanned ? "generation_banned" : "generation_policy_violation",
    bannedUntil: record?.bannedUntil ?? null,
    violationCount: record?.violationCount ?? null,
  }
}

function generationPendingResponse(timedOut = false): Response {
  return jsonResponse({
    error: timedOut ? "request timed out" : "生成仍在处理中，请稍后查看回忆。",
    code: "generation_in_progress",
    provider: "generation_job",
  }, timedOut ? 504 : 409)
}

async function markGuestGenerationJobFailed(adminClient: any, jobID: string, userID: string, message: string): Promise<void> {
  try {
    const { error } = await adminClient.from("guest_generation_jobs")
      .update({ status: "failed", error_message: truncateDiagnosticText(message, 1000) })
      .eq("id", jobID).eq("user_id", userID).eq("status", "pending")
    if (error) throw error
  } catch (error) {
    console.error("[generate-memory-v2] guest failure update failed", String(error))
  }
}
