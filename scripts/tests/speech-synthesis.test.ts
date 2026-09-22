import { deepStrictEqual, strictEqual, throws, rejects, ok } from "node:assert";
import { createSpeechHandler, type SpeechDependencies } from "../../supabase/functions/synthesize-speech/handler.ts";
import { readMiMoAudio, speechRequest, validateSpeechText } from "../../supabase/functions/synthesize-speech/speech.ts";

const encoder = new TextEncoder();
const audioEvent = (data = "AAABAA==") => `data: ${JSON.stringify({ choices: [{ delta: { audio: { data } } }] })}\n\n`;
const complete = audioEvent() + "data: [DONE]\n\n";
function body(text: string, fragmented = false) {
  return new ReadableStream<Uint8Array>({ start(output) {
    if (fragmented) for (const character of text) output.enqueue(encoder.encode(character));
    else output.enqueue(encoder.encode(text));
    output.close();
  } });
}
async function collect(text: string, fragmented = false) {
  const chunks: string[] = [];
  for await (const chunk of readMiMoAudio(body(text, fragmented))) chunks.push(chunk);
  return chunks;
}
function request(text = "This is a test.") {
  return new Request("https://app.invalid/speech", {
    method: "POST", headers: { Authorization: "Bearer token" }, body: JSON.stringify({ text }),
  });
}
function dependencies(overrides: Partial<SpeechDependencies> = {}): SpeechDependencies {
  return {
    url: "https://provider.invalid/chat/completions", apiKey: "server-only-secret",
    authenticate: () => Promise.resolve("user-id"), consumeBudget: () => Promise.resolve(true),
    fetcher: (() => Promise.resolve(new Response(body(complete)))) as typeof fetch,
    ...overrides,
  };
}

Deno.test("speech request uses assistant text, English voice and streaming PCM", () => {
  const value = speechRequest("It's 3.14 miles.");
  strictEqual(value.model, "mimo-v2.5-tts");
  strictEqual(value.stream, true);
  deepStrictEqual(value.audio, { format: "pcm16", voice: "Mia" });
  deepStrictEqual(value.messages[1], { role: "assistant", content: "It's 3.14 miles." });
});

Deno.test("speech text is bounded without rewriting the sentence", () => {
  strictEqual(validateSpeechText({ text: "  It's 3.14 miles.  " }), "It's 3.14 miles.");
  for (const input of [null, {}, { text: 3 }, { text: " " }, { text: "a".repeat(501) }]) {
    throws(() => validateSpeechText(input));
  }
});

Deno.test("fragmented SSE and CRLF produce complete PCM chunks", async () => {
  deepStrictEqual(await collect(complete, true), ["AAABAA=="]);
  deepStrictEqual(await collect((audioEvent() + complete).replaceAll("\n", "\r\n")), ["AAABAA==", "AAABAA=="]);
});

Deno.test("SSE rejects empty, truncated, invalid and oversized audio", async () => {
  for (const value of ["", audioEvent(), "data: [DONE]\n\n", audioEvent("!") + "data: [DONE]\n\n",
    audioEvent("AA==") + "data: [DONE]\n\n", 'data: {"error":"failed"}\n\n',
    'data: {"choices":[{"finish_reason":"length"}]}\n\n', "data: " + "x".repeat(512_001) + "\n\n"]) {
    await rejects(() => collect(value));
  }
  const chunk = audioEvent(btoa("\0".repeat(100_000)));
  await rejects(() => collect(chunk.repeat(30) + "data: [DONE]\n\n"));
});

Deno.test("endpoint validates auth, body and quota before any model call", async () => {
  let calls = 0;
  const fetcher = (() => { calls++; throw new Error("unexpected call"); }) as typeof fetch;
  strictEqual((await createSpeechHandler(dependencies({ fetcher }))(new Request("https://app.invalid"))).status, 405);
  strictEqual((await createSpeechHandler(dependencies({ fetcher }))(new Request("https://app.invalid", { method: "POST" }))).status, 401);
  strictEqual((await createSpeechHandler(dependencies({ fetcher, authenticate: () => Promise.resolve(null) }))(request())).status, 401);
  strictEqual((await createSpeechHandler(dependencies({ fetcher }))(request(" "))).status, 400);
  strictEqual((await createSpeechHandler(dependencies({ fetcher }))(request("x".repeat(5000)))).status, 413);
  strictEqual((await createSpeechHandler(dependencies({ fetcher, consumeBudget: () => Promise.resolve(false) }))(request())).status, 429);
  strictEqual(calls, 0);
});

Deno.test("endpoint keeps model credentials server-side and forwards only audio", async () => {
  const result = await createSpeechHandler(dependencies({ fetcher: (async (url: string | URL | Request, init?: RequestInit) => {
    strictEqual(url, "https://provider.invalid/chat/completions");
    strictEqual(new Headers(init?.headers).get("api-key"), "server-only-secret");
    strictEqual(JSON.parse(String(init?.body)).messages[1].content, "This is a test.");
    return new Response(body(complete));
  }) as typeof fetch }))(request());
  strictEqual(result.status, 200);
  strictEqual(result.headers.get("X-Accel-Buffering"), "no");
  deepStrictEqual((await result.text()).trim().split("\n").map((line) => JSON.parse(line)), [
    { type: "audio", data: "AAABAA==" }, { type: "done" },
  ]);
});

Deno.test("partial upstream failure never advertises a complete cacheable result", async () => {
  const result = await createSpeechHandler(dependencies({
    fetcher: (() => Promise.resolve(new Response(body(audioEvent())))) as typeof fetch,
  }))(request());
  const output = await result.text();
  ok(output.includes('"type":"error"'));
  ok(!output.includes('"type":"done"'));
});

Deno.test("deadline covers a provider stalled after response headers", async () => {
  const result = await createSpeechHandler(dependencies({ timeoutMs: 10,
    fetcher: (async (_url: string | URL | Request, init?: RequestInit) => new Response(new ReadableStream({ start(output) {
      output.enqueue(encoder.encode(audioEvent()));
      init?.signal?.addEventListener("abort", () => output.error(new Error("aborted")), { once: true });
    } }))) as typeof fetch,
  }))(request());
  ok((await result.text()).includes('"type":"error"'));
});

Deno.test("downstream cancellation aborts provider work", async () => {
  let cancelled = false;
  const result = await createSpeechHandler(dependencies({
    fetcher: (async (_url: string | URL | Request, init?: RequestInit) => new Response(new ReadableStream({ start(output) {
      output.enqueue(encoder.encode(audioEvent()));
      init?.signal?.addEventListener("abort", () => { cancelled = true; output.error(new Error("aborted")); }, { once: true });
    } }))) as typeof fetch,
  }))(request());
  const reader = result.body!.getReader();
  await reader.read();
  await reader.cancel();
  strictEqual(cancelled, true);
});

Deno.test("a stalled request body cannot retain the handler indefinitely", async () => {
  const stalled = new Request("https://app.invalid", { method: "POST", headers: { Authorization: "Bearer token" },
    body: new ReadableStream({ start(output) { output.enqueue(encoder.encode('{"text":')); } }),
  });
  strictEqual((await createSpeechHandler(dependencies({ timeoutMs: 10 }))(stalled)).status, 503);
});

Deno.test("speech migration is private and independent of generation credits", async () => {
  const sql = await Deno.readTextFile(new URL("../../supabase/migrations/20260922000000_add_speech_request_limits.sql", import.meta.url));
  ok(sql.includes("on conflict (user_id) do update"));
  ok(sql.includes("minute_count < 20"));
  ok(sql.includes("day_count < 300"));
  ok(sql.includes("revoke all on function public.consume_speech_request(uuid) from public, anon, authenticated"));
  ok(!sql.includes("available_generations"));
});
