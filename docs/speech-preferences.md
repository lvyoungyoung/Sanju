# Reading voice synchronization

- `profiles.speech_voice` stores Mia / Chloe / Milo / Dean. Null means not yet configured.
- Logged-out preferences remain on the device. Login loads the account voice; an
  unset account is initialized from the guest preference using a conditional PATCH.
- Local account caches and pending writes are isolated by Auth user ID. Failed
  writes survive relaunch and retry on login, foreground activation or reconnection.
- Requests are serialized. New selections supersede stale reads, and responses
  for an account the user left cannot change the current voice.
- Cloud settings do not gate login, generation or audio playback. Until the
  migration is deployed, the new client retains local playback and reports pending sync.
- Only the voice is synchronized. Reading speed was removed; the study completion
  auto-play toggle remains a separate local setting.

## Deployment

1. Run Backend Database for staging (`apply`), including
   `20260922001000_add_profile_speech_voice.sql`.
2. No Edge Function or proxy changes are required.
3. Run `node scripts/check-client-compatibility.mjs`, then check voice restoration
   between two signed-in devices, logout/account switching, and offline selection.
4. After staging validation, deploy the same migration to production.

Existing profile reads/writes and RPC signatures are unchanged. The nullable
column uses the existing profile permissions/RLS and does not touch credit balances.

## Local checks

- iOS tests: `SpeechPreferenceSyncTests`, `SpeechAudioTests`, `StudioAppearanceTests`.
- Database test: `deno test --allow-read --allow-env --allow-write scripts/tests/speech-preferences.test.ts`.
