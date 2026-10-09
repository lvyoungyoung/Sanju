# Favorite sentence explanations

## Product flow

Tap a favorite sentence to open its own detail page. The original photo, English,
Chinese and existing playback control appear first. Opening the page only reads
saved content; it never asks an AI to generate an explanation.

Tapping **AI解析 / AI explanation** requests 1–4 concise teaching points, exactly
two translated example sentences and one four-option cloze exercise. The first
selection reveals the correct choice and a short explanation. **再练一次 / Try
again** resets only this exercise; it does not change SRS, mastery, flip history
or image-generation credits. Reentering starts a fresh exercise attempt.

## Modules and persistence

- `SentenceDetailView`: presentation and navigation, using the existing photo and
  TTS components. It has no custom queue or study-completion calls.
- `SentenceExplanationModel`: loading, duplicate-tap suppression, failure/retry
  and invalidation of stale results.
- `AppModel+SentenceExplanation`: existing session lifecycle and account-revision
  guards. A saved local result can be read without network access.
- `SentenceExplanationCache`: account/content/language-scoped atomic local files
  in Application Support. Only complete validated explanations are written.
- `explain-sentence`: authenticated lookup/generation endpoint; Chinese and
  English UI languages have separate explanations. Logged-in users' sentence
  text is fetched from their owned memories, not trusted from the request.
  Anonymous users can explain their local sentences using their anonymous JWT.
- `sentence_explanations`: cloud cache keyed by authenticated owner and a SHA-256
  fingerprint of schema version, original English/Chinese and explanation
  language. Source changes invalidate the key. Account deletion cascades to the
  cloud cache and request limits. Exercise answers are never persisted.

Cache content is intentionally account-scoped. Guest-to-account migration does not
transfer these auxiliary explanations in this MVP; the sentence itself still
uses the existing migration flow. A different account cannot read a former
account's explanations. App deletion removes local files; the same authenticated
owner can retrieve the saved cloud explanation again. Cached explanations are not
exposed through public REST tables.

## Backend safety

`POST /functions/v1/explain-sentence` accepts `sentenceID`, `english`, `chinese`,
`language` (`zh` or `en`) and `generate` (boolean). With `generate:false`, a cache
miss returns `{ "explanation": null }` without a model call.

Generation claims are atomic and owner-scoped. A 90-second lease prevents two
concurrent requests from generating the same explanation. Publishing checks the
claim UUID and lease; an expired worker cannot overwrite a newer result. Failed
requests release their unfinished claim; runtime termination is recoverable when
the lease expires. Full content validation precedes every successful save.

Separate abuse limits allow 8 new generation attempts per minute and 50 per UTC
day per authenticated owner (including anonymous owners). Cache reads and hits
do not consume this budget or the user's paid image-generation balance. A busy
claim returns 409; a budget limit returns 429. Neither triggers automatic retries.

Provider order: configured DeepSeek (`deepseek-flash`), MiMo
(`mimo-v2.6-flash`), Kimi (`kimi-k2.5`). Each has a 20-second full-response
deadline; the client allows 75 seconds. Existing `*_API_KEY` and `*_BASE_URL`
secrets are reused. BASE_URL must be the full chat-completions endpoint. Keys
remain server-only. Internal Supabase calls use `SUPABASE_LOCAL_URL` when present.

## Release and verification

1. Apply `20261009001000_add_sentence_explanations.sql` to staging.
2. Deploy **explain-sentence** using Backend Functions, then run the updated app.
3. Verify a cache miss, explicit generation, exercise feedback, retry, reentry,
   offline reuse, anonymous use and a different account. Check Chinese/English
   and light/dark modes. No other Edge Function or proxy setting needs updating.

Local checks: `deno check --no-lock supabase/functions/explain-sentence/index.ts`,
`deno test --no-lock --allow-read scripts/tests/sentence-explanation.test.ts scripts/tests/sentence-explanation-database.test.ts`,
and the simulator `SentenceExplanationTests` suite. These use mocks/isolated local
files and do not contact staging/production or trigger purchases.

Local verification on 2026-10-09: explanation handler/database 12 tests passed;
simulator sentence-explanation suite 12 tests passed, including rendering in
light/dark modes and accessibility text sizes. Existing generation, speech and
stability suites: 45 tests passed. SQL was executed in isolated in-memory
PostgreSQL, including lease expiry, quota resets, private permissions and
account-deletion cascades. All registered Edge Functions passed type checking.
No live provider request or staging/production deployment was performed.
