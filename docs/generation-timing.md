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

Vector generation and topic matching run in the background, so their execution
is deliberately not included in these foreground timing logs. This diagnostic
change does not alter generation, recovery, charging, or background scheduling.
