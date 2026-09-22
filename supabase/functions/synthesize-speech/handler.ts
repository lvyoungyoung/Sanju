import { readMiMoAudio, speechRequest, validateSpeechText } from "./speech.ts";

export interface SpeechDependencies {
  url: string;
  apiKey: string;
  authenticate(token: string): Promise<string | null>;
  consumeBudget(userID: string): Promise<boolean>;
  fetcher?: typeof fetch;
  timeoutMs?: number;
}

export function createSpeechHandler(deps: SpeechDependencies) {
  return async (req: Request): Promise<Response> => {
    const jsonError = (code: string, status: number) => Response.json({ error: code }, { status });
    if (req.method !== "POST") return jsonError("method_not_allowed", 405);
    const token = req.headers.get("Authorization")?.match(/^Bearer\s+(\S+)$/i)?.[1];
    if (!token) return jsonError("unauthorized", 401);
    if (!deps.url || !deps.apiKey) return jsonError("speech_not_configured", 503);

    const controller = new AbortController();
    const abort = () => controller.abort();
    req.signal.addEventListener("abort", abort, { once: true });
    if (req.signal.aborted) abort();
    const timeout = setTimeout(abort, deps.timeoutMs ?? 15_000);
    const cleanup = () => {
      clearTimeout(timeout);
      req.signal.removeEventListener("abort", abort);
      controller.abort();
    };
    let streaming = false;
    try {
      // Bound the body even if Content-Length is missing or untrusted.
      const reader = req.body?.getReader();
      if (!reader) return jsonError("invalid_text", 400);
      const cancelBody = () => { void reader.cancel().catch(() => {}); };
      controller.signal.addEventListener("abort", cancelBody, { once: true });
      let raw = "";
      const decoder = new TextDecoder();
      try {
        controller.signal.throwIfAborted();
        while (true) {
          const { done, value } = await reader.read();
          controller.signal.throwIfAborted();
          if (done) break;
          raw += decoder.decode(value, { stream: true });
          if (raw.length > 4096) return jsonError("request_too_large", 413);
        }
      } finally {
        controller.signal.removeEventListener("abort", cancelBody);
        await reader.cancel().catch(() => {});
        reader.releaseLock();
      }
      let text: string;
      try { text = validateSpeechText(JSON.parse(raw)); }
      catch { return jsonError("invalid_text", 400); }

      const userID = await deps.authenticate(token);
      controller.signal.throwIfAborted();
      if (!userID) return jsonError("unauthorized", 401);
      if (!(await deps.consumeBudget(userID))) return jsonError("speech_rate_limited", 429);
      controller.signal.throwIfAborted();
      const upstream = await (deps.fetcher ?? fetch)(deps.url, {
        method: "POST",
        headers: { "Content-Type": "application/json", "api-key": deps.apiKey },
        body: JSON.stringify(speechRequest(text)),
        signal: controller.signal,
      });
      if (!upstream.ok || !upstream.body) {
        await upstream.body?.cancel();
        console.warn("[synthesize-speech] provider HTTP", upstream.status);
        return jsonError("speech_unavailable", 502);
      }

      const audio = readMiMoAudio(upstream.body);
      let cancelled = false;
      const encoder = new TextEncoder();
      const encode = (value: unknown) => encoder.encode(JSON.stringify(value) + "\n");
      // Pull-driven forwarding preserves backpressure and avoids buffering a full sentence.
      const stream = new ReadableStream<Uint8Array>({
        async pull(output) {
          try {
            const next = await audio.next();
            if (cancelled) return;
            if (next.done) {
              output.enqueue(encode({ type: "done" }));
              output.close();
              cleanup();
            } else {
              output.enqueue(encode({ type: "audio", data: next.value }));
            }
          } catch {
            console.warn("[synthesize-speech] incomplete provider stream");
            cleanup();
            if (!cancelled) {
              output.enqueue(encode({ type: "error", code: "speech_unavailable" }));
              output.close();
            }
          }
        },
        async cancel() {
          cancelled = true;
          cleanup();
          await audio.return(undefined);
        },
      });
      streaming = true;
      return new Response(stream, {
        headers: {
          "Content-Type": "application/x-ndjson; charset=utf-8",
          "Cache-Control": "no-store, no-transform",
          "X-Accel-Buffering": "no",
        },
      });
    } catch {
      console.warn("[synthesize-speech] request failed");
      return jsonError("speech_unavailable", 503);
    } finally {
      if (!streaming) cleanup();
    }
  };
}
