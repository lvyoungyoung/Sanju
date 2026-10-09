import { SCENE_CATEGORIES, SCENE_CATEGORY_CATALOG_VERSION } from "../_shared/scene-categories.ts";

export const CATEGORY_CATALOG_VERSION = SCENE_CATEGORY_CATALOG_VERSION;
export const CATEGORY_DESCRIPTIONS: Record<string, string> = Object.fromEntries(
  SCENE_CATEGORIES.map(([id, , description]) => [id, description]),
);

type CacheRow = { topic_id: string; embedding: number[] };
type Cache = {
  read: () => Promise<CacheRow[]>;
  write: (rows: CacheRow[]) => Promise<void>;
};

export function isCategoryEmbedding(value: unknown): value is number[] {
  return Array.isArray(value) && value.length === 1024 &&
    value.every((n) => typeof n === "number" && Number.isFinite(n)) &&
    value.some((n) => n !== 0);
}

// This cache is shared across accounts. No user text is stored in it.
export async function ensureCategoryEmbeddings(
  cache: Cache,
  embed: (texts: string[]) => Promise<number[][]>,
): Promise<void> {
  const existing = new Set(
    (await cache.read())
      .filter((row) => isCategoryEmbedding(row.embedding))
      .map((row) => row.topic_id),
  );
  const missing = Object.entries(CATEGORY_DESCRIPTIONS)
    .filter(([id]) => !existing.has(id));
  // Small batches avoid provider batch-size limits.
  const batches: Array<Array<[string, string]>> = [];
  for (let i = 0; i < missing.length; i += 8) {
    batches.push(missing.slice(i, i + 8));
  }
  const results = await Promise.allSettled(batches.map(async (batch) => {
    const embeddings = await embed(batch.map(([, text]) => text));
    if (
      embeddings.length !== batch.length ||
      !embeddings.every(isCategoryEmbedding)
    ) {
      throw new Error("Invalid category embeddings");
    }
    await cache.write(
      batch.map(([topic_id], index) => ({
        topic_id,
        embedding: embeddings[index],
      })),
    );
  }));
  // Finish all writes before the request returns, even if one batch failed.
  if (results.some((result) => result.status === "rejected")) {
    throw new Error("Category cache initialization incomplete");
  }
}
