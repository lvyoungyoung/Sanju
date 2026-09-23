// Bump the version in both this file and the SQL matcher when descriptions change.
export const CATEGORY_CATALOG_VERSION = "photo-life-v1";
export const CATEGORY_DESCRIPTIONS: Record<string, string> = {
  self_and_style:
    "Personal appearance, outfits, clothing, hairstyles and personal style.",
  family_time:
    "Family life, spending time with parents, siblings and relatives.",
  children_growing_up:
    "Children growing up, their play, development and childhood milestones.",
  friends_gatherings:
    "Meeting friends, social gatherings and spending time together.",
  romance_and_companionship:
    "Romantic relationships, dates, love and companionship.",
  pet_life: "Life with pets, their behavior, care and companionship.",
  food_and_drinks:
    "Describing food and drinks: taste, texture, appearance and the experience of eating and drinking.",
  cooking:
    "Cooking meals, preparing ingredients, baking and activities in the kitchen.",
  home_life:
    "Everyday life at home, rooms, furniture, household activities and relaxing indoors.",
  city_life:
    "City life, urban streets, buildings, neighborhoods and public spaces.",
  natural_scenery:
    "Describing natural scenery: landscapes, mountains, rivers, lakes, the sea, skies and changing weather.",
  plants_and_wildlife:
    "Flowers, plants, trees, wild animals and their life in nature.",
  travel:
    "Travel, vacations, sightseeing, visiting destinations and experiences away from home.",
  transport:
    "Getting around, journeys, commuting, vehicles and public transportation.",
  sports_and_outdoors:
    "Sports, exercise, hiking, camping and outdoor recreation.",
  festivals_and_celebrations:
    "Festivals, birthdays, weddings, holidays and celebrations.",
  arts_and_entertainment:
    "Art, music, performances, museums, films and entertainment.",
  school_and_study:
    "School life, classes, studying, reading and learning activities.",
  work_life: "Work, offices, colleagues, meetings and professional activities.",
  shopping: "Shopping, stores, choosing products, buying things and markets.",
  health_and_wellness:
    "Physical health, wellness, rest, recovery and taking care of the body.",
};

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
  // Small batches avoid provider batch-size limits; three requests at most.
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
