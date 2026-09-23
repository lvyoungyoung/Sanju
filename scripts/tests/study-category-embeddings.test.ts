import { deepStrictEqual, rejects, strictEqual } from "node:assert";
import {
  CATEGORY_DESCRIPTIONS,
  ensureCategoryEmbeddings,
} from "../../supabase/functions/create-study-scene/categories.ts";

const vector = [1, ...Array(1023).fill(0)];
Deno.test("category document vectors are batched and reused across users", async () => {
  const rows = new Map<string, number[]>();
  let requests = 0;
  const cache = {
    read: async () =>
      [...rows].map(([topic_id, embedding]) => ({ topic_id, embedding })),
    write: async (items: { topic_id: string; embedding: number[] }[]) => {
      for (const row of items) rows.set(row.topic_id, row.embedding);
    },
  };
  const embed = async (texts: string[]) => {
    requests++;
    strictEqual(texts.length <= 8, true);
    return texts.map(() => vector);
  };
  await ensureCategoryEmbeddings(cache, embed);
  strictEqual(requests, 3);
  deepStrictEqual(
    [...rows.keys()].sort(),
    Object.keys(CATEGORY_DESCRIPTIONS).sort(),
  );
  await ensureCategoryEmbeddings(cache, embed);
  strictEqual(requests, 3);
  rows.set("natural_scenery", []);
  await ensureCategoryEmbeddings(cache, embed);
  strictEqual(requests, 4);
  strictEqual(rows.get("natural_scenery")?.length, 1024);
});

Deno.test("invalid or failed category vectors are never written", async () => {
  for (const bad of [[], [NaN, ...Array(1023).fill(0)], Array(1024).fill(0)]) {
    let writes = 0;
    await rejects(() =>
      ensureCategoryEmbeddings({
        read: async () => [],
        write: async () => {
          writes++;
        },
      }, async (texts) => texts.map(() => bad))
    );
    strictEqual(writes, 0);
  }
});

Deno.test("vector catalog matches the generation category identifiers", async () => {
  const generation = await Deno.readTextFile(
    new URL(
      "../../supabase/functions/generate-memory-v2/index.ts",
      import.meta.url,
    ),
  );
  deepStrictEqual(
    Object.keys(CATEGORY_DESCRIPTIONS),
    [...generation.matchAll(/^  \["([a-z_]+)",/gm)].map((m) => m[1]),
  );
});

Deno.test("embedding responses honor provider indices and reject ambiguous batches", async () => {
  const source = await Deno.readTextFile(
    new URL(
      "../../supabase/functions/create-study-scene/index.ts",
      import.meta.url,
    ),
  );
  const module = await import(
    "data:application/typescript," + encodeURIComponent(`
    const EMBEDDING_MODEL = "test", EMBEDDING_DIMENSIONS = 1024, EMBEDDING_TIMEOUT_MS = 5;
    export let payload: unknown;
    export function setPayload(value: unknown) { payload = value; }
    const fetch = async () => Response.json(payload);
    export ${
      source.slice(
        source.indexOf("async function createEmbeddings("),
        source.indexOf("function jsonResponse("),
      )
    }
  `)
  );
  const first = [1, ...Array(1023).fill(0)];
  const second = [0, 1, ...Array(1022).fill(0)];
  module.setPayload({
    output: {
      embeddings: [{ text_index: 1, embedding: second }, {
        text_index: 0,
        embedding: first,
      }],
    },
  });
  deepStrictEqual(
    await module.createEmbeddings("url", "key", ["a", "b"], "document"),
    [first, second],
  );
  module.setPayload({
    data: [{ index: 1, embedding: second }, { index: 0, embedding: first }],
  });
  deepStrictEqual(
    await module.createEmbeddings("url", "key", ["a", "b"], "document"),
    [first, second],
  );
  for (const index of [0, 2, -1, 0.5]) {
    module.setPayload({
      data: [{ index: 0, embedding: first }, { index, embedding: second }],
    });
    await rejects(
      () => module.createEmbeddings("url", "key", ["a", "b"], "document"),
      /Invalid embedding index/,
    );
  }
});
