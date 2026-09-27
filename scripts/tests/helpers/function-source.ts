// Existing endpoint tests inject local auth/storage/model doubles into one module.
// Follow function-local imports so they exercise every production stage, not just
// the small Deno.serve entry point. Shared services remain explicit test doubles.
export async function readFunctionSource(entry: URL): Promise<string> {
  const directory = new URL("./", entry).href
  const visited = new Set<string>()
  async function visit(url: URL): Promise<string> {
    if (visited.has(url.href)) return ""
    visited.add(url.href)
    const source = await Deno.readTextFile(url)
    let dependencies = ""
    for (const match of source.matchAll(/^import .* from ["']([^"']+)["'].*$/gm)) {
      const specifier = match[1]
      if (!specifier.startsWith("./")) continue
      const dependency = new URL(specifier, url)
      if (!dependency.href.startsWith(directory)) throw new Error("Unexpected function import")
      dependencies += await visit(dependency)
    }
    return dependencies + "\n" + source.replace(/^import .*\n/gm, "").replace(/^export /gm, "")
  }
  return await visit(entry)
}
