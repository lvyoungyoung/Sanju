import { strictEqual, match } from "node:assert/strict";

const root = new URL("../../", import.meta.url);
const target = "spb-bp112jga6hk29sgb";
const production = "spb-bp103246ivn7q0nl";

Deno.test("replacement staging client has an anon key and isolated storage, production stays unscoped", async () => {
  const staging = await Deno.readTextFile(new URL("三句/Config.staging.plist", root));
  const release = await Deno.readTextFile(new URL("三句/Config.plist", root));
  const value = (plist: string, key: string) =>
    plist.match(new RegExp(`<key>${key}</key>\\s*<string>([^<]+)</string>`))?.[1];
  strictEqual(value(staging, "SupabaseURL"), "https://api-staging.sanju.cc");
  strictEqual(value(staging, "SupabaseDataIsolationID"), target);
  strictEqual(value(release, "SupabaseURL"), "https://api.sanju.cc");
  strictEqual(value(release, "SupabaseDataIsolationID"), undefined);
  const token = value(staging, "SupabasePublishableKey")!;
  const payload = JSON.parse(atob(token.split(".")[1].replaceAll("-", "+").replaceAll("_", "/")));
  strictEqual(payload.role, "anon");
  strictEqual(token === value(release, "SupabasePublishableKey"), false);

  const model = await Deno.readTextFile(new URL("三句/AppModel.swift", root));
  match(model, /let defaults = Bundle.main.supabaseDefaults/);
  const keychain = await Deno.readTextFile(new URL("三句/KeychainStorage.swift", root));
  strictEqual(keychain.match(/SupabaseEnvironment.storageKey\(key, isolationID: Bundle.main.supabaseDataIsolationID\)/g)?.length, 3);
  const files = await Deno.readTextFile(new URL("三句/AppModel+Persistence.swift", root));
  strictEqual(files.match(/if Bundle.main.supabaseDataIsolationID != nil \{ return targetURL \}/g)?.length, 2);
});

Deno.test("both deployment workflows pin the new staging project without changing production", async () => {
  for (const name of ["backend-database.yml", "backend-functions.yml"]) {
    const yaml = await Deno.readTextFile(new URL(`.github/workflows/${name}`, root));
    strictEqual(yaml.includes(`inputs.target_environment == 'staging' && '${target}' || '${production}'`), true);
    strictEqual(yaml.includes("spb-bp1364k407p37qn7"), false);
  }
});

Deno.test("staging proxy reference keeps upstream, Host and TLS SNI on the replacement project", async () => {
  const text = await Deno.readTextFile(new URL("deploy/nginx/sanju-staging-upstream.conf.example", root));
  const host = `${target}.supabase.opentrust.net`;
  strictEqual(text.includes(`server ${host}:443;`), true);
  strictEqual(text.includes(`proxy_set_header Host ${host};`), true);
  strictEqual(text.includes(`proxy_ssl_name ${host};`), true);
  strictEqual(text.includes("spb-bp103246ivn7q0nl"), false);
  strictEqual(text.includes("spb-kjnhpxun1ahyip6o"), false);
});

Deno.test("staging deployment guards reject old staging and production before calling any CLI", async (t) => {
  for (const project of ["spb-bp1364k407p37qn7", "spb-kjnhpxun1ahyip6o", production]) {
    for (const script of ["deploy-edge-functions.sh", "supabase-db-migrations.sh"]) {
      await t.step(`${script}: ${project}`, async () => {
        const result = await new Deno.Command("/bin/bash", {
          cwd: root,
          args: [`scripts/${script}`, script.startsWith("deploy") ? "all" : "apply"],
          clearEnv: true,
          env: {
            PATH: "/usr/bin:/bin",
            TARGET_ENVIRONMENT: "staging",
            EXPECTED_SUPABASE_PROJECT_ID: target,
            SUPABASE_PROJECT_ID: project,
            SUPABASE_API_URL: `https://${project}.supabase.opentrust.net`,
            SUPABASE_API_KEY: "fake-local-test-not-a-key",
          },
          stdout: "piped",
          stderr: "piped",
        }).output();
        strictEqual(result.code, 1);
        match(new TextDecoder().decode(result.stderr), /does not match staging project/);
      });
    }
  }
});
