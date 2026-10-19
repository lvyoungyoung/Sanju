# Dialogue Generation Backend

## Current: Named Scenarios (2026-10-17)

New clients request `scenario_dialogue_v1`. The model returns `scenarios` (two
or three different situations, with no preferred count) and photo `tags`.
Each scenario has a short Chinese `title` and exactly three `dialogue` objects
with speakers A, B, A. English/Chinese courses use `english` and `chinese`;
other courses use `targetText` / `translationText` for the corresponding field,
retaining segmented learning material where required. Titles stay Chinese.

The prompt follows the photo-scenario template: natural useful conversation,
different small topics, plausible fictional context without asserting real
identities, and a third turn that continues the conversation rather than asking
the app user to answer. Usually 5–12 words, with natural shorter/longer speech
allowed. Vocabulary and grammar follow the selected level. There is no random
objective/subjective middle group, mandatory question or sentence-purpose output.

The server flattens the result into six or nine independently identifiable
sentence records. `dialogue: {index, turn, title}` preserves scenario membership;
indices are contiguous from zero, turns are 0/1/2. `presentationGroup` is the
internal placeholder `what_i_say`, not an AI category or client Tab. Titles must
be nonempty, at most 24 Unicode scalars, identical within a scenario and distinct
between scenarios. The validator checks shape, not whether conversations sound
natural. English word-count safety caps are 18/18/24 for starter/beginner/
intermediate; Japanese character and all other material checks remain in place.

Flow: client compression and session checks -> moderation -> one model request
for scenarios plus tags -> validation -> image upload and atomic save/debit ->
client persistence/display. Provider order and timeouts are unchanged. No extra
model request is introduced for titles; no sentence taxonomy/purpose/vector job
is added. Failed parsing can still cause fallback, so local tests alone do not
establish real response time or naturalness.

The new migration `20261017000000_scenario_dialogue_generation.sql` extends the
existing dialogue JSON and immutable format marker. It retains old singles,
12-turn dialogues, six-turn pairs, IDs, favorites, study history and receipts.
One credit is charged per photo, not per scenario or utterance. Recovery and guest
import retain all titles and turns. No destructive backfill is performed.

Deployment order: apply the new migration, deploy `generate-memory-v3` and
`import-guest-memories-v1`, then test the updated client. Existing read/recovery
functions pass through the stored JSON and need no redeployment. No new secrets,
environment variables, proxy routes or changes to speech endpoints are required.
Code push is not a deployment. The sections below document historical formats.

Local verification for this version: 111 backend regression tests / 174 steps
passed, plus the new database suite's 3 tests / 7 steps. The final dedicated
scenario run passed 11 tests / 95 steps. All Edge Function dependency and type
checks passed. Logs: `/tmp/sanju-scenario-backend.log`,
`/tmp/sanju-scenario-final-backend.log`, `/tmp/sanju-scenario-functions.log`.
Both GitHub deployment workflows now run the scenario test files. No live model,
staging/production database, deployment or real speech service was exercised.

### Neutral Scenario Count (2026-10-19)

The prompt now says only "生成 2—3 个情景", removing the default of two and the
extra condition for a third. Topic diversity, three A/B/A turns, output fields,
and validation accepting either six or nine utterances remain unchanged.
Deploy only `generate-memory-v3` after pushing this change. No new database
migration, client update, secrets or proxy changes are needed.
Local scenario regression passed 8 tests / 88 steps; all Edge Function dependency
and type checks passed. No live model request or deployment was performed.

### Observational Conversations (2026-10-19)

Named scenarios can now be conversations about jointly observing scenery or
visible details, not just imagined situations. The photo guides the choice of
observation, feelings, suggestions or situational conversation; no fixed mix is
required. Different groups should offer different observations or topics, but
need not invent separate events or communication purposes. One speaker can point
out something and the other respond or add an observation. Unconnected captions
and mechanical question-answer drills are still discouraged. Titles may describe
scenery or a topic rather than an event.

Only the prompt changes: the neutral two-or-three count, three A/B/A turns,
difficulty, JSON fields, photo tags and validation stay unchanged. Deploy only
`generate-memory-v3`; no new migration, client update, secrets or proxy changes
are needed. Local contract tests do not establish real model output quality.

Verification: 54 regression tests / 88 steps passed across scenario generation,
multilingual generation, legacy prompts and the generation endpoint. All Edge
Function dependency and type checks passed. No live model call or deployment
was performed.

## Contract

- New V3 requests use `generationSpec.generationFormat = "dialogue_trio_v1"`.
- A photo has six flat `SentenceContent` records, three independent A/B pairs.
  Every record has `dialogue: { index: 0 | 1 | 2, turn: 0 | 1 }` with global
  pair indices. Turn 0 is A and turn 1 is B. Canonical order is
  `(0,0), (0,1), (1,0), (1,1), (2,0), (2,1)`.
- `presentationGroup` remains internal structural data, not UI tabs. Pair 0 uses
  `what_i_see`; pair 2 uses `what_i_say`. The server samples pair 1's group once
  with equal probability and persists it as `generation_policy.dialogueMiddleGroup`.
  Both turns use that group; every fallback provider receives the same choice.
  Clients must not select or send this policy. Finalization verifies it against
  the immutable claimed policy, in addition to checking the collection shape.
- Every B should naturally respond to its A. The prompt requests a mix of
  observation/response, statement/suggestion and question/answer exchanges.
  `what_i_see` remains visibly grounded and objective; `what_i_say` retains
  scene-adaptive tone. Difficulty and length limits apply to each utterance.
- The parser validates all six distinct global `(index,turn)` keys
  and returns canonical index/turn order. Missing, duplicated, out-of-range,
  incorrectly typed, extra-field and cross-group mismatched turns are rejected.
  Semantic responsiveness is a prompt requirement, not a deterministic validator.
- Sentence category/purpose metadata stays retired. Photo tags remain unchanged.
- Historical `dialogue_tabs_v1` remains supported: 12 records, six per group,
  three pairs per group, with indices restarting in each group. Its parser still
  validates distinct `(presentationGroup,index,turn)` keys and sorts by group,
  index and turn. Existing `dual_tabs_v1` V3 jobs retain six standalone sentences. V2 requests
  remain legacy. Three/six-sentence imports and historical single records do not
  acquire a `dialogue` key; absent and null optional fields stay equivalent.

## Persistence And Compatibility

### Relaxed Word Counts (2026-10-17)

V3 generation keeps the prompt's difficulty targets but accepts natural short
replies without padding. English targets remain 3–6 / 8–12 / 10–16 words for
starter / beginner / intermediate. Validation allows 1–10 / 1–18 / 1–24 words;
the historical advanced tier allows 1–36. Spanish and French use the same rule:
minimum one word, maximum target upper bound plus the larger of four words or
50% (rounded up). Japanese character limits are unchanged.

Empty or punctuation-only text, excess length, incomplete pairs, incorrect group policy, invalid
photo tags, language-script checks and learning-material validation still fail.
Accepted text is preserved, not truncated or padded. Provider fallback only
occurs if the response still fails validation or the upstream request fails.

Deploy `generate-memory-v3` after pushing this change. No new migration,
client update, environment variable or proxy change is required. V2's legacy
prompt/parser is unchanged. Local mock tests do not establish the cause of any
previous production/staging failure or measure real model latency.

Local verification: 56 tests and 12 substeps passed across generation, dialogue,
offline HTTP, legacy endpoint and prompt suites. The complete Edge Function
dependency-boundary and type checks passed. Logs:
`/tmp/sanju-relaxed-word-regression.log`, `/tmp/sanju-relaxed-word-functions.log`.

Apply the new `20261016002000_dialogue_trio_generation.sql` after the existing
`20261016001000_dialogue_generation.sql` and
`20261016000000_remove_sentence_metadata.sql`. No historical migration is edited.

The prior dialogue migration added nullable `memory_sentences.dialogue` JSONB, a shape constraint,
a unique per-memory/group/pair/turn index, and a deferred completeness trigger.
It replaced the historical `memory_sentences_sort_order_check` bound of `0..5`
with `0..11`; negative positions and position 12 remain invalid. The PGlite
fixture now loads the actual `20260826001000` migration so this bound cannot be
silently omitted from generation/import tests again.
The trio migration retains `0..11` for old records; new generated trios use
`0..5`. It adds immutable, internal `memories.dialogue_format`, backfilling old
dialogue memories as `dialogue_tabs_v1` without changing their DTOs. Inserts set
this marker for both generated and imported memories. The deferred trigger uses
the stored family, preventing a valid six-turn subset of an old 12-turn import
from masquerading as a trio. This marker is not part of DTOs or receipt identity.
Whole-memory deletion still cascades; deleting individual dialogue turns fails.
`project_sentence_content_v2` makes dialogue identity immutable while allowing
favorite updates. `protect_generation_context_v3` also rejects incomplete guest
results on the pending-to-completed transition. Existing completed-result guards
and generation-context immutability remain in force.

Direct authenticated favorite UPDATEs are covered under RLS, not only through
the security-definer favorite RPC. The existing learning-material and legacy
helper grants survive; the new row validator grants EXECUTE to authenticated.
Deferred collection validation is security-definer and does not require exposing
the collection validator to authenticated callers. Tests verify toggling both old
single and new dialogue favorites and blocking foreign-owner row updates. No
production table grants or RLS policies are broadened by this migration.

`valid_generation_spec_v3` and the memory specification constraint accept all three
formats. `validate_memory_import_v1`, `insert_memory_content_v2` and
`finalize_generation_job_v3` enforce the appropriate collection contract before
persistence or debit. Authenticated/anonymous finalization remains transactional
and idempotent, with one credit charged per photo, not per utterance.

`memory_content_dto_v2` includes dialogue only when present. Existing list/get,
favorite and recovery RPCs use this DTO; guest recovery carries the same JSON in
`result_content`. Guest import validates the complete envelope before its first
RPC and retains the guest proof/ownership checks.

`immutable_memory_identity_v1` includes non-null dialogue but omits the key
entirely for old singles. Existing import receipt digests are therefore unchanged,
including receipts whose memories have been deleted. No receipt rewrite or
backfill occurs. Changing valid turn assignments after import conflicts with the
receipt instead of silently rewriting content. Favorites and learning history
remain keyed by the original sentence IDs.

The canonical fingerprint algorithm is unchanged for both historical formats.
New fingerprints incorporate the exact `dialogue_trio_v1` specification and
original image digest. The server-only random middle is not client request
identity; it is immutable job policy. A pending job cannot switch formats,
course or image. Trio claims record `promptVersion: "dialogue-trio-v1"`;
old dialogue/dual claims retain `dialogue-v1` / `multilingual-v1` respectively.

There is no reclaim/resume-generation path. Existing pending claims return
pending; existing failed claims return failed, without overwriting policy or
calling providers. Completed jobs replay the original result. Recovery runs
before sampling; if a competing claim wins after recovery misses, the losing
request stops on the returned status and never uses its newly sampled choice.
After failure, retrying the same ID returns `generation_failed` without debit.
A fresh generation requires a new request ID and may select a different middle.

## Output And Request Limits

| V3 format | English | Non-English with learning material |
| --- | ---: | ---: |
| `dual_tabs_v1` | Existing defaults retained | 12,288 |
| `dialogue_tabs_v1` | 8,192 | 24,576 |
| `dialogue_trio_v1` | 4,096 | 12,288 |

Trio uses the six-utterance budgets; historical 12-turn jobs retain doubled budgets.
DeepSeek receives `max_tokens`; MiMo and Kimi receive the existing
`max_completion_tokens` field. Offline tests inspect all three outgoing request
bodies, including fallback. A provider `finish_reason: "length"` is rejected even
if its content is syntactically valid JSON. Primary providers fall back; if all
providers truncate, generation fails without finalization/debit.

These are requested ceilings, not guarantees of provider acceptance, latency or
natural-language quality. No live provider calls were made. Existing 20-second
provider deadlines and 90-second total generation deadline remain unchanged.

- Generation keeps its 15 MiB streamed JSON envelope, 14 MiB base64-string bound
  and 10 MiB decoded-image bound. New spec fields do not change image handling.
- Import still permits 1-25 memories. This endpoint retains its 16 MiB streamed
  body ceiling, accommodating up to 150 trio or 300 old-dialogue utterances with bounded
  learning material. Other content endpoints retain their 6 MiB ceiling.
- Per-utterance text, learning material (32 KiB / 256 segments), UUID, language,
  image path and photo-tag checks remain active. The body read deadline stays
  five seconds. Oversized bodies are rejected before any import RPC.

## Verification

Final trio offline regression: **100 tests / 86 steps passed, 0 failed** (about
14 seconds), including historical sort constraints and direct authenticated
favorite updates. All three entrypoint type checks passed.

Offline-only commands (cached dependencies, no network permission):

```sh
deno test --cached-only --no-lock --allow-read --allow-env --allow-sys scripts/tests/multilingual*.ts scripts/tests/generation-endpoint.test.ts scripts/tests/generation-module-boundaries.test.ts scripts/tests/generation-prompt.test.ts scripts/tests/generation-timeouts.test.ts scripts/tests/generation-timing.test.ts scripts/tests/generation-jobs.test.ts scripts/tests/sentence-metadata-retirement.test.ts scripts/tests/edge-deployment-boundaries.test.ts
deno test --cached-only --no-lock --no-run supabase/functions/generate-memory-v3/index.ts supabase/functions/import-guest-memories-v1/index.ts supabase/functions/recover-generation-v2/index.ts
```

Coverage includes PGlite authenticated/anonymous debit-once, malformed-pair
rollback, recovery/replay/acknowledgement, guest proof/import, immutable identity,
old pending/completed jobs, old/deleted import receipts, favorites/history,
non-English material round-trips, provider budgets/truncation, request bounds and
the actual V3/import/recovery handlers with local HTTP doubles.
Trio coverage exercises both middle choices for authenticated and anonymous
generation, malformed/missing/duplicate/mismatched pairs, policy-preserving
provider fallback, failed-ID retry and competing claims, six-turn non-English
parsing/budgets, immutable stored family, and old 12-turn results/import receipts.

The existing untracked `generation-model-benchmark.test.ts` is excluded: its
dependency `scripts/benchmark-generation-metadata.ts` is missing. A broad
`generation-*.test.ts` invocation consequently fails type checking before tests;
neither that test nor its dependencies were changed. The explicit regression
command above avoids that unrelated work.

Both extended test files match the existing `scripts/tests/multilingual*.ts` path filters
and test command in `backend-functions.yml`; its deploy job depends on that check.
The separate `backend-database.yml` deploy check now explicitly includes:

```sh
deno test --no-lock --allow-read --allow-env --allow-sys scripts/tests/multilingual-dialogue-generation.test.ts scripts/tests/multilingual-dialogue-http.test.ts
```

The Database workflow's existing `scripts/tests/**` path filters also cover
these files. No new test filename or workflow edit is required for trio support;
workflow maintenance remains with the main thread.

## Deployment Handoff

Deployment is separate from committing/pushing this change. No deployment or
live API call was performed during local verification.

1. Apply `20261016002000_dialogue_trio_generation.sql`, after its existing
   metadata-retirement and 12-turn-dialogue prerequisites.
2. Deploy `generate-memory-v3` and `import-guest-memories-v1` with their shared
   modules. Do not deploy shared files as standalone functions.
3. Existing `recover-generation-v2` and content read/favorite endpoints need no
   redeployment for dialogue: their existing pass-through/SQL calls suffice.
   `generate-memory-v2` need not be redeployed for this feature.
4. No new environment variables, secrets, model selection or proxy routes are
   required. The repository Nginx example already permits 25 MiB bodies, enough
   for the 16 MiB import limit. If an environment has a lower custom ingress cap,
   raise the import route's body allowance to at least 16 MiB before testing large
   batches. No live proxy configuration was inspected or modified.
5. After separately authorized deployment, validate real provider acceptance,
   response quality and latency with the new client. Offline coverage does not
   replace that acceptance check. Do not roll back by dropping dialogue data.

## Backend Changed Files

The backend portion of this trio follow-up changes these nine files:

- `supabase/functions/_shared/content-contracts/memory.ts`
- `supabase/functions/_shared/generate-memory-v2/handler.ts`
- `supabase/functions/_shared/generation/adapter.ts`
- `supabase/functions/_shared/generation/content.ts`
- `supabase/functions/_shared/generation/spec.ts`
- `supabase/migrations/20261016002000_dialogue_trio_generation.sql`
- `scripts/tests/multilingual-dialogue-generation.test.ts`
- `scripts/tests/multilingual-dialogue-http.test.ts`
- `docs/dialogue-generation-backend.md`

The companion client removes category tabs and browses three pairs per new photo;
see `album-flip.md` for client verification. Unrelated workspace changes remain
separate from this delivery.
