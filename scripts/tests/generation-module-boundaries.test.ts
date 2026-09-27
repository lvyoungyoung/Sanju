import { ok, strictEqual } from "node:assert";

// Stage modules must not import the HTTP entry point or create a dependency
// cycle. Keeping orchestration at the top also makes isolated tests possible.
Deno.test("generation and theme stages form acyclic local module graphs", async () => {
  for (const name of ["generate-memory-v2", "create-study-scene"]) {
    const root = new URL(`../../supabase/functions/${name}/`, import.meta.url);
    const visited = new Set<string>();
    const visiting = new Set<string>();
    async function visit(file: string): Promise<void> {
      ok(!visiting.has(file), `circular stage dependency: ${name}/${file}`);
      if (visited.has(file)) return;
      visiting.add(file);
      const source = await Deno.readTextFile(new URL(file, root));
      if (file !== "index.ts") strictEqual(source.includes("Deno.serve("), false, file);
      for (const match of source.matchAll(/^import .* from ["']\.\/([^"']+)["'].*$/gm)) {
        strictEqual(match[1] === "index.ts" || match[1] === "handler.ts" && file !== "index.ts", false, file);
        await visit(match[1]);
      }
      visiting.delete(file);
      visited.add(file);
    }
    await visit("index.ts");
    ok(visited.size >= 4, name);
  }
});
