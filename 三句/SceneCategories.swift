import Foundation

struct SceneCategory: Identifiable, Hashable {
    let id: String
    let fallbackTitle: String

    var title: String {
        L10n.string("scene_category.\(id)", fallbackTitle, tableName: "SceneCategories")
    }

    // Shared by the photo and sentence wrappers; checked against the server catalog.
    static let all: [SceneCategory] = [
        .init(id: "people_and_portraits", fallbackTitle: "人物与合影"),
        .init(id: "self_and_style", fallbackTitle: "穿搭与形象"),
        .init(id: "family_time", fallbackTitle: "家人相处"),
        .init(id: "children_growing_up", fallbackTitle: "孩子成长"),
        .init(id: "friends_gatherings", fallbackTitle: "朋友相聚"),
        .init(id: "romance_and_companionship", fallbackTitle: "恋爱与陪伴"),
        .init(id: "pets_and_animals", fallbackTitle: "宠物与动物"),
        .init(id: "flowers_and_plants", fallbackTitle: "花草与植物"),
        .init(id: "food_and_drinks", fallbackTitle: "美食与饮品"),
        .init(id: "restaurants_and_cafes", fallbackTitle: "餐厅与咖啡馆"),
        .init(id: "cooking", fallbackTitle: "下厨"),
        .init(id: "home_life", fallbackTitle: "居家生活"),
        .init(id: "city_life", fallbackTitle: "城市与建筑"),
        .init(id: "natural_scenery", fallbackTitle: "自然风景"),
        .init(id: "travel", fallbackTitle: "旅行"),
        .init(id: "transport", fallbackTitle: "交通出行"),
        .init(id: "sports_and_outdoors", fallbackTitle: "运动与户外"),
        .init(id: "festivals_and_celebrations", fallbackTitle: "节日与庆祝"),
        .init(id: "arts_and_entertainment", fallbackTitle: "文化娱乐"),
        .init(id: "school_and_study", fallbackTitle: "学校与学习"),
        .init(id: "work_life", fallbackTitle: "工作与办公"),
        .init(id: "shopping", fallbackTitle: "购物"),
        .init(id: "health_and_wellness", fallbackTitle: "身体与健康"),
        .init(id: "objects_and_details", fallbackTitle: "物品特写"),
        .init(id: "screenshots_and_documents", fallbackTitle: "截图与文档")
    ]

    static let knownIDs = Set(all.map(\.id))

    static func category(for id: String) -> SceneCategory? {
        all.first { $0.id == id }
    }

    static func normalizedIDs(_ ids: [String], limit: Int) -> [String] {
        var seen = Set<String>()
        return Array(ids.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { knownIDs.contains($0) && seen.insert($0).inserted }.prefix(limit))
    }
}
