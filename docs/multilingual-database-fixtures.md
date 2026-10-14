# Multilingual Database Foundation: Contract and Test Fixture

Migration: `20261013000000_multilingual_content.sql`. No deployment is authorized.
This document describes the local fixture, not a verified hosted schema export.

## RPC signatures

- `list_memories_v2(p_target_language text = null, p_cursor_created_at timestamptz = null, p_cursor_id uuid = null, p_limit integer = 50)` returns `{schemaVersion:2, memories:[MemoryDTO], nextCursor:{createdAt,id}|null}`. Limit 1-100; descending `(created_at,id)`. Full sync omits language.
- `get_memory_v2(p_memory_id uuid)` returns canonical MemoryDTO or null for missing/foreign IDs.
- `set_sentence_favorite_v2(p_sentence_id uuid, p_is_favorite boolean)` returns `{sentenceID,isFavorite}`. Repeating the same desired state is idempotent.
- `delete_memory_v2(p_memory_id uuid, p_operation_id uuid)` returns `{memoryID,operationID,deleted:true}`. Stable operation UUID; mismatched reuse fails. Database deletion and an image-cleanup outbox are one transaction.
- `get_learning_preferences_v1()` returns `{schemaVersion:1,selection:null|{mode,targetLanguage,translationLanguage,explanationLanguage,revision},languages:[{targetLanguage,level,levelRevision,speechVoice,voiceRevision}]}`. Missing fields begin at revision zero. Selection is not inferred from UI or initialized by migration.
- `update_learning_preferences_v1(p_patch jsonb)` accepts optional `selection` and `language` groups, atomically. Selection requires `{mode:'standard'|'legacyEnglish',targetLanguage,translationLanguage,explanationLanguage,expectedRevision}`. Language requires `{targetLanguage,level?,expectedLevelRevision?,speechVoice?,expectedVoiceRevision?}`. Each supplied value requires its own revision. Conflict is SQLSTATE `40001`, message `preference_revision_conflict`; re-read and replay only still-pending fields.
- `get_language_capabilities_v1(p_catalog_version integer = 1)` returns `{schemaVersion:1,catalogVersion:1,voiceCatalogVersion:1,combinations:[{targetLanguage,translationLanguage,teachingLocale,canRead,canGenerate}]}`. All 10 pairs readable; only en/zh-Hans generation initially enabled. Voices other than existing English voices remain unavailable.
- `get_album_flip_progress_v2(p_target_language text = null)` returns rows of `album_flip_progress`.
- `sync_album_flip_feedback_v2(p_events jsonb)` keeps the existing feedback keys: `{id,sentence_id,memory_id,feedback,occurred_at,time_zone}`; returns affected progress rows. Does not activate study or alter credits.

All user RPCs infer owner from `auth.uid()` and permit only authenticated EXECUTE. Account-content RPCs reject anonymous identities. Capabilities also permit anonymous-auth guests with a valid JWT, so generation cannot rely on stale client rollout flags. Internal DTO/building helpers are not callable by clients.

## Fixture

Run `deno test --allow-read --allow-env scripts/tests/multilingual-database.test.ts`.
PGlite runs PostgreSQL locally. The synthetic baseline deliberately grants broad
permissive policies to test restrictive AND composition. Alice owns en/zh-Hans,
en/es and ja/zh-Hans content; Bob owns a separate en/zh-Hans row. Identical
timestamps exercise cursor tie-breaking. Existing text has leading whitespace
and a newline to detect accidental normalization. Existing favorite, credit,
profile voice/level and study rows predate migration.

The tests execute the real album-flip migration and the complete new migration,
not extracted snippets. They cover mixed reads, count/join isolation, forbidden
legacy mutations, projections, immutable fields, pending task snapshots, Storage
delete/update/upsert guards, preference CAS/atomic rollback, legacy profile
synchronization, versioned flip ownership, deletion receipts/outbox, account
cleanup, material validation, capability flags, and function privileges.
Expression-cache policies inspect every source example without allowing RLS to
hide incompatible examples first. Explicitly server-only payload caches also
receive restrictive deny policies; their service-role access is unchanged.

## Release blockers and limits

- Obtain staging READ ONLY inventory of `pg_policies`, `pg_proc` (definitions/ACL/search_path), triggers, foreign keys, grants, RLS flags, and Storage buckets before applying. No complete original schema exists in this repository. This migration preserves all unknown policies and never rewrites their definitions.
- The study migration isolates checked-in old study/queue/statistics SECURITY DEFINER entry points and adds activation/session/event RPCs. Hosted topic/semantic/summary/cover RPCs and service-role workers still require an inventory audit. Restrictive RLS cannot constrain table-owner/BYPASSRLS SECURITY DEFINER code. Local fixtures alone do not authorize multilingual rollout.
- Any historical null translation causes backfill to abort rather than synthesize content. Audit nulls before deployment. Existing IDs, text, images, favorites, progress, and balances are not rewritten.
- Storage protection covers referenced nonlegacy objects in the existing `memories` bucket, using `memories.image_url`. Actual bucket aliases/public access, signed URLs, owner/path rules, overwrite behavior, and cross-reference paths need hosted verification. No unknown Storage policy is removed.
- Image cleanup uses a durable outbox consumed by the existing service-only `cleanup-guest-generation-jobs` endpoint. The shared worker claims a bounded lease, verifies references and owner/memory paths, removes the Storage object, and records success or a retry. Deployment must verify that this endpoint is periodically invoked with service authentication. Actual Storage deletion/retry and account deletion cleanup remain hosted acceptance checks.
- Nonlegacy content must enter through audited service generation/import transactions. No generic client insertion RPC is supplied. Generation migration owns job snapshot fields and finalize functions; job restrictive guards inspect snapshots through `to_jsonb` so they also work before those fields exist.
- English legacy profile writes and new CAS RPCs lock profile before preference rows. PGlite tests stale revisions and atomicity, not independent-session lock scheduling. Real PostgreSQL multi-session races and old physical-device compatibility remain release gates.
- Learning material v1 uses the shared `{schemaVersion:1,policyVersion:1,textDigest,segments:[{id,surface,reading?,kind,canBlank}]}` contract. It validates SHA-256 of exact UTF-8 text, segment reconstruction, size limits, allowlisted keys/enums, and nonblankable whitespace/punctuation. Linguistic reading quality belongs to the generation/learning policy; this foundation does not claim Japanese quality acceptance.

No staging or production migration, Storage mutation, commit, or push is performed
as part of local validation. New generation combinations remain OFF.

## Read-only hosted audit

Run only against the explicitly authorized staging database. These queries read
schema metadata, not account content or credentials. Store a redacted inventory
outside source control if it contains deployment-specific details.

```sql
begin transaction read only;
select version();
select schemaname,tablename,policyname,permissive,roles,cmd,qual,with_check
from pg_policies where schemaname in ('public','storage')
order by schemaname,tablename,policyname;
select n.nspname,c.relname,c.relrowsecurity,c.relforcerowsecurity,c.relacl
from pg_class c join pg_namespace n on n.oid=c.relnamespace
where n.nspname in ('public','storage') and c.relkind in ('r','p');
select n.nspname,p.oid::regprocedure,p.prosecdef,p.proconfig,p.proacl,
       pg_get_functiondef(p.oid)
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public' and p.prokind='f'
  and (p.prosecdef or p.prosrc ~ '(memories|memory_sentences|study_scene|storage)');
select tgrelid::regclass,tgname,pg_get_triggerdef(oid)
from pg_trigger where not tgisinternal
  and tgrelid in (select oid from pg_class where relnamespace='public'::regnamespace);
select conrelid::regclass,conname,pg_get_constraintdef(oid)
from pg_constraint where connamespace in ('public'::regnamespace,'storage'::regnamespace);
select id,name,public from storage.buckets;
rollback;
```

Review especially `generation_enrichment_jobs`, `guest_sentence_embeddings`,
`sentence_explanations`, legacy topic-expression tables and all definer functions
called by their workers. The first three deny direct client access in checked-in
migrations; topic-expression caches instead have owner-readable policies and
require provenance filtering. Unknown hosted grants and definer execution paths
cannot be assumed safe.
