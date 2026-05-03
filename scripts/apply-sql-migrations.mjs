#!/usr/bin/env node

import { createHash } from "node:crypto"
import { readdirSync, readFileSync } from "node:fs"
import { basename, dirname, resolve } from "node:path"
import { fileURLToPath } from "node:url"
import postgres from "postgres"

const scriptDir = dirname(fileURLToPath(import.meta.url))
const repoRoot = resolve(scriptDir, "..")
const migrationsDir = resolve(repoRoot, "supabase", "migrations")
const mode = parseMode(process.argv.slice(2), process.env.DATABASE_MIGRATION_MODE ?? "status")
const targetEnvironment = process.env.TARGET_ENVIRONMENT ?? process.env.SANJU_TARGET_ENVIRONMENT ?? "unknown"
const databaseURL = process.env.SUPABASE_DATABASE_URL ?? process.env.DATABASE_URL ?? ""
const expectedProjectID = process.env.EXPECTED_SUPABASE_PROJECT_ID ?? ""
const skipProjectIDCheck = process.env.SKIP_DATABASE_URL_PROJECT_CHECK === "1"
const allowProduction = process.env.DATABASE_MIGRATION_ALLOW_PRODUCTION === "1"
const failOnPending = process.env.DATABASE_MIGRATION_FAIL_ON_PENDING === "1"

if (!databaseURL) {
  failFast("SUPABASE_DATABASE_URL is required.")
}

if (targetEnvironment === "production" && !allowProduction) {
  failFast("Refusing to run production database migrations without DATABASE_MIGRATION_ALLOW_PRODUCTION=1.")
}

if (expectedProjectID && !databaseURL.includes(expectedProjectID) && !skipProjectIDCheck) {
  failFast(
    [
      "SUPABASE_DATABASE_URL does not contain the expected project id.",
      `Expected project id: ${expectedProjectID}`,
      "If the database host truly cannot contain the project id, set SKIP_DATABASE_URL_PROJECT_CHECK=1 after manually checking the secret.",
    ].join("\n")
  )
}

const migrations = loadMigrations()
const sql = postgres(databaseURL, {
  max: 1,
  idle_timeout: 5,
  connect_timeout: 20,
  onnotice: () => {},
})

console.log("Sanju SQL migration runner")
console.log(`Target environment: ${targetEnvironment}`)
console.log(`Mode: ${mode}`)
console.log(`Migration files: ${migrations.length}`)
console.log("")

try {
  await sql`select pg_advisory_lock(hashtext('sanju_schema_migrations'))`
  await ensureMigrationTable()

  const applied = await loadAppliedMigrations()
  const plan = buildPlan(migrations, applied)

  if (plan.changedChecksums.length > 0) {
    for (const item of plan.changedChecksums) {
      console.error(`Checksum mismatch: ${item.name}`)
      console.error(`  database: ${item.appliedChecksum}`)
      console.error(`  local:    ${item.localChecksum}`)
    }
    failFast("One or more applied migration files changed. Add a new migration instead of editing an applied one.")
  }

  if (mode === "status") {
    printStatus(plan)
    if (failOnPending && plan.pending.length > 0) {
      process.exitCode = 1
    }
  } else if (mode === "baseline") {
    await baselineMigrations(plan.pending)
  } else if (mode === "apply") {
    await applyMigrations(plan.pending)
  }
} finally {
  try {
    await sql`select pg_advisory_unlock(hashtext('sanju_schema_migrations'))`
  } catch {
    // Ignore unlock failures so the original migration error remains visible.
  }
  await sql.end()
}

function loadMigrations() {
  return readdirSync(migrationsDir)
    .filter((file) => file.endsWith(".sql"))
    .sort((left, right) => left.localeCompare(right))
    .map((file) => {
      const path = resolve(migrationsDir, file)
      const sqlText = readFileSync(path, "utf8")
      return {
        version: file,
        name: basename(file),
        path,
        sqlText,
        checksum: createHash("sha256").update(sqlText).digest("hex"),
      }
    })
}

async function ensureMigrationTable() {
  await sql`
    create table if not exists public.sanju_schema_migrations (
      version text primary key,
      name text not null,
      checksum text not null,
      applied_at timestamptz not null default timezone('utc', now()),
      applied_by text not null default current_user,
      mode text not null check (mode in ('baseline', 'apply'))
    )
  `
  await sql`alter table public.sanju_schema_migrations enable row level security`
}

async function loadAppliedMigrations() {
  const rows = await sql`
    select version, name, checksum, applied_at, applied_by, mode
      from public.sanju_schema_migrations
     order by version asc
  `
  return new Map(rows.map((row) => [row.version, row]))
}

function buildPlan(localMigrations, applied) {
  const pending = []
  const appliedLocal = []
  const changedChecksums = []

  for (const migration of localMigrations) {
    const appliedRow = applied.get(migration.version)
    if (!appliedRow) {
      pending.push(migration)
      continue
    }

    if (appliedRow.checksum !== migration.checksum) {
      changedChecksums.push({
        name: migration.name,
        appliedChecksum: appliedRow.checksum,
        localChecksum: migration.checksum,
      })
      continue
    }

    appliedLocal.push(migration)
  }

  return {
    pending,
    appliedLocal,
    changedChecksums,
    appliedOnlyInDatabase: [...applied.keys()].filter(
      (version) => !localMigrations.some((migration) => migration.version === version)
    ),
  }
}

function printStatus(plan) {
  console.log(`Applied locally tracked: ${plan.appliedLocal.length}`)
  console.log(`Pending: ${plan.pending.length}`)
  if (plan.pending.length > 0) {
    for (const migration of plan.pending) {
      console.log(`  - ${migration.name}`)
    }
  }

  if (plan.appliedOnlyInDatabase.length > 0) {
    console.log("")
    console.log("Applied in database but missing locally:")
    for (const version of plan.appliedOnlyInDatabase) {
      console.log(`  - ${version}`)
    }
  }
}

async function baselineMigrations(pending) {
  if (pending.length === 0) {
    console.log("No pending migrations to baseline.")
    return
  }

  await sql.begin(async (tx) => {
    for (const migration of pending) {
      await recordMigration(tx, migration, "baseline")
      console.log(`BASELINE ${migration.name}`)
    }
  })

  console.log("")
  console.log(`Recorded ${pending.length} migration(s) as already applied.`)
}

async function applyMigrations(pending) {
  if (pending.length === 0) {
    console.log("No pending migrations to apply.")
    return
  }

  for (const migration of pending) {
    console.log(`APPLY ${migration.name}`)
    await sql.begin(async (tx) => {
      await tx.unsafe(migration.sqlText)
      await recordMigration(tx, migration, "apply")
    })
  }

  console.log("")
  console.log(`Applied ${pending.length} migration(s).`)
}

async function recordMigration(tx, migration, recordMode) {
  await tx`
    insert into public.sanju_schema_migrations (version, name, checksum, mode)
    values (${migration.version}, ${migration.name}, ${migration.checksum}, ${recordMode})
    on conflict (version) do nothing
  `
}

function parseMode(argv, defaultMode) {
  let parsedMode = defaultMode
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index]
    if (arg === "--mode") {
      parsedMode = argv[++index]
    } else if (arg === "--help" || arg === "-h") {
      printHelp()
      process.exit(0)
    } else {
      failFast(`Unknown argument: ${arg}`)
    }
  }

  if (!["status", "baseline", "apply"].includes(parsedMode)) {
    failFast(`Invalid mode: ${parsedMode}. Expected status, baseline, or apply.`)
  }
  return parsedMode
}

function failFast(message) {
  console.error(message)
  process.exit(1)
}

function printHelp() {
  console.log(`
Usage:
  node scripts/apply-sql-migrations.mjs --mode status
  node scripts/apply-sql-migrations.mjs --mode baseline
  node scripts/apply-sql-migrations.mjs --mode apply

Required environment:
  SUPABASE_DATABASE_URL

Recommended environment:
  TARGET_ENVIRONMENT=staging|production
  EXPECTED_SUPABASE_PROJECT_ID=spb-...

Safety switches:
  DATABASE_MIGRATION_ALLOW_PRODUCTION=1
  DATABASE_MIGRATION_FAIL_ON_PENDING=1
  SKIP_DATABASE_URL_PROJECT_CHECK=1
`.trim())
}
