import Foundation
import XCTest
@testable import 三句

@MainActor
final class GuestMemoryMigrationTests: XCTestCase {
    func testSixSentenceMigrationUsesDatabasePositionsZeroThroughFive() throws {
        let memory = makeMemory(sentenceCount: 6)
        let payloads = SupabaseMemorySentenceInsertPayload.memoryCopy(for: memory)
        XCTAssertEqual(payloads.map(\.sortOrder), Array(0..<6))
        let data = try JSONEncoder().encode(payloads)
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertEqual(rows.compactMap { $0["sort_order"] as? Int }, Array(0..<6))
        XCTAssertTrue(rows.allSatisfy { (0..<6).contains($0["sort_order"] as? Int ?? -1) })
    }

    func testThreeSentenceMigrationRemainsSupported() {
        let payloads = SupabaseMemorySentenceInsertPayload.memoryCopy(for: makeMemory(sentenceCount: 3))
        XCTAssertEqual(payloads.map(\.sortOrder), [0, 1, 2])
    }

    func testRetryKeepsOriginalIDsGroupsFavoritesAndContent() throws {
        let memory = makeMemory(sentenceCount: 6)
        let payloads = SupabaseMemorySentenceInsertPayload.memoryCopy(for: memory)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        XCTAssertEqual(try encoder.encode(payloads), try encoder.encode(SupabaseMemorySentenceInsertPayload.memoryCopy(for: memory)))
        for (payload, sentence) in zip(payloads, memory.sentences) {
            XCTAssertEqual(payload.id, sentence.id.uuidString.lowercased())
            XCTAssertEqual(payload.memoryID, memory.id.uuidString.lowercased())
            XCTAssertEqual(payload.english, sentence.english)
            XCTAssertEqual(payload.chinese, sentence.chinese)
            XCTAssertEqual(payload.presentationGroup, sentence.presentationGroup.rawValue)
            XCTAssertEqual(payload.isFavorite, sentence.isFavorite)
            XCTAssertEqual(payload.learningTopicIDs, sentence.learningTopicIDs)
        }
    }

    func testIncompleteRemoteMemoryDoesNotSuppressMigrationRetry() {
        let memory = makeMemory(sentenceCount: 6)
        let manager = CloudSyncManager()
        let incompleteRecord = SupabaseMemoryRecord(
            id: memory.id.uuidString,
            imagePath: "current-user/memory.jpg",
            createdAt: memory.createdAt,
            tags: nil,
            sentences: []
        )
        let remoteMemories = manager.makeRemoteMemories(from: [incompleteRecord])
        XCTAssertTrue(remoteMemories.isEmpty)
        let result = manager.reconcileLocalMemories(
            localMemories: [memory], remoteMemories: remoteMemories, sessionUserID: "current-user"
        )
        XCTAssertEqual(result.memories.count, 1)
        XCTAssertFalse(result.memories[0].syncedToAccount)
        let plan = manager.makePlan(
            localMemories: result.memories, remoteMemories: remoteMemories,
            queuedGuestMemories: [memory], queuedMemoryDeletions: [],
            queuedFavoriteChanges: [], queuedLocalStudyProgress: []
        )
        XCTAssertEqual(plan.queuedGuestMemoriesCount, 1)
    }

    private func makeMemory(sentenceCount: Int) -> MemoryEntry {
        MemoryEntry(
            id: UUID(), createdAt: Date(timeIntervalSince1970: 1_000),
            imageData: Data([1, 2, 3]), syncedToAccount: false,
            sentences: (0..<sentenceCount).map { index in
                SentenceRecord(
                    english: "English sentence \(index).", chinese: "Sentence translation \(index).",
                    learningTopicIDs: ["food"],
                    presentationGroup: index < 3 ? .whatISee : .whatIDSay,
                    isFavorite: index == 4
                )
            }
        )
    }
}
