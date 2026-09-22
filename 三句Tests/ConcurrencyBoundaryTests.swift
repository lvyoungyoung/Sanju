import Foundation
import XCTest
@testable import 三句

@MainActor
final class ConcurrencyBoundaryTests: XCTestCase {
    func testLocalizationCanBeUsedFromBackgroundWork() async {
        let values = await Task.detached {
            (
                L10n.string("tests.missing_plain_key", "Fallback"),
                L10n.string("tests.missing_formatted_key", "Count: %d", 3)
            )
        }.value

        XCTAssertEqual(values.0, "Fallback")
        XCTAssertEqual(values.1, "Count: 3")
    }

    func testStudyTopicDefaultAndCodableWorkFromBackground() async throws {
        let topic = try await Task.detached {
            let favorites = Self.topicWithDefaultArgument()
            let data = try JSONEncoder().encode(favorites)
            return try JSONDecoder().decode(SentenceStudyTopic.self, from: data)
        }.value

        XCTAssertEqual(topic, .favorites)
        XCTAssertEqual(topic.rawValue, "favorites")
        XCTAssertTrue(topic.usesFavoriteQueue)
    }

    func testCustomStudyTopicStillValidatesAndPreservesItsIdentity() async throws {
        let topic = try await Task.detached {
            let topic = try XCTUnwrap(SentenceStudyTopic(rawValue: "  scene:example  "))
            XCTAssertNil(SentenceStudyTopic(rawValue: "  "))
            XCTAssertNil(SentenceStudyTopic(rawValue: String(repeating: "a", count: 65)))
            return try JSONDecoder().decode(SentenceStudyTopic.self, from: JSONEncoder().encode(topic))
        }.value

        XCTAssertEqual(topic.rawValue, "scene:example")
        XCTAssertFalse(topic.usesFavoriteQueue)
    }

    func testImageDataCanBeReadFromBackgroundWork() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let expectedData = Data([1, 2, 3])
        try expectedData.write(to: url)

        let data = await Task.detached {
            PersistenceDiagnostics.readData(from: url, operation: "Test background image read")
        }.value

        XCTAssertEqual(data, expectedData)
    }

    func testMissingImageDataReturnsNilFromBackgroundWork() async {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let data = await Task.detached {
            PersistenceDiagnostics.readData(from: url, operation: "Test missing image read")
        }.value

        XCTAssertNil(data)
    }

    nonisolated private static func topicWithDefaultArgument(
        _ topic: SentenceStudyTopic = .favorites
    ) -> SentenceStudyTopic {
        topic
    }
}
