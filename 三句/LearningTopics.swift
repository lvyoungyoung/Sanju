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
        .init(id: "people_and_relationships", localizationKey: "learning_topic.people_and_relationships", fallbackTitle: "人物与关系"),
        .init(id: "clothes_and_appearance", localizationKey: "learning_topic.clothes_and_appearance", fallbackTitle: "衣着与形象"),
        .init(id: "house_and_home", localizationKey: "learning_topic.house_and_home", fallbackTitle: "家与居住"),
        .init(id: "daily_routines", localizationKey: "learning_topic.daily_routines", fallbackTitle: "日常事务"),
        .init(id: "food_and_cooking", localizationKey: "learning_topic.food_and_cooking", fallbackTitle: "餐饮与烹饪"),
        .init(id: "shopping_and_consumption", localizationKey: "learning_topic.shopping_and_consumption", fallbackTitle: "购物与消费"),
        .init(id: "health_and_body", localizationKey: "learning_topic.health_and_body", fallbackTitle: "健康与身体"),
        .init(id: "hobbies_and_culture", localizationKey: "learning_topic.hobbies_and_culture", fallbackTitle: "兴趣、娱乐与文化"),
        .init(id: "sports_and_fitness", localizationKey: "learning_topic.sports_and_fitness", fallbackTitle: "运动与健身"),
        .init(id: "social_occasions", localizationKey: "learning_topic.social_occasions", fallbackTitle: "节日与社交场合"),
        .init(id: "travel_and_transport", localizationKey: "learning_topic.travel_and_transport", fallbackTitle: "出行与旅行"),
        .init(id: "places_and_public_services", localizationKey: "learning_topic.places_and_public_services", fallbackTitle: "城市地点与公共服务"),
        .init(id: "education_and_learning", localizationKey: "learning_topic.education_and_learning", fallbackTitle: "学校与学习"),
        .init(id: "work_and_career", localizationKey: "learning_topic.work_and_career", fallbackTitle: "工作与职业"),
        .init(id: "nature_weather_and_environment", localizationKey: "learning_topic.nature_weather_and_environment", fallbackTitle: "自然、天气与环境"),
        .init(id: "digital_life_and_communication", localizationKey: "learning_topic.digital_life_and_communication", fallbackTitle: "数码生活与沟通")
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
