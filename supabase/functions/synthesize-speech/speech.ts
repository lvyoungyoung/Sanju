export const SPEECH_MODEL = "mimo-v2.5-tts";
export const SPEECH_VOICE = "Mia";
export const MAX_AUDIO_BYTES = 24_000 * 2 * 60;
const MAX_FRAME_LENGTH = 512_000;

export function speechRequest(text: string) {
  return {
    model: SPEECH_MODEL,
    messages: [
      {
        role: "user",
        content: "Read the supplied English text exactly as written, without additions or paraphrasing. Use natural conversational English with a warm, relaxed tone, clear pronunciation, and natural connected speech. Use a moderate pace suitable for English learners, not a slow word-by-word reading. Respect punctuation and sentence stress. Do not sing, add sound effects, or exaggerate emotion.",
      },
      { role: "assistant", content: text },
    ],
    audio: { format: "pcm16", voice: SPEECH_VOICE },
    stream: true,
  };
}

export function validateSpeechText(body: unknown): string {
  const text = (body as { text?: unknown } | null)?.text;
  if (typeof text !== "string" || !text.trim() || text.trim().length > 500) {
    throw new Error("invalid_text");
  }
  return text.trim();
}

// MiMo's SSE chunks contain base64 24kHz PCM16LE mono, not a WAV file.
// Require an explicit completion marker so truncated responses are never cached.
export async function* readMiMoAudio(body: ReadableStream<Uint8Array>): AsyncGenerator<string> {
  const reader = body.getReader();
  const decoder = new TextDecoder();
  let pending = "";
  let eventLines: string[] = [];
  let audioBytes = 0;
  let completed = false;

  function parseEvent(): { audio?: string; done?: boolean } {
    const event = eventLines.join("\n");
    eventLines = [];
    if (!event) return {};
    if (event === "[DONE]") return { done: true };
    const chunk = JSON.parse(event);
    if (chunk.error) throw new Error("provider_error");
    const choice = chunk.choices?.[0];
    if (choice?.finish_reason && choice.finish_reason !== "stop") {
      throw new Error("incomplete_audio");
    }
    const audio = choice?.delta?.audio?.data;
    if (audio === undefined || audio === "") return {};
    if (typeof audio !== "string") throw new Error("invalid_audio");
    const decoded = atob(audio);
    audioBytes += decoded.length;
    if (audioBytes > MAX_AUDIO_BYTES) throw new Error("audio_too_large");
    return { audio };
  }

  try {
    while (!completed) {
      const { done, value } = await reader.read();
      if (done) break;
      pending += decoder.decode(value, { stream: true });
      let newline: number;
      while ((newline = pending.indexOf("\n")) !== -1) {
        const line = pending.slice(0, newline).replace(/\r$/, "");
        pending = pending.slice(newline + 1);
        if (line.length > MAX_FRAME_LENGTH) throw new Error("frame_too_large");
        if (line.startsWith("data:")) {
          eventLines.push(line.slice(5).trimStart());
          if (eventLines.reduce((sum, item) => sum + item.length, 0) > MAX_FRAME_LENGTH) {
            throw new Error("frame_too_large");
          }
        } else if (line === "") {
          const event = parseEvent();
          if (event.audio) yield event.audio;
          if (event.done) { completed = true; break; }
        }
      }
      if (pending.length > MAX_FRAME_LENGTH) throw new Error("frame_too_large");
    }
    if (!completed || audioBytes === 0 || audioBytes % 2 !== 0) throw new Error("incomplete_audio");
  } finally {
    await reader.cancel().catch(() => {});
    reader.releaseLock();
  }
}
