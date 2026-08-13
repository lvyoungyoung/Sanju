import { createClient } from "npm:@supabase/supabase-js@2"

const MIMO_TIMEOUT_MS = 20_000
const KIMI_TIMEOUT_MS = 25_000
const MAX_SOURCE_SENTENCES = 120
const MAX_EXPRESSIONS_PER_KIND = 12

type ExpressionKind = "word" | "phrase"

interface ExtractionRequest {
  topicKey?: string
  sourceSentences?: SourceSentence[]
}

interface SourceSentence {
  id: string
  english: string
  chinese: string
}

interface ExtractedExpression {
  kind: ExpressionKind
  english: string
  chinese: string
  part_of_speech?: string
  occurrence_count: number
  sentence_ids: string[]
}

Deno.serve(async (req) => {
  try {
    if (req.method !== "POST") {
      return jsonResponse({ error: "Method Not Allowed" }, 405)
    }

    const supabaseURL = Deno.env.get("SUPABASE_LOCAL_URL") ?? Deno.env.get("SUPABASE_URL")
    const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY")
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")
    const mimoAPIKey = Deno.env.get("MIMO_API_KEY")
    const mimoBaseURL = Deno.env.get("MIMO_BASE_URL")
    const kimiAPIKey = Deno.env.get("KIMI_API_KEY")
    const kimiBaseURL = Deno.env.get("KIMI_BASE_URL")

    if (!supabaseURL || !supabaseAnonKey || !serviceRoleKey || !mimoAPIKey || !mimoBaseURL || !kimiAPIKey || !kimiBaseURL) {
      return jsonResponse({ error: "Missing server configuration" }, 500)
    }

    const authHeader = req.headers.get("Authorization")
    if (!authHeader?.startsWith("Bearer ")) {
      return jsonResponse({ error: "Missing Authorization header" }, 401)
    }

    const body = (await req.json()) as ExtractionRequest
    const topicKey = body.topicKey?.trim() ?? ""
    if (!isValidTopicKey(topicKey)) {
      return jsonResponse({ error: "Invalid study topic" }, 400)
    }

    const accessToken = authHeader.replace("Bearer ", "").trim()
    const userClient = createClient(supabaseURL, supabaseAnonKey, {
      global: { headers: { Authorization: `Bearer ${accessToken}` } },
    })
    const adminClient = createClient(supabaseURL, serviceRoleKey)
    const {
      data: { user },
      error: userError,
    } = await userClient.auth.getUser()

    if (userError || !user) {
      return jsonResponse({ error: "Invalid JWT" }, 401)
    }

    const sourceSentences = user.is_anonymous === true
      ? normalizeSourceSentences(body.sourceSentences)
      : await fetchTopicSentences(userClient, topicKey)
    if (sourceSentences.length < 2) {
      return jsonResponse({ expressions: [] })
    }

    if (user.is_anonymous === true) {
      const result = await extractWithFallback({
        mimoAPIKey,
        mimoBaseURL,
        kimiAPIKey,
        kimiBaseURL,
        sourceSentences,
      })
      if (!result.ok) {
        console.error("[extract-study-topic-expressions]", result.error)
        return jsonResponse({ error: "Unable to extract study topic expressions" }, 502)
      }
      return jsonResponse({
        expressions: makeTransientExpressions(sanitizeExpressions(result.expressions, sourceSentences), sourceSentences),
      })
    }

    const fingerprint = await sha256(
      sourceSentences
        .map((sentence) => `${sentence.id}|${sentence.english}|${sentence.chinese}`)
        .join("\n")
    )

    const { data: cachedExpressions, error: cachedError } = await userClient.rpc(
      "get_study_topic_expressions",
      {
        p_topic_key: topicKey,
        p_source_fingerprint: fingerprint,
      }
    )
    if (cachedError) {
      throw new Error(`Expression cache read failed: ${cachedError.message}`)
    }
    const { data: cacheSet, error: cacheSetError } = await userClient
      .from("study_topic_expression_sets")
      .select("source_fingerprint")
      .eq("user_id", user.id)
      .eq("topic_key", topicKey)
      .eq("source_fingerprint", fingerprint)
      .maybeSingle()
    if (cacheSetError) {
      throw new Error(`Expression cache metadata read failed: ${cacheSetError.message}`)
    }
    if (cacheSet) {
      return jsonResponse({
        expressions: Array.isArray(cachedExpressions) ? cachedExpressions : [],
      })
    }

    const result = await extractWithFallback({
      mimoAPIKey,
      mimoBaseURL,
      kimiAPIKey,
      kimiBaseURL,
      sourceSentences,
    })
    if (!result.ok) {
      console.error("[extract-study-topic-expressions]", result.error)
      return jsonResponse({ error: "Unable to extract study topic expressions" }, 502)
    }

    const expressions = sanitizeExpressions(result.expressions, sourceSentences)
    const { error: replaceError } = await adminClient.rpc("replace_study_topic_expressions", {
      p_user_id: user.id,
      p_topic_key: topicKey,
      p_source_fingerprint: fingerprint,
      p_expressions: expressions,
    })
    if (replaceError) {
      throw new Error(`Expression cache write failed: ${replaceError.message}`)
    }

    const { data: storedExpressions, error: storedError } = await userClient.rpc(
      "get_study_topic_expressions",
      {
        p_topic_key: topicKey,
        p_source_fingerprint: fingerprint,
      }
    )
    if (storedError) {
      throw new Error(`Expression cache reload failed: ${storedError.message}`)
    }

    return jsonResponse({ expressions: Array.isArray(storedExpressions) ? storedExpressions : [] })
  } catch (error) {
    console.error(
      "[extract-study-topic-expressions]",
      error instanceof Error ? error.message : String(error)
    )
    return jsonResponse({ error: "Unable to extract study topic expressions" }, 500)
  }
})

async function fetchTopicSentences(
  userClient: any,
  topicKey: string
): Promise<SourceSentence[]> {
  const { data, error } = await userClient.rpc("get_study_topic_source_sentences", {
    p_topic_key: topicKey,
    p_limit: MAX_SOURCE_SENTENCES,
  })
  if (error) {
    throw new Error(`Study topic sentence query failed: ${error.message}`)
  }

  return normalizeSourceSentences(data)
}

function normalizeSourceSentences(value: unknown): SourceSentence[] {
  if (!Array.isArray(value)) return []
  const seen = new Set<string>()
  return value.flatMap((item: any) => {
    const id = typeof item?.id === "string" ? item.id : ""
    const english = typeof item?.english === "string" ? item.english.trim() : ""
    const chinese = typeof item?.chinese === "string" ? item.chinese.trim() : ""
    if (!id || !english || !chinese || seen.has(id)) return []
    seen.add(id)
    return [{ id, english, chinese }]
  })
    .sort((left, right) => left.id.localeCompare(right.id))
    .slice(0, MAX_SOURCE_SENTENCES)
}

async function extractWithFallback(args: {
  mimoAPIKey: string
  mimoBaseURL: string
  kimiAPIKey: string
  kimiBaseURL: string
  sourceSentences: SourceSentence[]
}): Promise<{ ok: true; expressions: ExtractedExpression[] } | { ok: false; error: string }> {
  const prompt = buildExtractionPrompt(args.sourceSentences)
  const mimoResult = await requestCompletion(
    args.mimoBaseURL,
    { "Content-Type": "application/json", "api-key": args.mimoAPIKey },
    {
      model: "mimo-v2.5",
      messages: [
        { role: "system", content: "You are MiMo, an AI assistant developed by Xiaomi." },
        { role: "user", content: prompt },
      ],
      max_completion_tokens: 2048,
    },
    MIMO_TIMEOUT_MS
  )
  if (mimoResult.ok) return mimoResult

  console.error("[extract-study-topic-expressions] MiMo fallback", mimoResult.error)
  const kimiResult = await requestCompletion(
    args.kimiBaseURL,
    { "Content-Type": "application/json", Authorization: `Bearer ${args.kimiAPIKey}` },
    {
      model: "kimi-k2.5",
      messages: [
        { role: "system", content: "你是 Kimi，由 Moonshot AI 提供的人工智能助手。" },
        { role: "user", content: prompt },
      ],
      thinking: { type: "disabled" },
      max_completion_tokens: 2048,
    },
    KIMI_TIMEOUT_MS
  )
  return kimiResult
}

async function requestCompletion(
  url: string,
  headers: Record<string, string>,
  body: unknown,
  timeoutMs: number
): Promise<{ ok: true; expressions: ExtractedExpression[] } | { ok: false; error: string }> {
  try {
    const response = await fetchWithTimeout(url, {
      method: "POST",
      headers,
      body: JSON.stringify(body),
    }, timeoutMs)
    const rawText = await response.text()
    if (!response.ok) {
      return { ok: false, error: `HTTP ${response.status}: ${rawText.slice(0, 300)}` }
    }

    const payload = JSON.parse(rawText)
    const content = payload?.choices?.[0]?.message?.content
    const expressions = parseExpressions(content)
    return expressions
      ? { ok: true, expressions }
      : { ok: false, error: "Invalid model expression response" }
  } catch (error) {
    return { ok: false, error: error instanceof Error ? error.message : String(error) }
  }
}

function buildExtractionPrompt(sentences: SourceSentence[]): string {
  return `You are curating useful language from a user's personal study topic.

Read the source sentences below. Return only high-value, reusable English vocabulary and natural phrases that repeat across at least two DIFFERENT source sentences. Do not include articles, pronouns, auxiliary verbs, generic grammar words, isolated prepositions, names, or one-off details.

Return a JSON object only, with this exact shape:
{"expressions":[{"kind":"word","english":"...","chinese":"...","part_of_speech":"n.","sentence_ids":["uuid","uuid"]},{"kind":"phrase","english":"...","chinese":"...","part_of_speech":"","sentence_ids":["uuid","uuid"]}]}

Rules:
1. "kind" is exactly "word" or "phrase".
2. Return at most ${MAX_EXPRESSIONS_PER_KIND} words and ${MAX_EXPRESSIONS_PER_KIND} phrases.
3. Chinese definitions must be concise and natural.
4. sentence_ids must reference only the source sentence IDs below; each item needs 2 or 3 different IDs.
5. A word or phrase must genuinely occur in every sentence ID you give it, allowing only basic inflection changes for single words.
6. Omit a category instead of inventing weak items.

Source sentences:
${sentences.map((sentence) => `ID: ${sentence.id}\nEnglish: ${sentence.english}\nChinese: ${sentence.chinese}`).join("\n\n")}`
}

function parseExpressions(content: unknown): ExtractedExpression[] | null {
  if (typeof content !== "string") return null
  const normalized = content.trim().replace(/^```json\s*/i, "").replace(/^```\s*/i, "").replace(/\s*```$/, "")
  const start = normalized.indexOf("{")
  const end = normalized.lastIndexOf("}")
  const candidate = start >= 0 && end > start ? normalized.slice(start, end + 1) : normalized
  try {
    const value = JSON.parse(candidate)
    return Array.isArray(value?.expressions) ? value.expressions : null
  } catch {
    return null
  }
}

function sanitizeExpressions(
  extracted: ExtractedExpression[],
  sourceSentences: SourceSentence[]
): ExtractedExpression[] {
  const byID = new Map(sourceSentences.map((sentence) => [sentence.id, sentence]))
  const seen = new Set<string>()
  const counts: Record<ExpressionKind, number> = { word: 0, phrase: 0 }

  return extracted.flatMap((item) => {
    const kind: ExpressionKind | null = item?.kind === "word" || item?.kind === "phrase" ? item.kind : null
    const english = typeof item?.english === "string" ? item.english.trim().replace(/\s+/g, " ") : ""
    const chinese = typeof item?.chinese === "string" ? item.chinese.trim() : ""
    const partOfSpeech = typeof item?.part_of_speech === "string" ? item.part_of_speech.trim() : ""
    const sentenceIDs = Array.from(new Set(
      Array.isArray(item?.sentence_ids)
        ? item.sentence_ids.filter((id: unknown): id is string => typeof id === "string" && byID.has(id))
        : []
    )).slice(0, 3)
    const key = `${kind ?? ""}|${english.toLocaleLowerCase()}`

    if (!kind || !english || english.length > 120 || !chinese || chinese.length > 120 || sentenceIDs.length < 2 || seen.has(key) || counts[kind] >= MAX_EXPRESSIONS_PER_KIND) {
      return []
    }
    if (!sentenceIDs.every((id) => expressionOccursInSentence(english, byID.get(id)?.english ?? "", kind))) {
      return []
    }

    seen.add(key)
    counts[kind] += 1
    return [{
      kind,
      english,
      chinese,
      ...(partOfSpeech ? { part_of_speech: partOfSpeech } : {}),
      occurrence_count: sentenceIDs.length,
      sentence_ids: sentenceIDs,
    }]
  })
}

function makeTransientExpressions(
  expressions: ExtractedExpression[],
  sourceSentences: SourceSentence[]
) {
  const sentencesByID = new Map(sourceSentences.map((sentence) => [sentence.id, sentence]))
  return expressions.map((expression) => ({
    id: crypto.randomUUID(),
    kind: expression.kind,
    english: expression.english,
    chinese: expression.chinese,
    part_of_speech: expression.part_of_speech ?? null,
    occurrence_count: expression.occurrence_count,
    examples: expression.sentence_ids
      .map((id) => sentencesByID.get(id))
      .filter((sentence): sentence is SourceSentence => Boolean(sentence)),
  }))
}

function expressionOccursInSentence(expression: string, sentence: string, kind: ExpressionKind): boolean {
  const escaped = expression.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
  if (kind === "phrase") {
    return new RegExp(`\\b${escaped}\\b`, "i").test(sentence)
  }
  const stem = expression.toLocaleLowerCase().replace(/(?:ing|ed|es|s)$/i, "")
  const wordPattern = stem.length >= 4 ? `${stem}(?:s|es|ed|ing)?` : escaped
  return new RegExp(`\\b${wordPattern}\\b`, "i").test(sentence)
}

function isValidTopicKey(value: string): boolean {
  return value === "favorites" || /^scene:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value)
}

async function sha256(value: string): Promise<string> {
  const bytes = new TextEncoder().encode(value)
  const digest = await crypto.subtle.digest("SHA-256", bytes)
  return Array.from(new Uint8Array(digest))
    .map((value) => value.toString(16).padStart(2, "0"))
    .join("")
}

async function fetchWithTimeout(input: string, init: RequestInit, timeoutMs: number): Promise<Response> {
  const controller = new AbortController()
  const timeout = setTimeout(() => controller.abort(), timeoutMs)
  try {
    return await fetch(input, { ...init, signal: controller.signal })
  } finally {
    clearTimeout(timeout)
  }
}

function jsonResponse(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "Content-Type": "application/json; charset=utf-8" },
  })
}
