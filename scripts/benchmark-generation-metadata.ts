// Direct model benchmark only: no Supabase requests, persisted memories or credit changes.
import { Buffer } from "node:buffer";
import { fetchWithTimeout } from "../supabase/functions/_shared/fetch-with-timeout.ts";
import {
  buildSentenceMetadataPrompt,
  buildSentenceMetadataRules,
  generateSentenceMetadata,
  parseSentenceMetadata,
} from "../supabase/functions/_shared/sentence-metadata.ts";

import * as generation from "../supabase/functions/generate-memory-v2/content.ts";

const root = new URL("../", import.meta.url);
const generationSource = await Deno.readTextFile(new URL("supabase/functions/generate-memory-v2/content.ts", root));

export function buildBenchmarkPrompts(level = "简单") {
  const combined: string = generation.buildPromptText(level as Parameters<typeof generation.buildPromptText>[0], "dual_tabs_v1");
  const metadata = buildSentenceMetadataPrompt();
  const rules = buildSentenceMetadataRules() + "\n\n";
  const exampleStart = combined.lastIndexOf("\n{");
  const fieldRule = "每一项必须且只能包含 english、chinese、learning_topic_ids 和 expression_purpose 四个字段";
  if (exampleStart < 0 || !combined.includes(rules) || !combined.includes(fieldRule)) {
    throw new Error("Prompt layout changed; update the benchmark before running");
  }
  const example = JSON.parse(combined.slice(exampleStart));
  for (const group of ["image_descriptions", "scene_and_feelings"]) {
    for (const sentence of example[group]) {
      delete sentence.learning_topic_ids;
      delete sentence.expression_purpose;
    }
  }
  const separate = combined.slice(0, exampleStart)
    .replace(fieldRule, "每一项必须且只能包含 english 和 chinese 两个字段")
    .replace(rules, "") +
    "\n" + JSON.stringify(example);
  return { combined, separate, metadata };
}

export function imageRequest(prompt: string, base64: string) {
  return {
    model: "mimo-v2.6-flash",
    messages: [
      { role: "system", content: "You are MiMo, an AI assistant developed by Xiaomi." },
      { role: "user", content: [
        { type: "image_url", image_url: { url: `data:image/jpeg;base64,${base64}` } },
        { type: "text", text: prompt },
      ] },
    ],
    thinking: { type: "disabled" },
    max_completion_tokens: 4096,
  };
}

type Sentence = { id: string; english: string; chinese: string };
export function validateGeneration(content: string, combined: boolean): Sentence[] {
  const result = generation.parseGeneratedContent(content, "dual_tabs_v1");
  const raw = generation.parseJSONObject(content);
  if (!result || !raw || result.sentences.length !== 6) throw new Error("Invalid generation output");
  const sentences = result.sentences.map((s) => ({ id: crypto.randomUUID(), english: s.english, chinese: s.chinese }));
  if (combined) {
    const items: Record<string, unknown>[] = [...raw.image_descriptions, ...raw.scene_and_feelings];
    parseSentenceMetadata(items.map((s, i) => ({ ...s, sentence_id: sentences[i].id })), sentences);
  }
  return sentences;
}

type Stage = { ms: number; status: "success" | "failed"; httpStatus?: number; error?: string; usage?: Record<string, number>; content?: string };
type Trial = { variant: "combined" | "separate"; sample: number; round: number; stages: Stage[]; sentenceReadyMs?: number; totalMs: number; success: boolean };
const roundMS = (ms: number) => Math.round(ms * 10) / 10;
export function stats(values: number[]) {
  if (!values.length) return null;
  const sorted = [...values].sort((a, b) => a - b);
  const mid = Math.floor(sorted.length / 2);
  return {
    count: sorted.length,
    medianMs: roundMS(sorted.length % 2 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2),
    meanMs: roundMS(sorted.reduce((a, b) => a + b, 0) / sorted.length),
    minMs: roundMS(sorted[0]), maxMs: roundMS(sorted.at(-1)!),
  };
}

function summarize(trials: Trial[]) {
  const paired = trials.filter((t) => t.success && trials.some((other) =>
    other.success && other.variant !== t.variant && other.sample === t.sample && other.round === t.round));
  return Object.fromEntries((["combined", "separate"] as const).map((variant) => {
    const own = trials.filter((t) => t.variant === variant);
    return [variant, {
      attempted: own.length,
      completed: own.filter((t) => t.success).length,
      sentenceReady: stats(own.flatMap((t) => t.sentenceReadyMs === undefined ? [] : [t.sentenceReadyMs])),
      allResultsReady: stats(own.filter((t) => t.success).map((t) => t.totalMs)),
      metadataOnly: stats(own.flatMap((t) => t.stages[1]?.status === "success" ? [t.stages[1].ms] : [])),
      pairedAllResultsReady: stats(paired.filter((t) => t.variant === variant).map((t) => t.totalMs)),
    }];
  }));
}

function usageOf(payload: any): Record<string, number> {
  return Object.fromEntries(Object.entries(payload?.usage ?? {}).filter(([, v]) => typeof v === "number" && Number.isFinite(v))) as Record<string, number>;
}

async function main() {
  const args = [...Deno.args];
  const option = (name: string, fallback: string) => {
    const index = args.indexOf(name);
    if (index < 0) return fallback;
    const value = args[index + 1];
    if (!value || value.startsWith("--")) throw new Error(`Missing ${name} value`);
    args.splice(index, 2);
    return value;
  };
  const rounds = Number(option("--rounds", "3"));
  const level = option("--level", "简单");
  const output = option("--output", "tmp/mimo-generation-benchmark/results.json");
  const dryRun = args.includes("--dry-run");
  const images = args.filter((arg) => arg !== "--dry-run");
  if (!Number.isInteger(rounds) || rounds < 1 || rounds > 5 || !["启蒙", "简单", "中等"].includes(level) || !images.length || images.length > 5 || images.some((p) => p.startsWith("--"))) {
    throw new Error("Usage: --rounds 1..5 --level 简单 --output tmp/report.json [--dry-run] image1.jpg [image2.jpg ...] (up to 5 images)");
  }
  const prompts = buildBenchmarkPrompts(level);
  const fixtures = await Promise.all(images.map(async (path, index) => {
    const bytes = await Deno.readFile(path);
    if (bytes[0] !== 0xff || bytes[1] !== 0xd8 || bytes.length > 45_000) throw new Error("Use compressed JPEG samples <= 45KB, matching the client analysis budget");
    const sha256 = Buffer.from(await crypto.subtle.digest("SHA-256", bytes)).toString("hex");
    return { sample: index + 1, bytes: bytes.length, sha256, base64: Buffer.from(bytes).toString("base64") };
  }));
  const report = {
    startedAt: new Date().toISOString(), model: "mimo-v2.6-flash", level, style: "平铺直叙", rounds,
    requestDeadlineMs: 20_000, automaticRetries: 0, maximumRequests: rounds * fixtures.length * 3,
    generationSourceSHA256: Buffer.from(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(generationSource))).toString("hex"),
    promptCharacters: { combined: prompts.combined.length, separate: prompts.separate.length, metadata: prompts.metadata.length },
    samples: fixtures.map(({ base64: _, ...info }) => info),
    note: "Direct local-to-MiMo wall times, including response body and validation. No moderation, database, embeddings or Kimi fallback. Separate metadata uses the current production helper. Successful-only and paired-success summaries exclude failed/time-limited trials; inspect failure counts. Order alternates, every round rotates image order. Output content is retained for quality review; keys and image bytes are never saved.",
    trials: [] as Trial[], summary: {} as Record<string, unknown>, finishedAt: null as string | null,
  };
  if (dryRun) { console.log(JSON.stringify({ ...report, dryRun: true }, null, 2)); return; }
  const key = Deno.env.get("MIMO_API_KEY"), url = Deno.env.get("MIMO_BASE_URL");
  if (!key || !url) throw new Error("Missing MIMO_API_KEY / MIMO_BASE_URL. Use --env-file=.env.benchmark.local (Git-ignored); never pass keys on the command line.");
  if (new URL(url).protocol !== "https:") throw new Error("MiMo URL must use HTTPS");
  const outputURL = new URL(output, new URL(`file://${Deno.cwd()}/`));
  await Deno.mkdir(new URL("./", outputURL), { recursive: true });
  const save = async () => {
    report.summary = summarize(report.trials);
    await Deno.writeTextFile(outputURL, JSON.stringify(report, null, 2) + "\n", { mode: 0o600 });
  };
  await save();
  console.log(`Real MiMo benchmark: ${fixtures.length} samples x ${rounds} rounds, at most ${report.maximumRequests} API requests. No app credits or database writes.`);
  let denied = false;
  const observingFetch = (stage: Stage): typeof fetch => async (input, init) => {
    const response = await fetch(input, init);
    stage.httpStatus = response.status;
    if (response.status === 401 || response.status === 403) denied = true;
    // The caller's deadline still covers reading and observing the response body.
    const bytes = await response.arrayBuffer();
    if (response.ok) {
      try {
        const payload = JSON.parse(new TextDecoder().decode(bytes));
        stage.usage = usageOf(payload);
        const content = payload?.choices?.[0]?.message?.content;
        if (typeof content === "string") stage.content = content;
      } catch { /* The production parser will report invalid content. */ }
    }
    return new Response(bytes, { status: response.status, headers: response.headers });
  };
  let pairIndex = 0;
  for (let round = 1; round <= rounds; round++) {
    for (let offset = 0; offset < fixtures.length; offset++) {
      const fixture = fixtures[(offset + round - 1) % fixtures.length];
      const variants = pairIndex++ % 2 ? ["separate", "combined"] as const : ["combined", "separate"] as const;
      for (const variant of variants) {
        const trial: Trial = { variant, sample: fixture.sample, round, stages: [], totalMs: 0, success: false };
        report.trials.push(trial);
        console.log(`START round=${round} sample=${fixture.sample} variant=${variant}`);
        const start = performance.now();
        let stageStart = start;
        let stage: Stage = { ms: 0, status: "failed" };
        trial.stages.push(stage);
        try {
          const response = await fetchWithTimeout(url, {
            method: "POST", headers: { "Content-Type": "application/json", "api-key": key },
            body: JSON.stringify(imageRequest(prompts[variant === "combined" ? "combined" : "separate"], fixture.base64)),
          }, 20_000, observingFetch(stage));
          if (!response.ok) throw new Error(`Model HTTP ${response.status}`);
          const payload = await response.json();
          const content = payload?.choices?.[0]?.message?.content;
          if (typeof content !== "string") throw new Error("Missing model content");
          const sentences = validateGeneration(content, variant === "combined");
          stage.status = "success";
          stage.ms = roundMS(performance.now() - stageStart);
          trial.sentenceReadyMs = roundMS(performance.now() - start);
          console.log(`SENTENCES ${variant} ms=${trial.sentenceReadyMs}`);
          if (variant === "separate") {
            stage = { ms: 0, status: "failed" };
            trial.stages.push(stage);
            stageStart = performance.now();
            await generateSentenceMetadata(sentences, observingFetch(stage), { key, url });
            stage.status = "success";
            stage.ms = roundMS(performance.now() - stageStart);
          }
          trial.success = true;
        } catch (error) {
          stage.ms = roundMS(performance.now() - stageStart);
          // Raw network errors may contain the configured URL; do not log them.
          stage.error = error instanceof DOMException && error.name === "AbortError"
            ? "timeout"
            : stage.httpStatus && stage.httpStatus >= 400
            ? `HTTP ${stage.httpStatus}`
            : "request_or_output_validation_failed";
        }
        trial.totalMs = roundMS(performance.now() - start);
        await save();
        console.log(`END round=${round} sample=${fixture.sample} variant=${variant} success=${trial.success} totalMs=${trial.totalMs}`);
        if (denied) throw new Error("MiMo rejected credentials or permissions; stopped without further requests");
        await new Promise((resolve) => setTimeout(resolve, 500));
      }
    }
  }
  report.finishedAt = new Date().toISOString();
  await save();
  console.log(JSON.stringify(report.summary, null, 2));
  console.log(`Saved ${output}`);
}

if (import.meta.main) await main();
