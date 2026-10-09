import Foundation

struct LearningTopic: Identifiable, Hashable {
    let id: String
    let fallbackTitle: String

    var title: String {
        SceneCategory.category(for: id)?.title ?? fallbackTitle
    }

    static let all = SceneCategory.all.map {
        LearningTopic(id: $0.id, fallbackTitle: $0.fallbackTitle)
    }

    static func topic(for id: String?) -> LearningTopic? {
        guard let id else { return nil }
        return all.first { $0.id == id }
    }

    static func topic(matchingName name: String) -> LearningTopic? {
        let normalizedName = normalizedTopicName(name)
        guard !normalizedName.isEmpty else { return nil }
        return all.first {
            normalizedTopicName($0.title) == normalizedName ||
            normalizedTopicName($0.fallbackTitle) == normalizedName
        }
    }

    private static func normalizedTopicName(_ name: String) -> String {
        name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }
}
