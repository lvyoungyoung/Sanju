#if DEBUG
import Foundation
import XCTest
@testable import 三句

@MainActor
final class StudyMatchDiagnosticsTests: XCTestCase {
    func testDecodesNullableScoresAndPrintsActualAndCurrentReasons() throws {
        let json = #"""
        {
          "scene_id":"10000000-0000-0000-0000-000000000001",
          "name":"Expressing happiness", "learning_topic_id":null,
          "threshold":0.42, "rule":"sentence_or_purpose_v1",
          "query_model":"test", "legacy_search_description":null,
          "total_sentences":2, "included_count":1,
          "rows":[{
            "sentence_id":"10000000-0000-0000-0000-000000000002",
            "english":"The water is calm.\nSecond line.",
            "expression_purpose":"Describing calm water.",
            "sentence_model":"test", "has_sentence_vector":true,
            "has_purpose_vector":false, "sentence_similarity":0.31,
            "purpose_similarity":null, "included":true,
            "stored_source":"legacy", "stored_score":80, "current_source":null
          }]
        }
        """#
        let result = try JSONDecoder().decode(StudyMatchDiagnostics.self, from: Data(json.utf8))
        let log = result.logLines.joined(separator: "\n")
        XCTAssertTrue(log.contains("original=0.3100 purpose=n/a"))
        XCTAssertTrue(log.contains("storedSource=legacy"))
        XCTAssertTrue(log.contains("currentSource=none linkMismatch=true"))
        XCTAssertTrue(log.contains("truncated=true"))
        XCTAssertTrue(log.contains("The water is calm. Second line."))
        XCTAssertTrue(result.logLines.allSatisfy { $0.hasPrefix("[StudyMatch]") && !$0.contains("\n") })
    }

    func testCategoryTopicIsNotReportedAsSemanticMismatch() {
        let result = StudyMatchDiagnostics(
            scene_id: UUID(), name: "Food", learning_topic_id: "food",
            threshold: 0.42, rule: "sentence_or_purpose_v1", query_model: nil,
            legacy_search_description: nil, total_sentences: 1, included_count: 1,
            rows: [.init(sentence_id: UUID(), english: "Good food.", expression_purpose: nil,
                         sentence_model: nil, has_sentence_vector: false, has_purpose_vector: false,
                         sentence_similarity: nil, purpose_similarity: nil, included: true,
                         stored_source: "category", stored_score: 100, current_source: nil)]
        )
        let log = result.logLines.joined(separator: "\n")
        XCTAssertTrue(log.contains("NOT the semantic threshold"))
        XCTAssertTrue(log.contains("linkMismatch=false"))
        XCTAssertFalse(log.contains("truncated=true"))
    }
}
#endif
