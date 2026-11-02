import { strictEqual, ok } from "node:assert/strict";
import { createHash } from "node:crypto";

const root = new URL("../../", import.meta.url);
const base = new URL("supabase/bootstrap/staging-20261102/", root);
const read = (name: string) => Deno.readTextFile(new URL(name, base));

Deno.test("staging bootstrap pins its source, replacement target, migrations and exact SQL", async () => {
  const manifest = JSON.parse(await read("manifest.json"));
  strictEqual(manifest.sourceProject, "spb-bp1364k407p37qn7");
  strictEqual(manifest.targetProject, "spb-bp112jga6hk29sgb");
  strictEqual(manifest.schemaOnly, true);
  strictEqual(manifest.businessTables.length, 30);
  strictEqual(Object.keys(manifest.migrationFiles).length, 88);
  for (const [name, digest] of Object.entries(manifest.migrationFiles)) {
    const bytes = await Deno.readFile(new URL(`supabase/migrations/${name}`, root));
    strictEqual(createHash("sha256").update(bytes).digest("hex"), digest);
  }
  for (const [name, digest] of Object.entries(manifest.sqlSha256)) {
    strictEqual(createHash("sha256").update(await read(name)).digest("hex"), digest);
  }
});

Deno.test("bootstrap preserves explicit privileges without copying platform definitions or user data", async () => {
  const sql = await read("public-schema.sql");
  strictEqual((sql.match(/^CREATE TABLE public\./gm) ?? []).length, 30);
  strictEqual((sql.match(/^CREATE FUNCTION public\./gm) ?? []).length, 95);
  strictEqual((sql.match(/^REVOKE ALL ON (?:FUNCTION|TABLE).*FROM PUBLIC, anon, authenticated, service_role;/gm) ?? []).length, 125);
  for (const forbidden of [/^CREATE SCHEMA /m, /^CREATE FUNCTION extensions\./m,
    /^COPY /m, /^INSERT INTO /m, /GRANT ALL ON SCHEMA public TO PUBLIC/,
    /SET transaction_timeout/, /PRIVATE KEY/, /https?:\/\//]) {
    strictEqual(forbidden.test(sql), false, String(forbidden));
  }
  const policies = await read("storage-policies.sql");
  strictEqual((policies.match(/^CREATE POLICY /gm) ?? []).length, 7);
  ok(policies.includes("public.legacy_storage_mutation_allowed_v1("));
  const smoke = await read("runtime-smoke.sql");
  ok(smoke.includes("SAVEPOINT runtime_smoke;"));
  ok(smoke.includes("ROLLBACK TO SAVEPOINT runtime_smoke;"));
  ok(smoke.includes("Duplicate purchase idempotency failed"));
  const history = await read("migration-history.sql");
  const manifest = JSON.parse(await read("manifest.json"));
  for (const name of Object.keys(manifest.migrationFiles)) {
    ok(history.includes(`('${name.split("_")[0]}', `));
  }
});
