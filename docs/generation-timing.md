# Generation timing in Xcode

Run a Debug client from Xcode and filter the console by `GenerationTiming`.
Each tap has a UUID trace shared by client and server logs. Durations are
milliseconds, measured with monotonic clocks. No photos, prompts, sentence text,
tokens or account identifiers are included.

Deploy `generate-memory-v2` to the environment being tested to see server stages.
No new migration or proxy configuration is required for timing. Debug requests
opt into `Server-Timing` response headers; old and Release clients keep the same
JSON contract. If a proxy explicitly strips custom headers, it must preserve
`Server-Timing` and `X-Sanju-Generation-Timing`.

## Reading the output

The following numbers are illustrative, not production measurements:

```text
[GenerationTiming] request=<uuid> BEGIN
[GenerationTiming] request=<uuid> client_compress ms=180.0
[GenerationTiming] request=<uuid> client_session ms=240.0
[GenerationTiming] request=<uuid> http_round_trip ms=9600.0 status=200
[GenerationTiming] request=<uuid> server.moderation ms=850.0
[GenerationTiming] request=<uuid> server.mimo ms=6900.0
[GenerationTiming] request=<uuid> server.image_upload ms=450.0
[GenerationTiming] request=<uuid> server.finalize ms=120.0
[GenerationTiming] request=<uuid> server.total ms=9100.0
[GenerationTiming] request=<uuid> client_local_save ms=35.0
[GenerationTiming] request=<uuid> client_photo_upload ms=1400.0
[GenerationTiming] request=<uuid> END outcome=success client_total_ms=11475.0
```

Only executed stages appear. Successful generation, policy rejection, provider
fallback and server error responses all carry timing when requested.

| Stage | Includes |
| --- | --- |
| `client_checks` | Local credit and rate checks |
| `client_compress` | Preparing analysis and retained photos |
| `client_session` | Session preparation/refresh, including any profile reads |
| `client_pending_save` | Persisting recovery state before sending |
| `client_generate_request` | Entire generation service call, including encoding and decoding |
| `http_round_trip` | Sending the request through the proxy, server execution and receiving the body |
| `server.auth`, `server.profile` | Token validation and profile lookup |
| `server.request_decode` | Request body reading, base64 decoding, validation |
| `server.existing_result` | Idempotency lookup and pre-generation checks |
| `server.concurrency_slot`, `server.job_claim` | Capacity gate and atomic job claim |
| `server.guest_image_upload` | Anonymous recovery image upload before generation |
| `server.moderation` | Image safety check; near zero if disabled |
| `server.prompt` | Preparing prompt and model request |
| `server.mimo`, `server.kimi` | Full provider request, body read and parsing; Kimi only on fallback |
| `server.model_result`, `server.result_prepare` | Provider selection and result construction |
| `server.image_upload` | Signed-in user's server-side analysis image upload |
| `server.finalize` | Atomic result save, debit and indexing outbox write |
| `server.diagnostics`, `server.read_result` | Saving provider diagnostics and reading canonical result |
| `server.error_handling` | Failure bookkeeping and cleanup |
| `server.release_slot` | Releasing concurrency slot, including awaited cleanup |
| `server.background_dispatch` | Scheduling enrichment, NOT its embedding/matching execution |
| `client_local_save` | Local result updates and persistence scheduling |
| `client_photo_upload` | Existing clearer-photo upload step; the current UI waits for it |
| `client_refresh_session` | Token refresh after authentication failure |
| `client_recovery` | Recovery after a failed generation request |
| `client_recovered_save`, `client_recovered_finish` | Reconciling a recovered result locally |

Client stages, HTTP timings and server timings overlap: **do not add them all**.
`server.total` is contained within `http_round_trip`, which is contained within
the client request stage. The difference between HTTP and server time also
includes proxy/Edge startup and scheduling, not just network transfer. Repeated
attempts use the same trace; each response reports that attempt's server stages.

`START` lines show which client stage is currently waiting. Server stages arrive
together in response headers, not live while the model is running. On a network
failure without a response, only `http_timeout` / `http_transport_failed` and
client recovery timing are available. `server_timings_unavailable` means the
response lacked these headers (e.g. old deployment or proxy-generated error).

Sentence classification, expression purposes, vector generation and topic matching
are not included in the foreground headers. Their separate staging-only diagnostics
are described below. Diagnostics do not alter generation, recovery, charging, or
background scheduling.

## Background stages in Xcode (staging only)

The Debug + STAGING client starts a read-only observation after a successful or
recovered generation. Filter Xcode by `GenerationTiming`, then look for
`background.` under the same request UUID. This also supports anonymous generation
using its server guest job ID, not the locally assigned memory ID.

The client reads `get_generation_enrichment_timing` every two seconds, for at most
90 seconds (an in-flight read has a five-second timeout). It stops after the first
report, a network/read error, app backgrounding, session change or cancellation.
Reports arrive together after a background attempt finishes; these are not live
streamed model logs. A diagnostic timeout is NOT a generation failure and does not
cancel server work, change the UI, retry enrichment or debit credits.

Example only, not a measured result:

```text
[GenerationTiming] request=<uuid> background.metadata_generate ms=5100.0 outcome=success attempt=1
[GenerationTiming] request=<uuid> background.metadata_checkpoint ms=15.0 outcome=success attempt=1
[GenerationTiming] request=<uuid> background.sentence_embedding ms=630.0 outcome=success attempt=1
[GenerationTiming] request=<uuid> background.purpose_embedding ms=820.0 outcome=success attempt=1
[GenerationTiming] request=<uuid> background.embeddings_parallel ms=823.0 outcome=success attempt=1
[GenerationTiming] request=<uuid> background.publish_and_match ms=120.0 outcome=success attempt=1
[GenerationTiming] request=<uuid> background.job_total ms=6058.0 outcome=completed attempt=1
```

- `claim`: database task-claim round trip; not queue age.
- `metadata_generate`: the single MiMo call generating BOTH categories and expression
  purposes, including response decoding and validation. They cannot be timed separately.
- `metadata_reuse`: validating previously checkpointed metadata; no AI request.
- `metadata_checkpoint`: saving metadata before vector requests.
- `sentence_embedding`, `purpose_embedding`: separate concurrent provider round trips,
  including payload preparation, response decoding and vector validation.
- `embeddings_parallel`: combined wall-clock wait, not the sum of those two requests.
- `publish_and_match`: the existing atomic RPC that saves metadata/vectors, updates
  matches and completes the job. This includes DB/network overhead; no transaction is split.
- `retry_state`: recording the existing retry state on failure, not starting a retry.
- `job_total`: this claimed job's processing time, excluding claim, prior queue wait
  and the subsequent diagnostic write. Never add it to its component stages.

The worker also logs stage starts/ends and `worker_total` in Edge Function logs,
with a run UUID and job UUID. Diagnostics contain no sentence text, images, vectors,
tokens, user IDs or provider error bodies. The table keeps one small latest-attempt
report per job, follows job deletion, and ignores writes from superseded attempts.
Authenticated/anonymous sessions can read only their own report through the RPC;
direct queue/table reads and diagnostic writes remain service-role-only.

### Deployment

1. Push these changes, then apply `20260926003000_add_enrichment_timing_diagnostics.sql`
   to **staging**, after the existing enrichment migrations.
2. Deploy `generate-memory-v2` and `create-study-scene` to staging (both bundle the
   shared background worker). `recover-guest-generation` and the retired
   `process-generation-enrichment` need no update for this change.
3. Run the updated Debug client from Xcode and generate a new photo while leaving
   the app in the foreground. No new environment variables or proxy changes.

Workers enable diagnostics only when the server-controlled `SUPABASE_URL` hostname
is exactly `spb-bp1364k407p37qn7.supabase.opentrust.net` or `api-staging.sanju.cc`.
Request headers cannot enable them on production. The client additionally requires
DEBUG + STAGING and an allowlisted HTTPS staging URL. Release/production clients
make no diagnostic requests; production workers neither emit these timing logs nor
write reports. The additive migration can accompany a future production release
but is inert there. There is no reason to deploy production just to test timings.

## Prompt compaction baseline (2026-09-26)

Historical measurements below describe the three compaction experiments, which
were subsequently reverted for the two-stage pipeline. Current generation restores
the detailed sentence instructions from `5351ee5` but removes metadata tasks.
See [two-stage generation](generation-enrichment.md) for the current migration and
function deployment requirements. The earlier "no migration" notes apply only to
those historical prompt-only changes.

The subsequent prompt-only change consolidates JSON rules, lists each topic
boundary once, and shortens repeated wording. Full three/six-sentence JSON
examples, difficulty/style rules, scene-expression order, all 21 classification
IDs, up to two ordered labels, and grounded expression purposes are retained.
It does not change the model, output fields, token limit, timeout or fallback.

At medium difficulty and the everyday style, the dual-tab prompt decreased from
4,994 to 3,348 characters (33.0%); the legacy prompt from 3,834 to 2,364 (38.3%).
These are Unicode character counts of the text prompt only, **not token counts**.
No live model quality or latency comparison was performed locally. Compare
several identical photos/preferences after deploying `generate-memory-v2`, using
`server.mimo` and `client_total_ms`; do not infer proportional speedup from size.
No database migration or client update is needed for this prompt-only change.

### Second wording pass

The next pass keeps the 21 topic boundary descriptions and complete JSON examples
byte-for-byte, while shortening generation/format rules and the purpose example.
At the same medium/everyday settings, dual-tab text drops from 3,348 to 3,018
characters (another 9.9%; 39.6% below the original 4,994). Legacy text drops from
2,364 to 2,153. Field types, sentence counts, purpose limits and all processing
after prompt construction are unchanged. Tests cover each difficulty/style/format
combination, not live model quality or speed; deployment and comparison remain
necessary before attributing any timing improvement to this wording change.

### Around 2,000 characters

The latest request sets a much tighter budget. Continuing the character-count
metric above (not words or tokens), the medium/everyday dual-tab prompt is now
2,020 characters, down from 3,018. All dual-tab preference combinations are
1,992-2,071 characters; the medium/everyday legacy prompt is 1,551 characters.

The six repeated JSON items are replaced by one complete sentence-object example
and explicit top-level fields and counts (two arrays of three, or the legacy
array of three). The prompt says the example is not a complete answer. The 21
topic IDs are unchanged; shorter definitions retain their selection boundaries.
Purpose limits, sentence difficulty/style, scene-expression order and response
fields remain specified. No parser, model, recovery, credit or indexing code was
changed. Regression tests also exercise the actual parser with the composed
three/six-sentence payloads and reject a lone example or incomplete dual group.

Deploy only `generate-memory-v2`; no migration, client or proxy update is needed.
The shorter structural instructions still need a real-photo quality/format check
after deployment. Unit tests do not prove model adherence or a latency reduction.
