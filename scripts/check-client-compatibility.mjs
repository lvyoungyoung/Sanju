#!/usr/bin/env node

import { randomUUID } from "node:crypto"
import { readFileSync } from "node:fs"
import { dirname, resolve } from "node:path"
import { fileURLToPath } from "node:url"

const scriptDir = dirname(fileURLToPath(import.meta.url))
const repoRoot = resolve(scriptDir, "..")

const args = parseArgs(process.argv.slice(2))
const targetEnvironment = args.env ?? process.env.SANJU_COMPAT_ENV ?? "staging"
const allowProduction = process.env.SANJU_COMPAT_ALLOW_PRODUCTION === "1"
const config = loadConfig(targetEnvironment)
const baseURL = trimTrailingSlash(args.baseUrl ?? process.env.SANJU_COMPAT_BASE_URL ?? config.url)
const anonKey = args.anonKey ?? process.env.SANJU_COMPAT_ANON_KEY ?? config.anonKey
const parsedTimeoutMs = Number.parseInt(process.env.SANJU_COMPAT_TIMEOUT_MS ?? "30000", 10)
const requestTimeoutMs = Number.isFinite(parsedTimeoutMs) ? parsedTimeoutMs : 30000
const runID = new Date().toISOString().replace(/[-:.TZ]/g, "").slice(0, 14)
const state = {
  accessToken: null,
  refreshToken: null,
  userID: null,
  profile: null,
}

if (!baseURL || !anonKey) {
  failFast("Missing Supabase URL or anon key. Use staging config or set SANJU_COMPAT_BASE_URL and SANJU_COMPAT_ANON_KEY.")
}

if (targetEnvironment === "production" && !allowProduction) {
  failFast("Refusing to run against production. Set SANJU_COMPAT_ALLOW_PRODUCTION=1 only if you intentionally want production smoke tests.")
}

if (!baseURL.includes("spb-") && !allowProduction) {
  failFast(`Unexpected Supabase URL: ${baseURL}`)
}

const tests = [
  ["anonymous auth returns a client-compatible session", testAnonymousAuth],
  ["current user endpoint returns the same user id", testCurrentUser],
  ["refresh token endpoint returns a renewed session", testRefreshSession],
  ["profile upsert returns required profile fields", testProfileUpsert],
  ["profile fetch returns required profile fields", testProfileFetch],
  ["profile patch keeps preferences writable", testProfilePatch],
  ["anonymous starter credits can only move downward", testAnonymousStarterCreditPatch],
  ["memory list endpoint supports paged reads", testMemoryList],
  ["memory and favorite counters remain readable", testCounters],
  ["study count RPCs return numbers", testStudyCountRPCs],
  ["study queue RPCs return arrays", testStudyQueueRPCs],
  ["guest generation recovery returns recovered=false for missing job", testRecoverMissingGuestJob],
  ["generate-memory-v2 rejects missing image without consuming a real generation", testGenerateMissingImageContract],
  ["purchase function rejects missing auth before App Store validation", testConfirmPurchaseMissingAuth],
]

console.log(`Sanju old-client compatibility check`)
console.log(`Target: ${targetEnvironment}`)
console.log(`Base URL: ${baseURL}`)
console.log("")

let failed = 0
for (const [name, fn] of tests) {
  try {
    await fn()
    console.log(`PASS ${name}`)
  } catch (error) {
    failed += 1
    console.error(`FAIL ${name}`)
    console.error(`     ${error.message}`)
  }
}

console.log("")
if (failed > 0) {
  console.error(`${failed}/${tests.length} compatibility checks failed.`)
  process.exit(1)
}

console.log(`${tests.length}/${tests.length} compatibility checks passed.`)

async function testAnonymousAuth() {
  const response = await requestJSON("/auth/v1/signup", {
    method: "POST",
    body: {
      data: {
        compat_test: "true",
        compat_run_id: runID,
      },
    },
  })

  expectStatus(response, [200, 201])
  assertString(response.data?.access_token, "access_token")
  assertString(response.data?.refresh_token, "refresh_token")
  assertNumber(response.data?.expires_in, "expires_in")
  assertString(response.data?.user?.id, "user.id")
  assert(response.data?.user?.is_anonymous === true, "user.is_anonymous should be true")

  state.accessToken = response.data.access_token
  state.refreshToken = response.data.refresh_token
  state.userID = response.data.user.id
}

async function testCurrentUser() {
  const response = await requestJSON("/auth/v1/user", {
    method: "GET",
    bearerToken: state.accessToken,
  })

  expectStatus(response, 200)
  assert(response.data?.id === state.userID, "current user id does not match anonymous session")
}

async function testRefreshSession() {
  const response = await requestJSON("/auth/v1/token?grant_type=refresh_token", {
    method: "POST",
    body: {
      refresh_token: state.refreshToken,
    },
  })

  expectStatus(response, 200)
  assertString(response.data?.access_token, "access_token")
  assertString(response.data?.refresh_token, "refresh_token")
  assert(response.data?.user?.id === state.userID, "refreshed user id does not match original session")

  state.accessToken = response.data.access_token
  state.refreshToken = response.data.refresh_token
}

async function testProfileUpsert() {
  const nickname = `compat_${runID}`
  const response = await requestJSON("/rest/v1/profiles?on_conflict=id", {
    method: "POST",
    bearerToken: state.accessToken,
    headers: {
      Prefer: "return=representation,resolution=merge-duplicates",
    },
    body: [
      {
        id: state.userID,
        apple_user_id: `anonymous:${state.userID}`,
        nickname,
        email: null,
        english_level: "简单",
        language_style: "平铺直叙",
        available_generations: 5,
      },
    ],
  })

  expectStatus(response, [200, 201])
  assert(Array.isArray(response.data), "profile upsert response should be an array")
  const profile = response.data[0]
  assertProfileShape(profile)
  assert(profile.id === state.userID, "profile.id does not match session user id")
  assert(profile.nickname === nickname, "profile.nickname was not returned")
  assert(profile.available_generations >= 0 && profile.available_generations <= 5, "anonymous profile balance should be capped to starter credits")

  state.profile = profile
}

async function testProfileFetch() {
  const select = encodeURIComponent("id,apple_user_id,nickname,email,english_level,language_style,available_generations")
  const response = await requestJSON(`/rest/v1/profiles?id=eq.${state.userID}&select=${select}`, {
    method: "GET",
    bearerToken: state.accessToken,
  })

  expectStatus(response, 200)
  assert(Array.isArray(response.data), "profile fetch response should be an array")
  assertProfileShape(response.data[0])
}

async function testProfilePatch() {
  const nickname = `compat_${runID}_p`
  const response = await requestJSON(`/rest/v1/profiles?id=eq.${state.userID}`, {
    method: "PATCH",
    bearerToken: state.accessToken,
    headers: {
      Prefer: "return=representation",
    },
    body: {
      nickname,
      english_level: "中等",
      language_style: "抒情优美",
    },
  })

  expectStatus(response, 200)
  assert(Array.isArray(response.data), "profile patch response should be an array")
  const profile = response.data[0]
  assertProfileShape(profile)
  assert(profile.nickname === nickname, "profile.nickname was not patched")
  assert(profile.english_level === "中等", "profile.english_level was not patched")
  assert(profile.language_style === "抒情优美", "profile.language_style was not patched")
  state.profile = profile
}

async function testAnonymousStarterCreditPatch() {
  const current = state.profile?.available_generations
  assertNumber(current, "state.profile.available_generations")
  const nextBalance = Math.max(current - 1, 0)
  const response = await requestJSON(`/rest/v1/profiles?id=eq.${state.userID}`, {
    method: "PATCH",
    bearerToken: state.accessToken,
    headers: {
      Prefer: "return=representation",
    },
    body: {
      available_generations: nextBalance,
    },
  })

  expectStatus(response, 200)
  const profile = response.data?.[0]
  assertProfileShape(profile)
  assert(profile.available_generations === nextBalance, "anonymous balance should be allowed to move downward")
  state.profile = profile
}

async function testMemoryList() {
  const select = encodeURIComponent("id,image_url,created_at,memory_sentences(id,sort_order,english,chinese,is_favorite)")
  const response = await requestJSON(`/rest/v1/memories?select=${select}&order=created_at.desc`, {
    method: "GET",
    bearerToken: state.accessToken,
    headers: {
      "Range-Unit": "items",
      Range: "0-99",
    },
  })

  expectStatus(response, [200, 206])
  assert(Array.isArray(response.data), "memories response should be an array")
  for (const memory of response.data) {
    assertMemoryShape(memory)
  }
}

async function testCounters() {
  const memoryCount = await requestJSON("/rest/v1/memories?select=id", {
    method: "GET",
    bearerToken: state.accessToken,
    headers: {
      Prefer: "count=exact",
      "Range-Unit": "items",
      Range: "0-0",
    },
  })
  expectStatus(memoryCount, [200, 206])
  assertContentRange(memoryCount.headers.get("content-range"), "memories content-range")

  const select = encodeURIComponent("id,memories!inner(id)")
  const favoriteCount = await requestJSON(`/rest/v1/memory_sentences?select=${select}&is_favorite=eq.true&memories.user_id=eq.${state.userID}`, {
    method: "GET",
    bearerToken: state.accessToken,
    headers: {
      Prefer: "count=exact",
      "Range-Unit": "items",
      Range: "0-0",
    },
  })
  expectStatus(favoriteCount, [200, 206])
  assertContentRange(favoriteCount.headers.get("content-range"), "favorites content-range")
}

async function testStudyCountRPCs() {
  for (const path of [
    "/rest/v1/rpc/count_sentence_study_queue",
    "/rest/v1/rpc/count_sentence_studied_today",
    "/rest/v1/rpc/count_sentence_studied_today_reviewable",
  ]) {
    const response = await requestJSON(path, {
      method: "POST",
      bearerToken: state.accessToken,
    })
    expectStatus(response, 200)
    assertNumber(response.data, path)
  }
}

async function testStudyQueueRPCs() {
  for (const path of [
    "/rest/v1/rpc/get_sentence_study_queue",
    "/rest/v1/rpc/get_sentence_studied_today_queue",
  ]) {
    const response = await requestJSON(path, {
      method: "POST",
      bearerToken: state.accessToken,
      body: {
        p_limit: 30,
      },
    })
    expectStatus(response, 200)
    assert(Array.isArray(response.data), `${path} response should be an array`)
    for (const item of response.data) {
      assertStudyQueueShape(item)
    }
  }
}

async function testRecoverMissingGuestJob() {
  const response = await requestJSON("/functions/v1/recover-guest-generation", {
    method: "POST",
    bearerToken: state.accessToken,
    body: {
      guestJobID: randomUUID(),
    },
  })

  expectStatus(response, 200)
  assert(response.data?.recovered === false, "missing guest job should return recovered=false")
}

async function testGenerateMissingImageContract() {
  const response = await requestJSON("/functions/v1/generate-memory-v2", {
    method: "POST",
    bearerToken: state.accessToken,
    body: {
      englishLevel: "简单",
      languageStyle: "平铺直叙",
      guestJobID: randomUUID(),
    },
  })

  expectStatus(response, 400)
  assertAPIErrorShape(response.data)
}

async function testConfirmPurchaseMissingAuth() {
  const response = await requestJSON("/functions/v1/confirm-purchase", {
    method: "POST",
    body: {
      transactionID: "",
      productID: "",
    },
  })

  expectStatus(response, 401)
  assertAPIErrorShape(response.data)
}

async function requestJSON(path, options = {}) {
  const url = `${baseURL}${path}`
  const controller = new AbortController()
  const timeout = setTimeout(() => controller.abort(), requestTimeoutMs)
  const headers = {
    apikey: anonKey,
    "Content-Type": "application/json",
    ...(options.headers ?? {}),
  }

  if (options.bearerToken) {
    headers.Authorization = `Bearer ${options.bearerToken}`
  }

  let response
  try {
    response = await fetch(url, {
      method: options.method ?? "GET",
      headers,
      signal: controller.signal,
      body: options.body === undefined ? undefined : JSON.stringify(options.body),
    })
  } catch (error) {
    const reason = error instanceof Error ? error.message : String(error)
    throw new Error(`Request failed: ${options.method ?? "GET"} ${url}: ${reason}`)
  } finally {
    clearTimeout(timeout)
  }

  const text = await response.text()
  let data = null
  if (text.trim()) {
    try {
      data = JSON.parse(text)
    } catch {
      data = text
    }
  }

  return {
    response,
    status: response.status,
    headers: response.headers,
    data,
    text,
  }
}

function expectStatus(result, expected) {
  const expectedList = Array.isArray(expected) ? expected : [expected]
  if (!expectedList.includes(result.status)) {
    const body = typeof result.data === "string" ? result.data : JSON.stringify(result.data)
    throw new Error(`Expected HTTP ${expectedList.join(" or ")}, got ${result.status}. Body: ${body}`)
  }
}

function assertProfileShape(profile) {
  assert(profile && typeof profile === "object", "profile should be an object")
  assertString(profile.id, "profile.id")
  assertString(profile.nickname, "profile.nickname")
  assertString(profile.english_level, "profile.english_level")
  assertString(profile.language_style, "profile.language_style")
  assertNumber(profile.available_generations, "profile.available_generations")
}

function assertMemoryShape(memory) {
  assertString(memory?.id, "memory.id")
  assertString(memory?.image_url, "memory.image_url")
  assertString(memory?.created_at, "memory.created_at")
  assert(Array.isArray(memory?.memory_sentences), "memory.memory_sentences should be an array")
  for (const sentence of memory.memory_sentences) {
    assertString(sentence.id, "sentence.id")
    assertNumber(sentence.sort_order, "sentence.sort_order")
    assertString(sentence.english, "sentence.english")
    assertString(sentence.chinese, "sentence.chinese")
    assert(typeof sentence.is_favorite === "boolean", "sentence.is_favorite should be boolean")
  }
}

function assertStudyQueueShape(item) {
  assertString(item?.sentence_id, "study.sentence_id")
  assertString(item?.memory_id, "study.memory_id")
  assertString(item?.english, "study.english")
  assertString(item?.chinese, "study.chinese")
  assertString(item?.created_at ?? item?.memory_created_at, "study.created_at")
  assertNumber(item?.learning_step, "study.learning_step")
  assertNumber(item?.mastered_review_count, "study.mastered_review_count")
  assertNumber(item?.correct_count, "study.correct_count")
  assertNumber(item?.wrong_count, "study.wrong_count")
}

function assertContentRange(value, label) {
  assertString(value, label)
  assert(value.includes("/"), `${label} should include total count separator`)
}

function assertAPIErrorShape(value) {
  assert(value && typeof value === "object", "error response should be an object")
  const message = value.message ?? value.error_description ?? value.error ?? value.msg ?? value.code
  assertString(message, "error/message/msg/code")
}

function assertString(value, label) {
  assert(typeof value === "string" && value.length > 0, `${label} should be a non-empty string`)
}

function assertNumber(value, label) {
  assert(typeof value === "number" && Number.isFinite(value), `${label} should be a finite number`)
}

function assert(condition, message) {
  if (!condition) {
    throw new Error(message)
  }
}

function parseArgs(argv) {
  const parsed = {}
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index]
    if (arg === "--env") {
      parsed.env = argv[++index]
    } else if (arg === "--base-url") {
      parsed.baseUrl = argv[++index]
    } else if (arg === "--anon-key") {
      parsed.anonKey = argv[++index]
    } else if (arg === "--help" || arg === "-h") {
      printHelp()
      process.exit(0)
    } else {
      failFast(`Unknown argument: ${arg}`)
    }
  }
  return parsed
}

function loadConfig(envName) {
  const plistName = envName === "production" ? "Config.plist" : "Config.staging.plist"
  const plistPath = resolve(repoRoot, "三句", plistName)
  try {
    const plist = readFileSync(plistPath, "utf8")
    return {
      url: readPlistString(plist, "SupabaseURL"),
      anonKey: readPlistString(plist, "SupabasePublishableKey"),
    }
  } catch (error) {
    return {
      url: "",
      anonKey: "",
    }
  }
}

function readPlistString(plist, key) {
  const escapedKey = key.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
  const match = plist.match(new RegExp(`<key>\\s*${escapedKey}\\s*</key>\\s*<string>([^<]+)</string>`))
  return match?.[1]?.trim() ?? ""
}

function trimTrailingSlash(value) {
  return value?.replace(/\/+$/, "") ?? ""
}

function failFast(message) {
  console.error(message)
  process.exit(1)
}

function printHelp() {
  console.log(`
Usage:
  node scripts/check-client-compatibility.mjs [--env staging]

Options:
  --env staging|production   Defaults to staging. Production requires SANJU_COMPAT_ALLOW_PRODUCTION=1.
  --base-url URL             Override Supabase API URL.
  --anon-key KEY             Override Supabase anon/publishable key.

Environment overrides:
  SANJU_COMPAT_ENV
  SANJU_COMPAT_BASE_URL
  SANJU_COMPAT_ANON_KEY
  SANJU_COMPAT_ALLOW_PRODUCTION=1
`.trim())
}
