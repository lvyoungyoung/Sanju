import { SCENE_CATEGORIES, normalizeSceneCategoryIDs } from "../_shared/scene-categories.ts"

export const PHOTO_CATEGORIES = SCENE_CATEGORIES.map(([id, title]) => [id, title] as const)

export function normalizePhotoCategories(value: unknown): string[] {
  return normalizeSceneCategoryIDs(value, 3)
}

export function buildPhotoCategoryRules(includeCatalog = true): string {
  const catalog = includeCatalog
    ? `只用以下 ID：\n${PHOTO_CATEGORIES.map(([id, title]) => `${id}（${title}）`).join("；")}`
    : "与 learning_topic_ids 共用上面的分类目录和 ID。"
  return `照片分类 tags：直接根据图片本身选择，独立于每句的 learning_topic_ids 和 expression_purpose，不能从句子反推。${catalog}
返回有序数组：第一项为最突出的主分类，最多再加两个明确的次分类，不凑满。只看主要主体和清晰场景，忽略偶然背景；不推测旅行意图、人物关系或情绪。无法确定关系的人像选人物与合影；餐饮环境突出选餐厅与咖啡馆，食物饮品特写选美食与饮品；户外运动须有运动或活动线索，不把所有风景归入运动与户外。截图文档按信息载体分类，不按其中提到的对象分类。无法确定则 tags 为 []。`
}
