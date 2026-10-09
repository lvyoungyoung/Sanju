# Unified photo and sentence categories

## Behavior

Photos (`memories.tags` / guest job `tags`) and sentences
(`memory_sentences.learning_topic_ids`) use one 25-category catalog.
They are assigned independently: a cafe photo may be `restaurants_and_cafes`,
while a sentence about its coffee is `food_and_drinks`.
Do not copy photo tags onto every sentence or infer photo tags from generated
sentences.

Photo tags retain primary-first order, at most three categories.
Sentence categories retain primary-first order, at most two categories.
Unknown IDs are rejected or discarded, without aliases. No suitable scene can
still produce an empty array. Expression purposes remain sentence-specific.
People and relationship categories require evidence; a group photo alone does
not establish family, friendship or romance.

| ID | Chinese | English |
| --- | --- | --- |
| people_and_portraits | 人物与合影 | People & Portraits |
| self_and_style | 穿搭与形象 | Style & Appearance |
| family_time | 家人相处 | Family Time |
| children_growing_up | 孩子成长 | Growing Up |
| friends_gatherings | 朋友相聚 | Time with Friends |
| romance_and_companionship | 恋爱与陪伴 | Love & Companionship |
| pets_and_animals | 宠物与动物 | Pets & Animals |
| flowers_and_plants | 花草与植物 | Flowers & Plants |
| food_and_drinks | 美食与饮品 | Food & Drinks |
| restaurants_and_cafes | 餐厅与咖啡馆 | Restaurants & Cafes |
| cooking | 下厨 | Cooking |
| home_life | 居家生活 | Life at Home |
| city_life | 城市与建筑 | Cities & Architecture |
| natural_scenery | 自然风景 | Nature & Scenery |
| travel | 旅行 | Travel |
| transport | 交通出行 | Getting Around |
| sports_and_outdoors | 运动与户外 | Sports & Outdoors |
| festivals_and_celebrations | 节日与庆祝 | Festivals & Celebrations |
| arts_and_entertainment | 文化娱乐 | Arts & Entertainment |
| school_and_study | 学校与学习 | School & Study |
| work_life | 工作与办公 | Work & Office |
| shopping | 购物 | Shopping |
| health_and_wellness | 身体与健康 | Health & Wellness |
| objects_and_details | 物品特写 | Objects & Details |
| screenshots_and_documents | 截图与文档 | Screenshots & Documents |

## Sources

- Server source: `supabase/functions/_shared/scene-categories.ts`.
  Generation, metadata validation/repair, recovery and category embeddings import
  this catalog. The combined generation prompt lists it only once.
- Client source: `三句/SceneCategories.swift`.
  `LearningTopic` and `MemoryPhotoCategory` map the same catalog.
  Both use `SceneCategories.strings` through `L10n`.
- Database mirror: `scene_category_ids()`, introduced by
  `20261009003000_unify_scene_categories.sql`.
  Photo normalization, sentence JSON parsing, constraints and category matching
  use the same IDs. Contract tests check the mirrors against the server source.
- Category embedding version: `unified-scenes-v1`, shared by the embedding cache
  and SQL matcher. Cache completeness uses catalog size, not a literal 21.

## Migration Scope

As requested, no compatibility mapping or historical AI reclassification is
implemented. Stored IDs outside the new catalog are removed; photos without a
remaining valid tag appear as uncategorized. Invalid predefined scene IDs become
null. Obsolete category cache entries are removed and the cache is lazily rebuilt
when the existing matching endpoint needs it. Existing sentence and purpose
vectors are not regenerated.

Canonical category arrays in `sentence_embeddings` and
`guest_sentence_embeddings` are normalized before sentence rows. An unfinished
classification (`NULL`) remains unfinished, rather than becoming an empty result.
The preservation trigger also normalizes its canonical source before copying it
back, including when staged guest vectors arrive after deployment. This keeps
obsolete IDs from undoing cleanup or violating the new sentence constraint.

Photo/sentence content and IDs, favorites, study progress, credit balances and
purchase records are not reset. Generation/finalization transaction bodies,
idempotency, model routing and recovery ownership checks are unchanged.
No extra AI call is added to normal image generation.

## Release Order

1. Run Backend Database for the target environment in apply mode:
   `20261009003000_unify_scene_categories.sql`.
2. Deploy `generate-memory-v2`, `recover-guest-generation` and
   `create-study-scene` to the same environment.
3. Run/install the updated client.

The enrichment worker is bundled by `generate-memory-v2`; the retired
`process-generation-enrichment` endpoint does not import the catalog and needs
no deployment. No new secrets or proxy changes are required.
Pushing code does not deploy these changes.

### Retrying the failed staging migration

The initial `20261009003000` migration failed with SQLSTATE `23514` when
`preserve_enriched_sentence_categories` restored old categories from the vector
table during sentence cleanup. The previous isolated fixture omitted this
trigger. The pending migration has been corrected; the regression fixture now
loads the real preservation, guest promotion and matching triggers.

Start a new Backend Database run from the updated `main`, choosing `staging` and
`apply`. Do not rerun the old workflow commit, manually delete constraints, or
mark the failed migration applied. No additional migration file, Edge Function
change, client change, secret or proxy setting is required for this fix. The
three function deployments listed above are still needed to finish the original
category release after its migration succeeds.

## Local Verification

- `bash scripts/check-edge-functions.sh`
- `deno test --no-lock --allow-read --allow-env scripts/tests/life-scene-catalog.test.ts scripts/tests/photo-categories.test.ts scripts/tests/generation-*.test.ts scripts/tests/sentence-metadata.test.ts scripts/tests/study-scene-limit.test.ts scripts/tests/unified-scene-categories-db.test.ts`
- Simulator build and `LearningTopicsTests`, `SceneCategoriesTests`,
  `MemoryPhotoCollectionTests`.
- `plutil -lint` for both category localization tables.

Database tests execute the actual migration repeatedly in isolated PostgreSQL,
exercise every ID, table constraints, cache version/preparation, ownership,
service-role-only write helpers and real authenticated/anonymous finalization
with exactly-once debiting. They include canonical and staged old categories,
preserved vectors/purposes/ownership, unfinished classification and late guest
promotion with production trigger definitions active.
Endpoint tests use local doubles and no live API
calls. Remote deployment and device generation remain release-time checks.
