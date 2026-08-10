import SwiftUI

enum SentenceStudyTopic: String, CaseIterable, Codable, Hashable, Identifiable {
    case weather
    case kitchen
    case outdoorScenery = "outdoor_scenery"
    case cityStreets = "city_streets"
    case peopleDailyLife = "people_daily_life"
    case travel
    case foodDrink = "food_drink"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .weather:
            return L10n.string("study.topic.weather", "描述天气")
        case .kitchen:
            return L10n.string("study.topic.kitchen", "厨房场景")
        case .outdoorScenery:
            return L10n.string("study.topic.outdoor_scenery", "户外风景")
        case .cityStreets:
            return L10n.string("study.topic.city_streets", "城市与街道")
        case .peopleDailyLife:
            return L10n.string("study.topic.people_daily_life", "人物与日常")
        case .travel:
            return L10n.string("study.topic.travel", "旅行见闻")
        case .foodDrink:
            return L10n.string("study.topic.food_drink", "美食与饮品")
        }
    }

    var iconName: String {
        switch self {
        case .weather:
            return "cloud.sun.fill"
        case .kitchen:
            return "fork.knife"
        case .outdoorScenery:
            return "mountain.2.fill"
        case .cityStreets:
            return "building.2.fill"
        case .peopleDailyLife:
            return "figure.2.and.child.holdinghands"
        case .travel:
            return "suitcase.rolling.fill"
        case .foodDrink:
            return "cup.and.saucer.fill"
        }
    }

    var tintColor: Color {
        switch self {
        case .weather:
            return Color(red: 0.29, green: 0.56, blue: 0.86)
        case .kitchen:
            return Color(red: 0.86, green: 0.45, blue: 0.18)
        case .outdoorScenery:
            return Color(red: 0.24, green: 0.58, blue: 0.40)
        case .cityStreets:
            return Color(red: 0.40, green: 0.45, blue: 0.60)
        case .peopleDailyLife:
            return Color(red: 0.76, green: 0.38, blue: 0.45)
        case .travel:
            return Color(red: 0.56, green: 0.40, blue: 0.78)
        case .foodDrink:
            return Color(red: 0.78, green: 0.50, blue: 0.14)
        }
    }
}

struct SentenceStudyTopicSummary: Hashable {
    let totalCount: Int
    let dueCount: Int
    let studiedCount: Int
    let reviewableTodayCount: Int

    static let empty = SentenceStudyTopicSummary(
        totalCount: 0,
        dueCount: 0,
        studiedCount: 0,
        reviewableTodayCount: 0
    )
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
