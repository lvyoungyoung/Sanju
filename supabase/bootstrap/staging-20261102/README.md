# Empty staging bootstrap

Only for `spb-bp112jga6hk29sgb`. Do not execute on production, the old staging,
an occupied project, or through the regular migration runner.

This is a schema-only snapshot from the old staging, whose 88 migration versions
match the repository. `manifest.json` pins migration and snapshot hashes. It is
not a new migration and must never be used to replay all historical SQL on an
existing environment.

The snapshot excludes users, photos, purchases and other business rows. Only
the public language catalog and two empty private bucket configurations are
seeded. Platform extensions, roles, Auth tables and their ownership are retained.
The public schema's CREATE grant to PUBLIC is not copied. Per-object API-role
ACLs are reset before restoring explicit source grants, so target defaults do
not accidentally expose service-only functions. Storage helper references are
schema-qualified. The pg_dump 18 transaction_timeout setting is omitted for PG15.

Execution order inside one transaction: public-schema.sql, language-catalog.sql,
buckets.sql, storage-policies.sql, runtime-smoke.sql, verify.sql. First execute
with ROLLBACK. After verify.sql, migration-history.sql registers the pinned baseline.
The smoke test uses a savepoint and rolls back its synthetic user
and SQL-only credit transaction even on a successful initialization.

Only after the schema and permissions pass verification may the 88 pinned
migration versions be registered as the snapshot baseline. Never blindly mark
versions applied on a missing or partially restored schema. Future migrations
continue through the normal Backend Database workflow.

Client cutover, Auth configuration, runtime secrets, Edge Functions, GitHub
environment secrets and the staging reverse proxy are separate release steps.
Successful database initialization alone does not make the environment usable.
