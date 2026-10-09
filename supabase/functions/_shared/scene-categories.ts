// One catalog for photo subjects, sentence scenes and category embeddings.
// Keep the Swift/SQL mirrors aligned with the catalog contract tests.
export const SCENE_CATEGORY_CATALOG_VERSION = "unified-scenes-v1";
export const SCENE_CATEGORIES = [
  [
    "people_and_portraits",
    "人物与合影",
    "People, portraits, faces and group photographs.",
    "人物外貌、表情、姿态、合影；明确的穿搭或人物关系优先选对应分类，不猜测关系",
  ],
  [
    "self_and_style",
    "穿搭与形象",
    "Personal appearance, outfits, clothing, hairstyles and personal style.",
    "穿搭、发型、配饰和个人形象；普通人物描述归人物与合影",
  ],
  [
    "family_time",
    "家人相处",
    "Family life, spending time with parents, siblings and relatives.",
    "家人相伴、陪父母；孩子玩耍成长优先归孩子成长",
  ],
  [
    "children_growing_up",
    "孩子成长",
    "Children growing up, playing and childhood milestones.",
    "孩子玩耍、成长、亲子活动；上课学习归学校与学习",
  ],
  [
    "friends_gatherings",
    "朋友相聚",
    "Meeting friends, social gatherings and spending time together.",
    "朋友相伴、普通聚餐或活动；庆生过节归节日与庆祝",
  ],
  [
    "romance_and_companionship",
    "恋爱与陪伴",
    "Romantic relationships, dates, love and companionship.",
    "约会、情侣、亲密陪伴，不凭两个人臆造恋爱关系",
  ],
  [
    "pets_and_animals",
    "宠物与动物",
    "Pets, birds, wild animals, zoo animals and their behavior or care.",
    "宠物、鸟、野生或动物园动物及其行为、照护；花草树木归花草与植物",
  ],
  [
    "flowers_and_plants",
    "花草与植物",
    "Flowers, plants, trees, gardens and their growth or appearance.",
    "花草树木、园艺、植物生长或外观；动物归宠物与动物，整体山水归自然风景",
  ],
  [
    "food_and_drinks",
    "美食与饮品",
    "Food and drinks: taste, texture, appearance and eating or drinking experiences.",
    "食物饮料的外观、味道、口感、吃喝体验；制作归下厨，店内环境归餐厅与咖啡馆",
  ],
  [
    "restaurants_and_cafes",
    "餐厅与咖啡馆",
    "Restaurants, cafes, dining spaces, menus, ordering and eating out.",
    "餐厅咖啡馆环境、点单用餐；食物饮品本身的味道外观归美食与饮品",
  ],
  [
    "cooking",
    "下厨",
    "Cooking meals, preparing ingredients, baking and kitchen activities.",
    "备菜、烹调、烘焙；成品的味道外观归美食与饮品",
  ],
  [
    "home_life",
    "居家生活",
    "Life at home, rooms, furniture, household activities and relaxing indoors.",
    "房间家具、布置搬家、家务日常；家人互动归家人相处",
  ],
  [
    "city_life",
    "城市与建筑",
    "Urban streets, buildings, architecture, neighborhoods and public spaces.",
    "街道建筑、商店外观、城市夜景；购买行为归购物",
  ],
  [
    "natural_scenery",
    "自然风景",
    "Natural landscapes, mountains, rivers, lakes, seas, skies, weather and seasons.",
    "山川湖海、日落天气、季节雪景；具体花草动物选对应分类",
  ],
  [
    "travel",
    "旅行",
    "Travel, vacations, sightseeing, destinations, hotels and experiences away from home.",
    "旅行经历、景点、酒店、当地见闻；交通归交通出行，不把所有旅游照句子归旅行",
  ],
  [
    "transport",
    "交通出行",
    "Getting around, commuting, airports, stations, vehicles and public transportation.",
    "机场车站、乘车通勤、自驾、交通工具和旅途交通",
  ],
  [
    "sports_and_outdoors",
    "运动与户外",
    "Sports, exercise, running, cycling, hiking, camping and outdoor recreation.",
    "健身跑步、骑行徒步、露营等户外活动；纯山水景色归自然风景",
  ],
  [
    "festivals_and_celebrations",
    "节日与庆祝",
    "Festivals, birthdays, weddings, holidays, anniversaries and celebrations.",
    "生日婚礼、节日纪念日、毕业庆典；普通朋友聚会归朋友相聚",
  ],
  [
    "arts_and_entertainment",
    "文化娱乐",
    "Art, music, performances, museums, films, reading, games and entertainment.",
    "演出展览、电影游乐园、阅读音乐游戏；课程学习归学校与学习",
  ],
  [
    "school_and_study",
    "学校与学习",
    "School life, classes, books, courses, homework and learning activities.",
    "课堂校园、书本课程作业、学习；毕业庆典归节日与庆祝",
  ],
  [
    "work_life",
    "工作与办公",
    "Work, offices, colleagues, meetings, tasks and professional activities.",
    "工位同事、会议任务、工作成果，不凭普通室内布置臆造工作场景",
  ],
  [
    "shopping",
    "购物",
    "Shopping, choosing or trying products, prices, purchases and markets.",
    "购买、挑选试穿、价格、新购物品；仅穿着归穿搭与形象",
  ],
  [
    "health_and_wellness",
    "身体与健康",
    "Physical health, hospitals, checkups, rest, recovery and care for the body.",
    "身体、医院体检、康复休息照护；锻炼动作归运动与户外",
  ],
  [
    "objects_and_details",
    "物品特写",
    "Close-ups of everyday objects, materials, textures and small details.",
    "没有更贴切场景的物品、材质、纹理特写；食物、服饰等优先选对应分类",
  ],
  [
    "screenshots_and_documents",
    "截图与文档",
    "Screenshots, interfaces, charts, receipts, documents and recorded information.",
    "截图界面、图表票据、证件文档等信息载体，不按其中提到的对象分类",
  ],
] as const;

export const SCENE_CATEGORY_IDS: ReadonlySet<string> = new Set(
  SCENE_CATEGORIES.map(([id]) => id),
);

export function normalizeSceneCategoryIDs(
  value: unknown,
  limit: number,
): string[] {
  if (!Array.isArray(value)) return [];
  const ids = value.filter((id): id is string => typeof id === "string").map((
    id,
  ) => id.trim());
  return [...new Set(ids.filter((id) => SCENE_CATEGORY_IDS.has(id)))].slice(
    0,
    limit,
  );
}
