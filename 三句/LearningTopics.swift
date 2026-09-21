//
//  LearningTopics.swift
//  三句
//

import Foundation

struct LearningTopic: Identifiable, Hashable {
    let id: String
    let localizationKey: String
    let fallbackTitle: String

    var title: String {
        L10n.string(localizationKey, fallbackTitle)
    }

    static let all: [LearningTopic] = [
        .init(id: "self_and_style", localizationKey: "learning_topic.self_and_style", fallbackTitle: "自己与穿搭"),
        .init(id: "family_time", localizationKey: "learning_topic.family_time", fallbackTitle: "家人相处"),
        .init(id: "children_growing_up", localizationKey: "learning_topic.children_growing_up", fallbackTitle: "孩子成长"),
        .init(id: "friends_gatherings", localizationKey: "learning_topic.friends_gatherings", fallbackTitle: "朋友相聚"),
        .init(id: "romance_and_companionship", localizationKey: "learning_topic.romance_and_companionship", fallbackTitle: "恋爱与陪伴"),
        .init(id: "pet_life", localizationKey: "learning_topic.pet_life", fallbackTitle: "宠物日常"),
        .init(id: "food_and_drinks", localizationKey: "learning_topic.food_and_drinks", fallbackTitle: "吃喝"),
        .init(id: "cooking", localizationKey: "learning_topic.cooking", fallbackTitle: "下厨"),
        .init(id: "home_life", localizationKey: "learning_topic.home_life", fallbackTitle: "居家"),
        .init(id: "city_life", localizationKey: "learning_topic.city_life", fallbackTitle: "城市生活"),
        .init(id: "natural_scenery", localizationKey: "learning_topic.natural_scenery", fallbackTitle: "自然风景"),
        .init(id: "plants_and_wildlife", localizationKey: "learning_topic.plants_and_wildlife", fallbackTitle: "花草与动物"),
        .init(id: "travel", localizationKey: "learning_topic.travel", fallbackTitle: "旅行"),
        .init(id: "transport", localizationKey: "learning_topic.transport", fallbackTitle: "交通出行"),
        .init(id: "sports_and_outdoors", localizationKey: "learning_topic.sports_and_outdoors", fallbackTitle: "运动与户外"),
        .init(id: "festivals_and_celebrations", localizationKey: "learning_topic.festivals_and_celebrations", fallbackTitle: "节日与庆祝"),
        .init(id: "arts_and_entertainment", localizationKey: "learning_topic.arts_and_entertainment", fallbackTitle: "文化娱乐"),
        .init(id: "school_and_study", localizationKey: "learning_topic.school_and_study", fallbackTitle: "学校与学习"),
        .init(id: "work_life", localizationKey: "learning_topic.work_life", fallbackTitle: "工作"),
        .init(id: "shopping", localizationKey: "learning_topic.shopping", fallbackTitle: "购物"),
        .init(id: "health_and_wellness", localizationKey: "learning_topic.health_and_wellness", fallbackTitle: "身体与健康")
    ]

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
