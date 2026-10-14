import { ok } from "node:assert";

const root = new URL("../../supabase/functions/", import.meta.url);
const shared = new URL("_shared/", root).href;

async function files(directory: URL): Promise<URL[]> {
  const result: URL[] = [];
  for await (const item of Deno.readDir(directory)) {
    const url = new URL(item.name + (item.isDirectory ? "/" : ""), directory);
    if (item.isDirectory) result.push(...await files(url));
    else if (item.name.endsWith(".ts")) result.push(url);
  }
  return result;
}

// Aliyun uploads only the selected function directory and _shared, not siblings.
Deno.test("every deployed function has a self-contained local dependency bundle", async (t) => {
  const names = (await Deno.readTextFile(new URL("../edge-functions.txt", import.meta.url)))
    .split(/\r?\n/).map(s => s.trim()).filter(s => s && !s.startsWith("#"));
  const commonFiles = await files(new URL(shared));
  for (const name of names) {
    await t.step(name, async () => {
      const directory = new URL(`${name}/`, root);
      for (const file of [...await files(directory), ...commonFiles]) {
        const source = await Deno.readTextFile(file);
        // Includes imports, type-only imports, re-exports and literal dynamic imports.
        for (const match of source.matchAll(/["'](\.{1,2}\/[^"'\n]+\.ts)["']/g)) {
          const dependency = new URL(match[1], file);
          const allowed = file.href.startsWith(shared)
            ? dependency.href.startsWith(shared)
            : dependency.href.startsWith(shared) || dependency.href.startsWith(directory.href);
          ok(allowed, `${name}: ${file.pathname} imports an unpackaged module ${match[1]}`);
          ok((await Deno.stat(dependency)).isFile, `Missing module: ${dependency.pathname}`);
        }
      }
    });
  }
});
