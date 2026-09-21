import XCTest
@testable import 三句

final class LearningTopicsTests: XCTestCase {
    func testLifeSceneCatalogIsUniqueAndContainsOnlyCurrentTopics() {
        let ids = LearningTopic.all.map(\.id)
        XCTAssertEqual(ids.count, 21)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertTrue(ids.contains("family_time"))
        XCTAssertTrue(ids.contains("food_and_drinks"))
        XCTAssertFalse(ids.contains("food_and_cooking"))
        XCTAssertFalse(ids.contains("practical_records"))
    }

    func testNamesResolveToTheirExactCategory() {
        for topic in LearningTopic.all {
            XCTAssertEqual(LearningTopic.topic(for: topic.id), topic)
            XCTAssertEqual(LearningTopic.topic(matchingName: "  " + topic.title + "  "), topic)
            XCTAssertEqual(LearningTopic.topic(matchingName: topic.fallbackTitle), topic)
        }
        XCTAssertNil(LearningTopic.topic(matchingName: "描述食物的句子"))
        XCTAssertNil(LearningTopic.topic(matchingName: "餐饮与烹饪"))
    }

    func testTwoSceneIDsSurviveCloudDecodingAndLocalPersistence() throws {
        let ids = ["sports_and_outdoors", "family_time"]
        let sentenceID = UUID()
        let payload = """
        {"id":"\(sentenceID.uuidString)","sort_order":0,"english":"We went camping with our family.","chinese":"我们一家人去露营。","learning_topic_ids":["sports_and_outdoors","family_time"],"is_favorite":false}
        """
        let remote = try JSONDecoder().decode(SupabaseMemorySentenceRecord.self, from: Data(payload.utf8))
        XCTAssertEqual(remote.learningTopicIDs, ids)
        let local = SentenceRecord(id: sentenceID, english: remote.english, chinese: remote.chinese, learningTopicIDs: remote.learningTopicIDs ?? [])
        let restored = try JSONDecoder().decode(SentenceRecord.self, from: JSONEncoder().encode(local))
        XCTAssertEqual(restored.id, sentenceID)
        XCTAssertEqual(restored.learningTopicIDs, ids)
        XCTAssertFalse(restored.isFavorite)
        let suggestedTopics = LearningTopic.all.filter { Set(restored.learningTopicIDs).contains($0.id) }
        XCTAssertEqual(Set(suggestedTopics.map(\.id)), Set(ids))
    }
}
