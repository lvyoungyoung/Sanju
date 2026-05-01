export interface Sentence {
  english: string
  chinese: string
}

export type ProviderName = "mimo" | "kimi"

export function buildPromptText(
  englishLevel: "简单" | "中等" | "高级",
  languageStyle: "平铺直叙" | "抒情优美"
): string {
  const englishLevelPrompt =
    englishLevel === "简单"
      ? "请使用非常简单、非常常见的英语词汇和句式，默认面向英语初学者。每句尽量控制在 6 到 12 个单词之间，优先使用小学到初中阶段常见词，不要使用抽象词、书面词、复杂从句、比喻、拟人、现在分词作状语、过去分词作定语等复杂结构。尽量多用简单主谓宾句型，例如 This is..., There is..., A girl is..., The cat is...。"
      : englishLevel === "高级"
        ? "请使用更丰富、更自然、更有层次感的英语表达，默认面向英语水平较高的学习者。每句尽量控制在 14 到 24 个单词之间，可以使用更细腻的词汇、更加完整的句子结构，以及适度的修辞和节奏变化，但仍要保持自然、准确、可理解，不要写得像诗歌或过度炫技。"
        : "请使用自然、日常、适合中等英语水平学习者的表达。每句尽量控制在 10 到 18 个单词之间，可以使用常见但稍丰富一些的日常表达，允许适度使用定语、状语和更完整的句子结构，但不要过于书面或艰深。"

  const languageStylePrompt =
    languageStyle === "抒情优美"
      ? "整体风格请明显更细腻、更有画面感、更有情绪和节奏。可以适度使用温柔、优美、富有氛围感的词语，让句子读起来更柔和、更有美感，但仍然要自然、准确、易懂。允许轻微的抒情和意境表达，但不要写成诗歌，不要过度夸张，不要脱离图片内容。"
      : "整体风格请尽量客观、直接、朴素、清楚，像日常口语或基础学习材料，不要刻意营造氛围，不要使用文学化修饰，不要写得太美，也不要加入抽象感受、联想、象征或情绪渲染。优先描述看得见的内容本身。"

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
6. 顶层字段必须且只能是 sentences
7. sentences 必须是长度为 3 的数组
8. 每一项必须且只能包含 english 和 chinese 两个字段
9. english 和 chinese 都必须是字符串
10. 不要输出任何多余字段
11. 不要转义整个 JSON 对象
12. 不要在 JSON 前后添加任何字符
13. 每句中文控制在 8 到 30 个汉字之间
14. 如果图片里有文字或数字，可以适度提到 "a screen"、"a chart"、"some numbers" 这类概括性表达，但不要逐字抄录内容

你必须严格按照下面这个格式返回：
{"sentences":[{"english":"...","chinese":"..."},{"english":"...","chinese":"..."},{"english":"...","chinese":"..."}]}
`.trim()
}

export async function fetchWithTimeout(
  input: string,
  init: RequestInit,
  timeoutMs: number
): Promise<Response> {
  const controller = new AbortController()
  const timeout = setTimeout(() => controller.abort(), timeoutMs)

  try {
    return await fetch(input, {
      ...init,
      signal: controller.signal,
    })
  } finally {
    clearTimeout(timeout)
  }
}

export function serializeGenerationError(args: {
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

export function parseSentences(content: string): Sentence[] | null {
  const candidate = extractSentencePayload(content)
  if (!candidate || !Array.isArray(candidate.sentences)) {
    return extractSentencesByPattern(content)
  }

  const sentences = normalizeSentenceArray(candidate.sentences)
  if (sentences.length === 3) {
    return sentences
  }

  return extractSentencesByPattern(content)
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

function normalizeSentenceArray(value: any): Sentence[] {
  if (!Array.isArray(value)) {
    return []
  }

  return value
    .map((item: any) => ({
      english: String(item?.english ?? "").trim(),
      chinese: String(item?.chinese ?? "").trim(),
    }))
    .filter((item: Sentence) => item.english && item.chinese)
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
      matches.push({ english, chinese })
    }
  }

  return matches.length === 3 ? matches : null
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

export function decodeBase64(base64: string): Uint8Array {
  const binary = atob(base64)
  const bytes = new Uint8Array(binary.length)
  for (let index = 0; index < binary.length; index += 1) {
    bytes[index] = binary.charCodeAt(index)
  }
  return bytes
}

export function jsonResponse(data: unknown, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      "Content-Type": "application/json; charset=utf-8",
    },
  })
}
