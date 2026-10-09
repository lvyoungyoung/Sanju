// Photo categories describe visible subjects/scenes, independently of sentence learning topics.
export const PHOTO_CATEGORIES = [
  ["people_and_portraits", "人物与合影"],
  ["food_and_drinks", "美食与饮品"],
  ["restaurants_and_cafes", "餐厅与咖啡馆"],
  ["pets_and_animals", "宠物与动物"],
  ["flowers_and_plants", "花草与植物"],
  ["natural_scenery", "自然风景"],
  ["cities_and_architecture", "城市与建筑"],
  ["home_life", "居家生活"],
  ["work_and_office", "工作与办公"],
  ["school_and_study", "学校与学习"],
  ["sports_and_outdoors", "运动与户外"],
  ["parties_and_celebrations", "聚会与庆祝"],
  ["culture_and_entertainment", "文化与娱乐"],
  ["transportation", "交通与出行"],
  ["clothing_and_style", "穿搭与服饰"],
  ["objects_and_details", "物品特写"],
  ["screenshots_and_documents", "截图与文档"],
] as const

const PHOTO_CATEGORY_IDS: Set<string> = new Set(PHOTO_CATEGORIES.map(([id]) => id))

export function normalizePhotoCategories(value: unknown): string[] {
  if (!Array.isArray(value)) return []
  const ids = value.filter((id): id is string => typeof id === "string").map((id) => id.trim())
  return [...new Set(ids.filter((id) => PHOTO_CATEGORY_IDS.has(id)))].slice(0, 3)
}

export function buildPhotoCategoryRules(): string {
  return `照片分类 tags：直接根据图片本身选择，独立于每句的 learning_topic_ids 和 expression_purpose，不能从句子反推。只用以下 ID：
${PHOTO_CATEGORIES.map(([id, title]) => `${id}（${title}）`).join("；")}
返回有序数组：第一项为最突出的主分类，最多再加两个明确的次分类，不凑满。只看主要主体和清晰场景，忽略偶然背景；不推测旅行意图、人物关系或情绪。餐饮环境突出选餐厅与咖啡馆，食物饮品特写选美食与饮品；户外运动须有运动或活动线索，不把所有风景归入运动与户外。截图文档按信息载体分类，不按其中提到的对象分类。无法确定则 tags 为 []。`
}
