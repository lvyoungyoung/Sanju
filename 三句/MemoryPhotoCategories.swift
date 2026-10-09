import Foundation

struct MemoryPhotoCategory: Identifiable {
    let id: String
    let fallbackTitle: String

    var title: String { SceneCategory.category(for: id)?.title ?? fallbackTitle }

    static let all = SceneCategory.all.map {
        MemoryPhotoCategory(id: $0.id, fallbackTitle: $0.fallbackTitle)
    }

    static func category(for id: String) -> MemoryPhotoCategory? {
        all.first { $0.id == id }
    }

    static func normalizedIDs(_ tags: [String]) -> [String] {
        SceneCategory.normalizedIDs(tags, limit: 3)
    }
}
