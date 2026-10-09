import Foundation

// A separate catalog for visible photo content, not sentence learning topics.
struct MemoryPhotoCategory: Identifiable {
    let id: String
    let fallbackTitle: String

    var title: String { L10n.string("photo_category.\(id)", fallbackTitle) }

    static let all: [MemoryPhotoCategory] = [
        .init(id: "people_and_portraits", fallbackTitle: "人物与合影"),
        .init(id: "food_and_drinks", fallbackTitle: "美食与饮品"),
        .init(id: "restaurants_and_cafes", fallbackTitle: "餐厅与咖啡馆"),
        .init(id: "pets_and_animals", fallbackTitle: "宠物与动物"),
        .init(id: "flowers_and_plants", fallbackTitle: "花草与植物"),
        .init(id: "natural_scenery", fallbackTitle: "自然风景"),
        .init(id: "cities_and_architecture", fallbackTitle: "城市与建筑"),
        .init(id: "home_life", fallbackTitle: "居家生活"),
        .init(id: "work_and_office", fallbackTitle: "工作与办公"),
        .init(id: "school_and_study", fallbackTitle: "学校与学习"),
        .init(id: "sports_and_outdoors", fallbackTitle: "运动与户外"),
        .init(id: "parties_and_celebrations", fallbackTitle: "聚会与庆祝"),
        .init(id: "culture_and_entertainment", fallbackTitle: "文化与娱乐"),
        .init(id: "transportation", fallbackTitle: "交通与出行"),
        .init(id: "clothing_and_style", fallbackTitle: "穿搭与服饰"),
        .init(id: "objects_and_details", fallbackTitle: "物品特写"),
        .init(id: "screenshots_and_documents", fallbackTitle: "截图与文档")
    ]

    private static let knownIDs = Set(all.map(\.id))

    static func category(for id: String) -> MemoryPhotoCategory? {
        all.first { $0.id == id }
    }

    static func normalizedIDs(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        return Array(tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { knownIDs.contains($0) && seen.insert($0).inserted }.prefix(3))
    }
}
