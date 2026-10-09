import Foundation

enum MemoryNavigationRoute: Hashable {
    case memory(UUID)
    case photoTopic(String)
}

enum MemoryBrowseMode: Int, CaseIterable {
    case time
    case topic

    var title: String {
        switch self {
        case .time: L10n.string("memories.browse.time", "按时间")
        case .topic: L10n.string("memories.browse.topic", "按主题")
        }
    }
}

struct MemoryPhotoTopic: Identifiable {
    let id: String
    let memories: [MemoryEntry]

    var title: String {
        MemoryPhotoCategory.category(for: id)?.title ?? L10n.string("memories.topic.uncategorized", "未分类")
    }

    var cover: MemoryEntry? { memories.first }
}

struct MemoryPhotoCollection {
    static let uncategorizedID = "__uncategorized__"
    let allMemories: [MemoryEntry]
    let topics: [MemoryPhotoTopic]

    static func photoCountTitle(_ count: Int) -> String {
        let key = count == 1 ? "memories.topic.photo_count.one" : "memories.topic.photo_count"
        return L10n.string(key, "%d 张照片", count)
    }

    init(memories: [MemoryEntry]) {
        allMemories = memories.deduplicatedByMemoryID().sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        var grouped: [String: [MemoryEntry]] = [:]
        for memory in allMemories {
            let categoryIDs = MemoryPhotoCategory.normalizedIDs(memory.tags)
            for id in categoryIDs.isEmpty ? [Self.uncategorizedID] : categoryIDs {
                grouped[id, default: []].append(memory)
            }
        }
        topics = (MemoryPhotoCategory.all.map(\.id) + [Self.uncategorizedID]).compactMap { id in
            guard let photos = grouped[id], !photos.isEmpty else { return nil }
            return MemoryPhotoTopic(id: id, memories: photos)
        }
    }

    func memories(in topicID: String?) -> [MemoryEntry] {
        guard let topicID else { return allMemories }
        return topics.first { $0.id == topicID }?.memories ?? []
    }

    func flipItems(in topicID: String?) -> [AlbumFlipItem] {
        AlbumFlipItem.makeItems(from: memories(in: topicID))
    }
}
