import { createClient } from "npm:@supabase/supabase-js@2"
import { fetchWithTimeout, fetchWithinDeadline } from "../_shared/fetch-with-timeout.ts"
import { scheduleGenerationEnrichment } from "../_shared/generation-enrichment.ts"
import { GenerationTiming, withGenerationTiming } from "../_shared/generation-timing.ts"

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
const EXPRESSION_PURPOSE_PROMPT = "expression_purpose：每句的简短英文用途，最多 30 个英文单词且不超过 240 个字符。依据句子本身，不是照片整体；保留关键对象、动作、感受及限制，不增补人物、关系、背景、感受或场景。不写宽泛分类、原句重复/翻译或多个猜测。湖边愉快用餐的用途是 Sharing an enjoyable meal beside a lake.，不是描述山水风景。"
const LEARNING_TOPIC_CLASSIFICATION_GUIDANCE = [
  "self_and_style：自拍、形象、穿搭、发型、配饰，不泛指人物",
  "family_time：家人相伴、合影、陪伴父母，不以孩子成长为主",
  "children_growing_up：孩子玩耍、成长、亲子活动，不是学校课程",
  "friends_gatherings：朋友相伴、聚餐、活动，不是明确庆生过节",
  "romance_and_companionship：约会、恋爱、亲密陪伴，不凭两个人臆造情侣关系",
  "pet_life：宠物日常、喂养、遛宠物，不含野生或动物园动物",
  "food_and_drinks：菜品、饮料、咖啡、甜品的外观、味道、口感及吃喝体验，不含制作",
  "cooking：备菜、烹调、烘焙，不含单纯的成品味道",
  "home_life：房间、家具、布置、搬家、家务、居家日常，不以家人互动为主",
  "city_life：街道、建筑、商店外观、城市夜景，不含购买行为",
  "natural_scenery：山川湖海、日落、天气、季节、雪景，不以具体花草动物为主",
  "plants_and_wildlife：花草树木、鸟、野生或动物园动物，不含宠物相处",
  "travel：旅行经历、游览、酒店、当地见闻，不含交通过程，也不泛指旅游照片",
  "transport：机场、车站、乘车、通勤、自驾、旅途交通",
  "sports_and_outdoors：健身、跑步、骑行、徒步、露营等活动，不含单纯山景",
  "festivals_and_celebrations：生日、婚礼、节日、纪念日、毕业庆典，不含普通朋友见面",
  "arts_and_entertainment：演出、展览、电影、游乐园、阅读、音乐、游戏",
  "school_and_study：课堂、校园、书本、课程、作业、学习，不含毕业庆祝",
  "work_life：工位、同事、会议、任务、工作成果，不凭室内布置臆造工作场景",
  "shopping：购买、选品、试穿、价格、购买体验、新购物品，不含单纯穿着",
  "health_and_wellness：身体、医院、体检、康复、休息、健康照护，不以锻炼动作为主",
].join("；")

function buildPromptText(
  englishLevel: "启蒙" | "简单" | "中等" | "高级",
  languageStyle: "平铺直叙" | "抒情优美",
  generationFormat: GenerationFormat
): string {
  const englishLevelPrompt =
    englishLevel === "启蒙"
      ? "启蒙难度：儿童/零基础；每句 3 到 6 个英文单词，优先 3 到 5 个。一句一意，用极常见具体词、一般现在时/be 简单句，完整自然，不用碎片短语。禁用从句、抽象词、习语、俚语、比喻、拟人、双关、复杂时态、文学表达；中文适合儿童。启蒙词汇/句长限制在所有组中优先于风格、幽默和表达层次。"
      : englishLevel === "简单"
      ? "初学者：每句尽量 6 到 12 个单词，小学至初中常见词、简单主谓宾或 This is/There is；不用抽象/书面词、复杂从句、比喻、拟人、分词状语/定语。"
      : englishLevel === "高级"
        ? "高级：每句尽量 14 到 24 个单词，词汇细腻、结构完整有层次，可适度修辞、变化节奏；自然准确易懂，不写诗或炫技。"
        : "中等：每句尽量 10 到 18 个单词，稍丰富的日常表达，可用定语/状语及完整结构，不书面或艰深。"

  const languageStylePrompt =
    englishLevel === "启蒙"
      ? "风格固定为平铺直叙：友好、自然、直接，不抒情。"
      : languageStyle === "抒情优美"
      ? "风格抒情：明显细腻、温柔，有画面感和情绪节奏；自然准确易懂，不写诗、过度夸张或脱离图片。"
      : "风格生动活泼：具体动词、自然口语、有节奏；轻微幽默取自可见对比/动作/细节，不写段子、网络梗、夸张笑话、生硬拟人，不虚构动作/对话/情绪/细节。"

  const outputRules = `
只输出 JSON 对象，不用 markdown/代码块/解释/额外字段，不把整个对象转义或包成字符串。
句子仅含 english、chinese、learning_topic_ids 和 expression_purpose 四个字段；除分类外均为非空字符串，必须显式写出 chinese 字段名；中文每句 ${englishLevel === "启蒙" ? "3 到 15" : "8 到 30"} 个汉字。
learning_topic_ids 数组：按句意而非照片整体分类，主类在前，最多 2 个不同 ID；仅明确涉及另一独立场景时加第二个。照片只消歧，不以句外背景补分类；无匹配场景（票据/证件/备忘截图/无场景感叹等）返回 []。限下列 ID，按边界确定主类：
${LEARNING_TOPIC_CLASSIFICATION_GUIDANCE}
蛋糕味道→food_and_drinks，庆生→festivals_and_celebrations；家庭露营→sports_and_outdoors+family_time，未提家人不补 family_time，湖景背景不补 natural_scenery。
tags：照片分类数组，1 到 3 个不重复的字符串，只能选：${MEMORY_TAGS.join("、")}。
${EXPRESSION_PURPOSE_PROMPT}`

  if (generationFormat === "dual_tabs_v1") {
    return `
看图生成两组英语学习句子及中文翻译。
${englishLevelPrompt}
${languageStylePrompt}

image_descriptions：3 句客观描述，只写可见的人/物/动作/环境/文字，不推测关系、背景或感受。
scene_and_feelings：3 句用户视角的场景表达，可大胆推测最可能的场景/关系/感受，不必声明推测，但不编造无依据的具体姓名/地点/时间/经历/事实。不写物体清单、同义改写或空泛鸡汤，按序各一句：
1. 我当时的感受：情绪、反应或氛围。
2. 当时会对别人说什么：围绕具体对象/活动，写一句发现/建议/邀请/提问/请求/提醒/回应，不限问句或请求。禁用通用寒暄、重复感受、事后配文；仅画面明确涉及拍照才可请求拍照。直接写用户会说的这句及译文，不写双方对话、说话人标签、额外引号或 I would say 等前言。此句允许假设对话，但不得写成已发生的事实。
3. 发生了什么：第一人称的最可能场景或动作。
1、3 优先 I/we；2 可用 you/we、祈使句或疑问句。
场景表达以母语者对朋友说话/照片配文的日常口语为准，优先于难度/风格：高级仅提升搭配、情绪词、节奏，不用复杂从句、书面词、文学修辞；抒情仅温暖、有画面感、真诚，不写诗、散文或文艺腔。
${englishLevel === "启蒙" ? "启蒙场景表达仍须 3 到 6 个单词，启蒙限制优先。" : "场景表达每句尽量 8 到 18 个英文单词。"}
信息图（截图/界面/图表/股票/数据面板/网页/文档）：客观组概括可见内容，场景组写看到/记录/分享时的话；不分析数据、解读涨跌或逐项抄录文字数字。

顶层仅 image_descriptions、scene_and_feelings、tags；两组句子数组各 3 项。
${outputRules}

严格按此结构填入内容：
{"image_descriptions":[{"english":"...","chinese":"...","learning_topic_ids":["self_and_style"],"expression_purpose":"..."},{"english":"...","chinese":"...","learning_topic_ids":["natural_scenery"],"expression_purpose":"..."},{"english":"...","chinese":"...","learning_topic_ids":["home_life"],"expression_purpose":"..."}],"scene_and_feelings":[{"english":"...","chinese":"...","learning_topic_ids":["festivals_and_celebrations"],"expression_purpose":"..."},{"english":"...","chinese":"...","learning_topic_ids":["sports_and_outdoors","family_time"],"expression_purpose":"..."},{"english":"...","chinese":"...","learning_topic_ids":[],"expression_purpose":"..."}],"tags":["人物","生活场景"]}
`.trim()
  }

  return `
看图生成 3 句英语描述及中文翻译，供学习模仿，仅限最明显、最直接可见的内容。
信息图（截图/界面/图表/股票/数据面板/网页/文档）：仅概括屏幕/图表/数字，不分析、解读涨跌、总结数据或逐项抄录文字数字。
${englishLevelPrompt}
${languageStylePrompt}

顶层仅 sentences、tags；sentences 数组固定 3 项。
${outputRules}

严格按此结构填入内容：
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

Deno.serve((req) => withGenerationTiming(req, handleGenerationRequest))

async function handleGenerationRequest(req: Request, timing: GenerationTiming): Promise<Response> {
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

    timing.start("auth")
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
    timing.start("profile")
    const { data: profile, error: profileError } = await adminClient
      .from("profiles")
      .select("available_generations, generation_banned_until")
      .eq("id", user.id)
      .single()

    if (profileError || !profile) {
      if (Date.now() >= generationDeadline) return generationPendingResponse(true)
      return jsonResponse({ error: "Profile not found" }, 404)
    }

    timing.start("request_decode")
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

    timing.start("existing_result")
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

    timing.start("concurrency_slot")
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
      timing.start("job_claim")
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
      timing.start("guest_image_upload")
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

    timing.start("moderation")
    const moderationResult = await moderateImageBeforeGeneration({
      userID: user.id,
      imageBase64,
      existingImagePath: isAnonymous ? guestImagePath : null,
      requestID: generationSlotRequestID,
      fetcher: generationFetch,
    })

    if (!moderationResult.allowed) {
      timing.start("error_handling")
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

    timing.start("prompt")
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
      timing,
    })

    if (!completionResult.ok) {
      timing.start("error_handling")
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

    timing.start("result_prepare")
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
      timing.start("finalize")
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
        timing.start("error_handling")
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

      timing.start("diagnostics")
      await updateGuestGenerationDiagnostics(adminClient, {
        guestJobID: guestJobID!,
        provider,
        mimoFailureReason,
      })

      timing.start("read_result")
      return await loadCompletedGuestGenerationResponseIfNeeded(adminClient, {
        guestJobID: guestJobID!, userID: user.id, fallbackCreatedAt: createdAt,
        fallbackRemainingCredits: finalizeResult.remainingCredits, generationFormat,
      }) ?? generationPendingResponse(true)
    }

    const memoryID = crypto.randomUUID()
    const imagePath = `${user.id}/${crypto.randomUUID().toLowerCase()}.jpg`

    timing.start("image_upload")
    const { error: uploadError } = await adminClient.storage
      .from("memories")
      .upload(imagePath, imageBytes, {
        contentType: "image/jpeg",
        upsert: false,
      })

    if (uploadError) {
      timing.start("error_handling")
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

    timing.start("finalize")
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
      timing.start("error_handling")
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

    timing.start("diagnostics")
    await updateMemoryGenerationDiagnostics(adminClient, {
      memoryID,
      userID: user.id,
      provider,
      mimoFailureReason,
    })

    if (authenticatedClientRequestID) {
      await updateAuthenticatedGenerationDiagnostics(adminClient, {
        clientRequestID: authenticatedClientRequestID,
        userID: user.id,
        memoryID,
        mimoFailureReason,
      })
      // The transaction owns the canonical memory ID and response, not this worker.
      timing.start("read_result")
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
    timing.start("error_handling")
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
      timing.start("release_slot")
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
    // Finalization queued the indexing payload in the same transaction as the
    // result and debit. Never wait for embeddings before delivering the result.
    if (generationUserID) {
      timing.start("background_dispatch")
      try { scheduleGenerationEnrichment(generationUserID) } catch (error) {
        console.error("[generate-memory-v2] could not start background indexing", String(error))
      }
    }
  }
}

async function requestWithFallback(args: {
  imageBase64: string
  promptText: string
  generationFormat: GenerationFormat
  mimoBaseURL: string
  mimoApiKey: string
  kimiBaseURL: string
  kimiApiKey: string
  fetcher: typeof fetch
  timing?: GenerationTiming
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

  args.timing?.start("mimo")
  const mimoResult = await requestMimoOnce(
    args.mimoBaseURL,
    args.mimoApiKey,
    mimoRequestBody,
    args.generationFormat,
    args.fetcher
  )

  args.timing?.start("model_result")
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

  args.timing?.start("kimi")
  const kimiResult = await requestKimiOnce(
    args.kimiBaseURL,
    args.kimiApiKey,
    kimiRequestBody,
    args.generationFormat,
    args.fetcher
  )

  args.timing?.start("model_result")
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
