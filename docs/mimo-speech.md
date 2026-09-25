# MiMo sentence speech

## Runtime behavior

- All existing sentence/word playback and automatic study playback use `SpeechService`.
- A complete account/environment-specific cache hit plays locally, including offline.
- Otherwise the app obtains a valid Supabase session (anonymous sessions are supported)
  and POSTs `{ "text": "..." }` to `synthesize-speech`. No MiMo secret is in the app.
- The function verifies the JWT through internal Supabase Auth, reserves an independent
  speech budget, then streams MiMo audio back as NDJSON. It never debits generation credits
  or writes memories/study progress.
- The model is `mimo-v2.5-tts`, with natural conversational delivery. The voice defaults to
  `Mia`; users can also select `Chloe`, `Milo` or `Dean`. The backend validates this allowlist.
  The source English text is not rewritten. Text goes in the `assistant` message;
  delivery instructions go in the `user` message, as required by the provider.
- Audio is 24 kHz PCM16LE mono. `AVAudioEngine` plays chunks as they arrive.
- Speech Settings is available in Profile and the study settings sheet. Voice and speed
  are saved only in UserDefaults on this device and apply to all playback. Normal speed
  is 1x; Slower is 0.85x using `AVAudioUnitTimePitch`, without pitch changes or another
  synthesis request. The system fallback also respects the selected speed.
- Previewing a voice does not select it. Every preview reads the same fixed English sample;
  the first preview per voice uses the cloud, then the standard local cache is reused.
  No prerecorded samples are bundled. If fallback occurs, the settings UI explicitly says
  the listener is hearing a system voice, not the selected MiMo voice.
- Requests may include `voice`; old clients omitting it keep Mia. The response confirms
  `X-Speech-Voice`. A new client will not cache audio under a different voice if talking to
  an older deployment that ignores voice selection. Deploy updated `synthesize-speech`
  before testing the other three voices; no additional database migration is needed for settings.
- Repeated taps during the same request are coalesced. Switching sentences, stopping,
  account changes and audio interruptions cancel pending playback. Late results cannot
  replace the currently selected sentence.
- Only streams ending with a valid explicit completion event are cached. Partial failures
  stop cloud audio and restart the sentence with iOS speech. Missing deployment, offline,
  quota rejection and other failures also fall back to iOS speech.
- Client total cloud/auth wait is bounded at 18 seconds; network inactivity is limited to
  8 seconds. The function has a 15-second deadline covering upstream response consumption.
  These are failure limits, not expected playback latency.
- Debug logs distinguish cached playback, first-audio milliseconds and system fallback.
  They do not print sentence text, JWTs or API keys.

## Limits and cache

Each valid user, including an anonymous user, can initiate at most 20 cloud syntheses per
UTC calendar minute and 300 per UTC day. A database upsert enforces both limits atomically.
Failed upstream attempts consume this budget; cached playback and iOS fallback do not.
This is per-user cost containment, not a global spending cap. Configure provider budget
alerts as well if exposing the service broadly.

Input is limited to 500 characters, output to 60 seconds of PCM. Disk cache is capped at
512 MiB with no time-based expiration. When over capacity, the oldest saved recordings
are removed first. It lives in the app's disposable Caches directory,
outside cloud backup, with file protection. Cache keys hash environment, user ID, text,
model, voice and prompt version. Bump `prompt2` in `SpeechAudioCache` when changing voice
or delivery instructions so old recordings are not reused.

### Simplified prompt (2026-09-23)

The delivery instruction is now: "Read the text naturally and exactly once. Do not add,
repeat, or change any words." The assistant message remains the original text. This
removes detailed style directions; it does not guarantee that the model will never
produce incorrect audio. No transcription or content verification is added.

Redeploy only `synthesize-speech`, then run the updated client to bypass `prompt1`
recordings using the `prompt2` cache key. No new migration, secrets or proxy changes
are required. Older clients remain compatible but may still play their old local cache.

## Deploy to staging first

1. Push the reviewed changes to GitHub when requested.
2. Run Backend Database for staging to apply
   `20260922000000_add_speech_request_limits.sql`.
3. Confirm function environment variables `MIMO_API_KEY` and `MIMO_BASE_URL` are set.
   `MIMO_BASE_URL` is the existing **full chat/completions endpoint**, not just `/v1`.
   There is no hardcoded default. The key must have access/balance for the TTS model.
   Supabase internal URL/service-role settings remain the existing platform settings.
4. Run Backend Functions, selecting **synthesize-speech**. No existing generation,
   recovery, purchase or study function needs redeployment for this feature.
5. For ECS streaming, merge the exact `synthesize-speech` location from
   `deploy/nginx/sanju-api-proxy.conf.example` into the existing staging server block.
   Keep the existing upstream/Host/TLS configuration; do NOT replace staging with the
   production upstream in the example. Validate Nginx configuration before reloading.
   The function also sends `X-Accel-Buffering: no`, but intermediate gateways can consume
   that header, so explicit proxy buffering settings are more reliable.
6. Run the updated client. Try first play/replay, rapid switching, anonymous/login,
   airplane mode and a simulated unavailable function. Check audio reaches the user
   before the entire response is complete and measure first-audio latency on real networks.

Old clients retain their system TTS. The additive migration does not change existing RPCs,
tables or purchase/generation behavior. A new client can run before deployment and will
use system TTS until the service is available.

## Verification

Offline tests: `deno test --no-lock --allow-read scripts/tests/speech-synthesis.test.ts`;
`bash scripts/check-edge-functions.sh`; iOS simulator build/test including `SpeechAudioTests`.
These use synthetic audio and mocked upstream requests. They do not prove real MiMo
availability, voice quality, production proxy streaming, or billed latency. Deploy and
listen on a device before releasing. Apply/test the SQL on staging as part of deployment.

API reference: https://mimo.mi.com/docs/zh-CN/quick-start/usage-guide/audio/speech-synthesis-v2.5
