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
        .init(id: "daily_life", localizationKey: "learning_topic.daily_life", fallbackTitle: "日常生活"),
        .init(id: "home_and_family", localizationKey: "learning_topic.home_and_family", fallbackTitle: "家庭与居住"),
        .init(id: "clothing_and_shopping", localizationKey: "learning_topic.clothing_and_shopping", fallbackTitle: "衣着与购物"),
        .init(id: "health_and_wellbeing", localizationKey: "learning_topic.health_and_wellbeing", fallbackTitle: "身体与健康"),
        .init(id: "feelings_and_emotions", localizationKey: "learning_topic.feelings_and_emotions", fallbackTitle: "情绪与感受"),
        .init(id: "hobbies_and_leisure", localizationKey: "learning_topic.hobbies_and_leisure", fallbackTitle: "兴趣与休闲"),
        .init(id: "sports_and_fitness", localizationKey: "learning_topic.sports_and_fitness", fallbackTitle: "运动与健身"),
        .init(id: "social_relationships", localizationKey: "learning_topic.social_relationships", fallbackTitle: "人际与社交"),
        .init(id: "school_and_learning", localizationKey: "learning_topic.school_and_learning", fallbackTitle: "学校与学习"),
        .init(id: "work_and_career", localizationKey: "learning_topic.work_and_career", fallbackTitle: "工作与职场"),
        .init(id: "food_and_cooking", localizationKey: "learning_topic.food_and_cooking", fallbackTitle: "美食与烹饪"),
        .init(id: "eating_out", localizationKey: "learning_topic.eating_out", fallbackTitle: "餐厅与咖啡馆"),
        .init(id: "services_and_consumer_life", localizationKey: "learning_topic.services_and_consumer_life", fallbackTitle: "服务与消费"),
        .init(id: "celebrations_and_events", localizationKey: "learning_topic.celebrations_and_events", fallbackTitle: "节日与庆祝"),
        .init(id: "culture_and_arts", localizationKey: "learning_topic.culture_and_arts", fallbackTitle: "文化与艺术"),
        .init(id: "media_and_entertainment", localizationKey: "learning_topic.media_and_entertainment", fallbackTitle: "影视、音乐与阅读"),
        .init(id: "technology_and_online_life", localizationKey: "learning_topic.technology_and_online_life", fallbackTitle: "科技与网络"),
        .init(id: "news_and_public_information", localizationKey: "learning_topic.news_and_public_information", fallbackTitle: "新闻与公共信息"),
        .init(id: "transportation", localizationKey: "learning_topic.transportation", fallbackTitle: "出行与交通"),
        .init(id: "travel_and_holidays", localizationKey: "learning_topic.travel_and_holidays", fallbackTitle: "旅行与度假"),
        .init(id: "cities_and_architecture", localizationKey: "learning_topic.cities_and_architecture", fallbackTitle: "城市与建筑"),
        .init(id: "community_and_public_places", localizationKey: "learning_topic.community_and_public_places", fallbackTitle: "社区与公共场所"),
        .init(id: "weather_and_seasons", localizationKey: "learning_topic.weather_and_seasons", fallbackTitle: "天气与季节"),
        .init(id: "nature_and_landscapes", localizationKey: "learning_topic.nature_and_landscapes", fallbackTitle: "自然风景"),
        .init(id: "animals_and_pets", localizationKey: "learning_topic.animals_and_pets", fallbackTitle: "动物与宠物"),
        .init(id: "plants_and_gardens", localizationKey: "learning_topic.plants_and_gardens", fallbackTitle: "植物与花园"),
        .init(id: "environment_and_sustainability", localizationKey: "learning_topic.environment_and_sustainability", fallbackTitle: "环境与保护"),
        .init(id: "people_and_activities", localizationKey: "learning_topic.people_and_activities", fallbackTitle: "人物与日常活动")
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
