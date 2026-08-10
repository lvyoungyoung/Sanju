import SwiftUI

/// A learning scene is created from the category returned for a sentence.
/// `favorites` is the one user-created scene and intentionally remains stable.
struct SentenceStudyTopic: RawRepresentable, Codable, Hashable, Identifiable {
    static let favorites = SentenceStudyTopic(uncheckedRawValue: "favorites")

    let rawValue: String

    init?(rawValue: String) {
        let normalizedValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedValue.isEmpty, normalizedValue.count <= 24 else { return nil }
        self.rawValue = normalizedValue
    }

    private init(uncheckedRawValue: String) {
        rawValue = uncheckedRawValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let topic = SentenceStudyTopic(rawValue: value) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid sentence study topic"
            )
        }
        self = topic
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var id: String { rawValue }

    var title: String {
        if usesFavoriteQueue {
            return L10n.string("study.topic.favorites", "收藏")
        }
        return Self.legacyTitle(for: rawValue) ?? rawValue
    }

    var iconName: String {
        usesFavoriteQueue ? "heart.fill" : "rectangle.3.group.fill"
    }

    var tintColor: Color {
        if usesFavoriteQueue {
            return Color(red: 0.84, green: 0.28, blue: 0.34)
        }

        let palette: [Color] = [
            Color(red: 0.29, green: 0.56, blue: 0.86),
            Color(red: 0.24, green: 0.58, blue: 0.40),
            Color(red: 0.86, green: 0.45, blue: 0.18),
            Color(red: 0.56, green: 0.40, blue: 0.78),
            Color(red: 0.76, green: 0.38, blue: 0.45),
            Color(red: 0.40, green: 0.45, blue: 0.60)
        ]
        let index = rawValue.unicodeScalars.reduce(0) { $0 + Int($1.value) } % palette.count
        return palette[index]
    }

    var usesFavoriteQueue: Bool {
        rawValue == Self.favorites.rawValue
    }

    private static func legacyTitle(for value: String) -> String? {
        switch value {
        case "weather":
            return L10n.string("study.topic.weather", "描述天气")
        case "kitchen":
            return L10n.string("study.topic.kitchen", "厨房场景")
        case "outdoor_scenery":
            return L10n.string("study.topic.outdoor_scenery", "户外风景")
        case "city_streets":
            return L10n.string("study.topic.city_streets", "城市与街道")
        case "people_daily_life":
            return L10n.string("study.topic.people_daily_life", "人物与日常")
        case "travel":
            return L10n.string("study.topic.travel", "旅行见闻")
        case "food_drink":
            return L10n.string("study.topic.food_drink", "美食与饮品")
        default:
            return nil
        }
    }
}

struct SentenceStudyTopicSummary: Hashable {
    let totalCount: Int
    let dueCount: Int
    let studiedCount: Int
    let reviewableTodayCount: Int
    let masteryScore: Int

    static let empty = SentenceStudyTopicSummary(
        totalCount: 0,
        dueCount: 0,
        studiedCount: 0,
        reviewableTodayCount: 0,
        masteryScore: 0
    )
}

enum SentenceStudyMastery {
    static func score(forCorrectCount correctCount: Int) -> Int {
        switch correctCount {
        case ...0:
            return 0
        case 1...2:
            return 40
        case 3...4:
            return 70
        default:
            return 100
        }
    }
}

struct SentenceStudyTopicSession: Identifiable {
    let topic: SentenceStudyTopic
    let queue: [SentenceStudyQueueItem]
    let startsInReviewMode: Bool

    var id: String { topic.rawValue }
}

enum SentenceStudyTopicLoadingError: LocalizedError {
    case networkUnavailable

    var errorDescription: String? {
        switch self {
        case .networkUnavailable:
            return L10n.string("study.error.network_unavailable", "当前网络不可用，请连接网络后再开始学习。")
        }
    }
}
