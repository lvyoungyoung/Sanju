import XCTest
@testable import 三句

@MainActor
final class StudyActivationStoreTests: XCTestCase {
    private func language(_ code: String) -> LearningLanguage { LearningLanguage(rawValue: code)! }
    private let zone = TimeZone(identifier: "UTC")!
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    private func url() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("activations.json") }

    func testGlobalBudgetRestartRetryDeletionAndOwnerIsolation() async throws {
        let file = url()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = try StudyActivationStore(fileURL: file)
        let ids = (0..<35).map { _ in UUID() }
        let now = date("2026-10-14T10:00:00Z")
        let sessionID = UUID()
        let first = try store.beginSession(ownerID: "guest", sessionID: sessionID, language: language("en"), candidateIDs: Array(ids.prefix(29)), seed: 1, at: now, timeZone: zone)
        XCTAssertEqual(first.sentenceIDs.count, 29)
        let reopened = try StudyActivationStore(fileURL: file)
        XCTAssertEqual(try reopened.beginSession(ownerID: "guest", sessionID: sessionID, language: language("en"), candidateIDs: Array(ids.prefix(29)), seed: 1, at: now.addingTimeInterval(86400), timeZone: zone), first)
        let last = try reopened.beginSession(ownerID: "guest", sessionID: UUID(), language: language("ja"), candidateIDs: Array(ids.suffix(6)), seed: 2, at: now, timeZone: zone)
        XCTAssertEqual(last.sentenceIDs.count, 1)
        XCTAssertEqual(reopened.remainingNew(ownerID: "guest", at: now, timeZone: zone), 0)
        // Removing a sentence from subsequent candidates does not remove its ledger entry.
        let empty = try reopened.beginSession(ownerID: "guest", sessionID: UUID(), language: language("fr"), candidateIDs: [UUID()], seed: 3, at: now, timeZone: zone)
        XCTAssertTrue(empty.sentenceIDs.isEmpty)
        XCTAssertEqual(reopened.remainingNew(ownerID: "other", at: now, timeZone: zone), 30)
        XCTAssertThrowsError(try reopened.beginSession(ownerID: "guest", sessionID: sessionID, language: language("ja"), candidateIDs: first.requestedIDs, seed: 1, at: now, timeZone: zone))
    }

    func testOldAndUnfinishedProgressDoesNotConsumeAnotherDay() async throws {
        let file = url()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = try StudyActivationStore(fileURL: file)
        let ids = (0..<31).map { _ in UUID() }
        let now = date("2026-10-14T10:00:00Z")
        try store.importLegacyProgress(ownerID: "guest", sentenceIDs: [ids[0]])
        let first = try store.beginSession(ownerID: "guest", sessionID: UUID(), language: language("en"), candidateIDs: ids, seed: 0, at: now, timeZone: zone)
        XCTAssertEqual(first.sentenceIDs.count, 31)
        XCTAssertEqual(store.remainingNew(ownerID: "guest", at: now, timeZone: zone), 0)
        let tomorrow = now.addingTimeInterval(86400)
        _ = try store.beginSession(ownerID: "guest", sessionID: UUID(), language: language("en"), candidateIDs: ids, seed: 0, at: tomorrow, timeZone: zone)
        XCTAssertEqual(store.remainingNew(ownerID: "guest", at: tomorrow, timeZone: zone), 30)
    }

    func testMergeOverflowIsDurableIdempotentAndTimeZoneAware() async throws {
        let file = url()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = try StudyActivationStore(fileURL: file)
        let now = date("2026-10-14T01:00:00Z")
        let records = (0..<40).map { _ in StudyActivationStore.Activation(ownerID: "guest", sentenceID: UUID(), firstActivatedAt: now, isLegacy: false) }
        try store.merge(ownerID: "account", activations: records, at: now)
        try store.merge(ownerID: "account", activations: records, at: now)
        XCTAssertEqual(store.remainingNew(ownerID: "account", at: now, timeZone: zone), 0)
        XCTAssertEqual(store.remainingNew(ownerID: "account", at: date("2026-10-14T10:00:00Z"), timeZone: TimeZone(identifier: "America/Los_Angeles")!), 30)
        let reopened = try StudyActivationStore(fileURL: file)
        XCTAssertEqual(reopened.remainingNew(ownerID: "account", at: now, timeZone: zone), 0)
        XCTAssertThrowsError(try reopened.merge(ownerID: "account", activations: records, at: now.addingTimeInterval(-60)))
    }

    func testCorruptFileIsNotSilentlyOverwritten() async throws {
        let file = url()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = Data("broken".utf8)
        try bytes.write(to: file)
        XCTAssertThrowsError(try StudyActivationStore(fileURL: file))
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }

    func testLegacyImportNeverRefundsANewActivation() async throws {
        let file = url()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = try StudyActivationStore(fileURL: file)
        let id = UUID()
        let now = date("2026-10-14T10:00:00Z")
        _ = try store.beginSession(ownerID: "guest", sessionID: UUID(), language: .japanese,
            candidateIDs: [id], seed: 4, at: now, timeZone: zone)
        try store.importLegacyProgress(ownerID: "guest", sentenceIDs: [id])
        XCTAssertEqual(store.remainingNew(ownerID: "guest", at: now, timeZone: zone), 29)
    }
}
