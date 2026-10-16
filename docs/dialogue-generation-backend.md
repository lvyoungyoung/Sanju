# Dialogue Generation Backend

## Contract

- New V3 requests use `generationSpec.generationFormat = "dialogue_tabs_v1"`.
- A photo has 12 flat `SentenceContent` records: six `what_i_see` and six
  `what_i_say`. Each group contains three independent A/B pairs. The structural
  field is `dialogue: { index: 0 | 1 | 2, turn: 0 | 1 }`; indices restart in
  each group. Turn 0 is A and turn 1 is B.
- Every B should naturally respond to its A. The prompt requests a mix of
  observation/response, statement/suggestion and question/answer exchanges.
  `what_i_see` remains visibly grounded and objective; `what_i_say` retains
  scene-adaptive tone. Difficulty and length limits apply to each utterance.
- The parser validates all 12 distinct `(presentationGroup,index,turn)` keys
  and returns canonical group/index/turn order. Missing, duplicated, out-of-range,
  incorrectly typed, extra-field and cross-group mismatched turns are rejected.
  Semantic responsiveness is a prompt requirement, not a deterministic validator.
- Sentence category/purpose metadata stays retired. Photo tags remain unchanged.
- Existing `dual_tabs_v1` V3 jobs retain six standalone sentences. V2 requests
  remain legacy. Three/six-sentence imports and historical single records do not
  acquire a `dialogue` key; absent and null optional fields stay equivalent.

## Persistence And Compatibility

Apply `20261016001000_dialogue_generation.sql` after
`20261016000000_remove_sentence_metadata.sql`. No historical migration is edited.

The migration adds nullable `memory_sentences.dialogue` JSONB, a shape constraint,
a unique per-memory/group/pair/turn index, and a deferred completeness trigger.
It replaces the historical `memory_sentences_sort_order_check` bound of `0..5`
with `0..11`; negative positions and position 12 remain invalid. The PGlite
fixture now loads the actual `20260826001000` migration so this bound cannot be
silently omitted from generation/import tests again.
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

`valid_generation_spec_v3` and the memory specification constraint accept both
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

The existing canonical fingerprint is unchanged for `dual_tabs_v1`. New format
fingerprints incorporate the exact `dialogue_tabs_v1` specification and original
image digest. A pending job cannot switch formats, course or image. New claims
record `promptVersion: "dialogue-v1"`; old format claims retain `multilingual-v1`.

## Output And Request Limits

| V3 format | English | Non-English with learning material |
| --- | ---: | ---: |
| `dual_tabs_v1` | Existing defaults retained | 12,288 |
| `dialogue_tabs_v1` | 8,192 | 24,576 |

The new output budgets double the previous explicit six-sentence budgets.
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
- Import still permits 1-25 memories. Only this endpoint's streamed body ceiling
  rises from 6 MiB to 16 MiB, accommodating up to 300 utterances with bounded
  learning material. Other content endpoints retain their 6 MiB ceiling.
- Per-utterance text, learning material (32 KiB / 256 segments), UUID, language,
  image path and photo-tag checks remain active. The body read deadline stays
  five seconds. Oversized bodies are rejected before any import RPC.

## Verification

Final offline regression after the sort-order follow-up: **98 tests / 80 steps
passed, 0 failed** (about 16 seconds), including the historical sort constraint
and direct authenticated favorite updates. All three entrypoint type checks
passed. Log: `/tmp/sanju-dialogue-backend-regression.log`.

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

The existing untracked `generation-model-benchmark.test.ts` is excluded: its
dependency `scripts/benchmark-generation-metadata.ts` is missing. A broad
`generation-*.test.ts` invocation consequently fails type checking before tests;
neither that test nor its dependencies were changed. The explicit regression
command above avoids that unrelated work.

Both new tests match the existing `scripts/tests/multilingual*.ts` path filters
and test command in `backend-functions.yml`; its deploy job depends on that check.
The separate `backend-database.yml` deploy check now explicitly includes:

```sh
deno test --no-lock --allow-read --allow-env --allow-sys scripts/tests/multilingual-dialogue-generation.test.ts scripts/tests/multilingual-dialogue-http.test.ts
```

The Database workflow's existing `scripts/tests/**` path filters also cover
these files.

## Deployment Handoff

No commit, push, deployment or live API call was performed.

1. Apply the new migration above, after the metadata-retirement prerequisite.
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

## Exact Changed Files

- `supabase/functions/_shared/content-contracts/memory.ts`
- `supabase/functions/_shared/generate-memory-v2/handler.ts`
- `supabase/functions/_shared/generate-memory-v2/providers.ts`
- `supabase/functions/_shared/generation/adapter.ts`
- `supabase/functions/_shared/generation/content.ts`
- `supabase/functions/_shared/generation/http.ts`
- `supabase/functions/_shared/generation/spec.ts`
- `supabase/functions/import-guest-memories-v1/index.ts`
- `supabase/migrations/20261016001000_dialogue_generation.sql`
- `scripts/tests/helpers/dialogue-database.ts`
- `scripts/tests/multilingual-dialogue-generation.test.ts`
- `scripts/tests/multilingual-dialogue-http.test.ts`
- `docs/dialogue-generation-backend.md`

Existing dirty client, documentation, benchmark and other workspace changes are
not part of this implementation and have not been reverted or included.
