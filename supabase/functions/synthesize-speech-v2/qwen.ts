import { MAX_AUDIO_BYTES } from "../_shared/synthesize-speech/speech.ts"

const MAX_FRAME_LENGTH = 512_000

// Qwen's HTTP SSE audio.data is PCM16LE/24kHz/mono. Ignore the final WAV URL;
// only a stop event makes this stream complete and safe for the client to cache.
export async function* readQwenAudio(body: ReadableStream<Uint8Array>): AsyncGenerator<string> {
  const reader = body.getReader()
  const decoder = new TextDecoder()
  let pending = ""
  let lines: string[] = []
  let frameLength = 0
  let audioBytes = 0
  let completed = false

  function parseEvent(): { audio?: string; done?: boolean } {
    const data = lines.join("\n")
    lines = []; frameLength = 0
    if (!data) return {}
    const chunk = JSON.parse(data)
    if (chunk.code || chunk.error || (chunk.status_code !== undefined && chunk.status_code !== 200)) {
      throw new Error("provider_error")
    }
    const output = chunk.output
    const finish = output?.finish_reason
    if (finish && finish !== "null" && finish !== "stop") throw new Error("incomplete_audio")
    const audio = output?.audio?.data
    if (audio !== undefined && audio !== null && audio !== "") {
      if (typeof audio !== "string") throw new Error("invalid_audio")
      const bytes = atob(audio)
      audioBytes += bytes.length
      if (audioBytes > MAX_AUDIO_BYTES) throw new Error("audio_too_large")
      return { audio, done: finish === "stop" }
    }
    return { done: finish === "stop" }
  }

  try {
    while (!completed) {
      const { done, value } = await reader.read()
      if (done) break
      pending += decoder.decode(value, { stream: true })
      let newline: number
      while ((newline = pending.indexOf("\n")) !== -1) {
        const line = pending.slice(0, newline).replace(/\r$/, "")
        pending = pending.slice(newline + 1)
        if (line.length > MAX_FRAME_LENGTH) throw new Error("frame_too_large")
        if (line.startsWith("data:")) {
          const data = line.slice(5).trimStart()
          frameLength += data.length
          if (frameLength > MAX_FRAME_LENGTH) throw new Error("frame_too_large")
          lines.push(data)
        } else if (line === "") {
          const event = parseEvent()
          if (event.audio) yield event.audio
          if (event.done) { completed = true; break }
        }
      }
      if (pending.length > MAX_FRAME_LENGTH) throw new Error("frame_too_large")
    }
    if (!completed || audioBytes === 0 || audioBytes % 2 !== 0) throw new Error("incomplete_audio")
  } finally {
    await reader.cancel().catch(() => {})
    reader.releaseLock()
  }
}
