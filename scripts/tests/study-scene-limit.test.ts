import { strictEqual } from "node:assert";

Deno.test("retired theme endpoints never reach a model or database", async () => {
  for (const name of ["create-study-scene", "review-study-scene", "extract-study-topic-expressions"]) {
    const source = await Deno.readTextFile(new URL(`../../supabase/functions/${name}/index.ts`, import.meta.url));
    const api = await import("data:application/typescript," + encodeURIComponent(`
      export let handler: any;
      const Deno={serve(fn:any){handler=fn}};
      const fetch=()=>{throw new Error("Retired feature must not call any provider")};
      ${source}
    `));
    for (const token of ["", "guest", "user", "service"]) {
      const response = await api.handler(new Request("https://test.invalid", {
        method:"POST", headers:{Authorization:token}, body:'{"name":"A theme"}'
      }));
      strictEqual(response.status,410);
      strictEqual((await response.json()).code,"feature_retired");
    }
    strictEqual((await api.handler(new Request("https://test.invalid"))).status,405);
  }
});
