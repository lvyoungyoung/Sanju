# Device-Local Study Days

## Rules

- Signed-in and guest study use the phone's current Gregorian calendar day, not a rolling 24-hour window.
- The client sends the IANA zone in `x-sanju-study-time-zone` on REST RPC requests and `create-study-scene`.
- PostgreSQL validates the zone against `pg_timezone_names` and uses server time for "now". Missing or invalid headers retain `Asia/Shanghai` behavior for released clients.
- Favorite and custom-scene queues, due counts, studied-today counts, completion deduplication, and new review dates use the same zone.
- The existing study intervals and independent favorite/scene scopes are unchanged. A local day can be 23 or 25 hours across daylight-saving transitions.
- Actual `last_studied_at` determines the study day in the current zone. Legacy records without timestamps fall back to `last_studied_on`.
- Existing review timestamps are not rewritten. Eligibility compares their date in the current zone; new review dates are scheduled at local midnight.
- Guest-to-account merge formats upload dates and the request header with one zone snapshot. It does not add duplicate completion counts.
- The app refreshes study summaries on significant time changes and on foreground entry when its day or zone has changed.
- This change does not alter generation quotas, purchases, rate limits, or authentication rules.

## Deployment

1. Apply `20260921000000_use_device_study_time_zone.sql` through Backend Database, staging first.
2. Redeploy `create-study-scene`; it forwards the request zone to its service-role RPC so the creation response has correct daily counts.
3. Install the updated client. Old clients do not send a zone and retain their existing Beijing-day behavior.

RPC names, parameters, return types, ownership checks, and existing grants are preserved. The owner-only scene-summary RPC remains service-role-only. There is no profile timezone field and no historical progress deletion.

Earlier uncommitted life-scene work has separate deployment requirements documented in `life-scene-topics.md`.

## Verification

- `deno test --no-lock --allow-read --allow-env scripts/tests/study-time-zone.test.ts` executes the actual migration in an isolated PGlite database, including old function definitions and permissions.
- Covers Shanghai, Los Angeles, Kiritimati, midnight boundaries, timezone changes, daylight-saving boundaries, same-day completion deduplication, separate scopes, guest merge, invalid headers, and preserved service-role grants.
- `StudyCalendarTests` covers client date formatting, header values, daylight-saving day lengths, and actual study timestamps after travel.
- Before production, manually verify both login states on devices set to Shanghai and Los Angeles, then switch zones or cross midnight and check favorite and scene summaries. Local tests do not verify deployed proxy header forwarding.
