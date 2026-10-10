# Favorite sentence explanations

## Product flow

Tap a favorite sentence to open its own detail page. The original photo, English,
Chinese and existing playback control appear first. Opening the page only reads
saved content; it never asks an AI to generate an explanation.

Tapping **AI解析 / AI explanation** requests a single **重点解析 / Key expressions**
card with 1–4 useful words or phrases from the original sentence. Each point
contains the word or phrase, a concise explanation and one new English example
with a Chinese translation, in that order. There is no separate examples section
or practice exercise. Explanations do not change SRS, mastery, flip history or
image-generation credits.

## Modules and persistence

- `SentenceDetailView`: presentation and navigation, using the existing photo and
  TTS components. It has no custom queue or study-completion calls.
- `SentenceExplanationModel`: loading, duplicate-tap suppression, failure/retry
  and invalidation of stale results.
- `AppModel+SentenceExplanation`: existing session lifecycle and account-revision
  guards. A saved local result can be read without network access.
- `SentenceExplanationCache`: account/format/content/language-scoped atomic local files
  in Application Support. Only complete validated explanations are written.
- `explain-sentence`: authenticated lookup/generation endpoint; Chinese and
  English UI languages have separate explanations. Logged-in users' sentence
  text is fetched from their owned memories, not trusted from the request.
  Anonymous users can explain their local sentences using their anonymous JWT.
- `sentence_explanations`: cloud cache keyed by authenticated owner and a SHA-256
  fingerprint of schema version, original English/Chinese and explanation
  language. Source changes invalidate the key. Account deletion cascades to the
  cloud cache and request limits.

The current format is version 2: `{version:2, points:[{title, explanation,
example:{english,chinese}}]}`. Both local and cloud keys include the format
version, so saved version-1 content is not displayed as an incomplete version-2
explanation. Existing cloud rows are preserved. Opening the page still does not
regenerate content; the user explicitly taps AI explanation for the new format.

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

Provider order: configured MiMo (`mimo-v2.6-flash`), DeepSeek
(`deepseek-flash`), Kimi (`kimi-k2.5`). Each has a 20-second full-response
deadline; the client allows 75 seconds. Existing `*_API_KEY` and `*_BASE_URL`
secrets are reused. BASE_URL must be the full chat-completions endpoint. Keys
remain server-only. Internal Supabase calls use `SUPABASE_LOCAL_URL` when present.

The 2026-10-10 provider-order change only requires redeploying `explain-sentence`.
No client update, migration or new environment variable is needed. Existing saved
explanations remain cached; switching the provider does not regenerate them.

## Release and verification

1. Apply `20261009001000_add_sentence_explanations.sql` if not already applied,
   then `20261009002000_update_sentence_explanation_points.sql` to staging.
2. Deploy **explain-sentence** using Backend Functions, then run the updated app.
3. Verify a cache miss, explicit generation, word/phrase examples, retry, reentry,
   offline reuse, anonymous use and a different account. Check Chinese/English
   and light/dark modes. No other Edge Function or proxy setting needs updating.

Local checks: `deno check --no-lock supabase/functions/explain-sentence/index.ts`,
`deno test --no-lock --allow-read scripts/tests/sentence-explanation.test.ts scripts/tests/sentence-explanation-database.test.ts`,
and the simulator `SentenceExplanationTests` suite. These use mocks/isolated local
files and do not contact staging/production or trigger purchases.

The tests cover complete translated examples, rejection of invalid/legacy content,
format-scoped cache keys and on-demand generation. Database checks execute both
migrations in isolated in-memory PostgreSQL, including saved legacy rows, lease
expiry, quota resets, private permissions and account-deletion cascades. Simulator
rendering checks cover light/dark modes and accessibility text sizes. No live
provider request or staging/production deployment is part of these local checks.

Local verification on 2026-10-09 for version 2: all 14 explanation handler/database
tests and 12 simulator tests passed. Existing generation, speech and stability
regression suites passed 45 tests. All registered Edge Functions passed type
checking. The rendered point/example card was inspected in light and dark modes,
including accessibility text sizes. No live AI requests or deployment were made.
