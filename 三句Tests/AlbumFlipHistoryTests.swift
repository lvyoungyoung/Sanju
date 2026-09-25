import XCTest
@testable import 三句

@MainActor
final class AlbumFlipHistoryTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    private let memoryID = UUID()
    private let sentenceID = UUID()
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUp() {
        super.setUp()
        suite = "AlbumFlipHistoryTests.\(UUID())"
        defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func event(_ feedback: AlbumFlipFeedback = .familiar, after: TimeInterval = 0,
                       zone: String = "Asia/Shanghai") -> AlbumFlipEvent {
        AlbumFlipEvent(id: UUID(), memoryID: memoryID, sentenceID: sentenceID, feedback: feedback,
                       occurredAt: start.addingTimeInterval(after), timeZoneID: zone)
    }

    private func store(_ owner: String = "alice") -> AlbumFlipHistoryStore {
        AlbumFlipHistoryStore(defaults: defaults, ownerID: owner)
    }

    func testSameDayDoesNotAdvanceAndDifferentDaysGraduallyReduceWeight() {
        var record = AlbumFlipProgress.applying(event(), to: nil)
        XCTAssertEqual(record.familiarityLevel, 1)
        record = .applying(event(after: 60), to: record)
        XCTAssertEqual(record.familiarityLevel, 1)
        var weights = [record.selectionWeight(at: record.lastFeedbackAt, timeZone: .gmt)]
        for day in 1...6 {
            record = .applying(event(after: Double(day) * 86_400), to: record)
            weights.append(record.selectionWeight(at: record.lastFeedbackAt, timeZone: .gmt))
        }
        XCTAssertEqual(record.familiarityLevel, 4)
        XCTAssertEqual(weights, [4, 2, 1, 1, 1, 1, 1])
        XCTAssertEqual(record.selectionWeight(at: record.lastFeedbackAt.addingTimeInterval(14 * 86_400), timeZone: .gmt), 6)
    }

    func testAgainResetsFamiliarityWithoutTouchingLearningRecords() throws {
        store().record(event())
        store().record(event(after: 86_400))
        let again = event(.again, after: 86_410)
        let history = store().record(again)
        let record = try XCTUnwrap(history.records[again.itemID])
        XCTAssertEqual(record.familiarityLevel, 0)
        XCTAssertEqual(record.selectionWeight(at: again.occurredAt, timeZone: .gmt), 24)
        XCTAssertNil(defaults.object(forKey: AppStorageKey.localSentenceStudyProgress))
        XCTAssertNil(defaults.object(forKey: AppStorageKey.remainingCredits))
    }

    func testDeviceTimeZoneDeterminesCalendarDay() {
        let first = event()
        // start is 22:13 UTC; two hours later crosses UTC midnight, not Shanghai midnight.
        let utc = AlbumFlipProgress.applying(event(after: 7_200, zone: "UTC"), to: .applying(first, to: nil))
        let shanghai = AlbumFlipProgress.applying(event(after: 7_200), to: .applying(first, to: nil))
        XCTAssertEqual(utc.familiarityLevel, 2)
        XCTAssertEqual(shanghai.familiarityLevel, 1)
    }

    func testDuplicateAndOutOfOrderEventsDoNotRevertNewerFeedback() {
        let first = event()
        let second = event(.again, after: 60)
        let current = AlbumFlipProgress.applying(second, to: .applying(first, to: nil))
        XCTAssertEqual(AlbumFlipProgress.applying(first, to: current), current)
        XCTAssertEqual(AlbumFlipProgress.applying(second, to: current), current)
    }

    func testPendingFeedbackSurvivesRestartAndIsAccountAndEnvironmentScoped() {
        let action = event()
        store().record(action)
        store().record(action)
        XCTAssertEqual(store().read().pending, [action])
        XCTAssertTrue(store("bob").read().records.isEmpty)
        XCTAssertTrue(store("guest").read().records.isEmpty)
        XCTAssertTrue(AlbumFlipHistoryStore(defaults: defaults, ownerID: "alice", namespace: "other").read().records.isEmpty)
    }

    func testAcknowledgementPreservesFeedbackMadeDuringRequest() throws {
        let first = event()
        let second = event(.again, after: 60)
        store().record(first)
        store().record(second)
        store().merge([.applying(first, to: nil)], acknowledging: [first])
        XCTAssertEqual(store().read().pending, [second])
        XCTAssertEqual(store().read().records[first.itemID]?.lastFeedback, .again)
        store().merge([.applying(second, to: .applying(first, to: nil))], acknowledging: [second])
        XCTAssertTrue(store().read().pending.isEmpty)
        XCTAssertEqual(store().read().records[first.itemID]?.familiarityLevel, 0)
    }

    func testGuestTransferPreservesEventsAndDoesNotMoveOtherMemories() {
        let action = event()
        store("guest").record(action)
        let unrelated = AlbumFlipEvent(id: UUID(), memoryID: UUID(), sentenceID: UUID(), feedback: .again,
                                      occurredAt: start, timeZoneID: "UTC")
        store("guest").record(unrelated)
        let original = MemoryEntry(id: memoryID, createdAt: start, imageData: Data(),
                                   sentences: [SentenceRecord(id: sentenceID, english: "Hello.", chinese: "Hi.")])
        var migrated = original
        migrated.sentences[0] = SentenceRecord(english: "Hello.", chinese: "Hi.")
        store("guest").transferGuestMemory(original, to: migrated, destination: store())
        store("guest").transferGuestMemory(original, to: migrated, destination: store())
        XCTAssertEqual(store().read().pending.count, 1)
        XCTAssertEqual(store().read().pending.first?.id, action.id)
        XCTAssertEqual(store().read().pending.first?.sentenceID, migrated.sentences[0].id)
        XCTAssertEqual(store("guest").read().pending, [unrelated])
        XCTAssertTrue(store("bob").read().records.isEmpty)
    }

    func testLegacyDirectionsAreImportedOnlyOnce() throws {
        let action = event()
        defaults.set(try JSONEncoder().encode([action.itemID: AlbumFlipFeedback.familiar]),
                     forKey: "sanju.albumFlip.feedback.alice")
        let first = store().read()
        XCTAssertEqual(first.records[action.itemID]?.familiarityLevel, 1)
        XCTAssertEqual(store().read().pending, first.pending)
        XCTAssertNil(defaults.object(forKey: "sanju.albumFlip.feedback.alice"))
    }

    func testSyncRetriesDurableOutboxAndDownloadsCloudHistory() async throws {
        let first = event()
        store().record(first)
        var fails = true
        var calls = 0
        let sync = AlbumFlipHistorySync(defaults: defaults, debounce: .zero, fetch: { _ in
            [.applying(first, to: nil)]
        }, upload: { owner, events in
            XCTAssertEqual(owner, "alice")
            XCTAssertEqual(events, [first])
            calls += 1
            if fails { throw URLError(.notConnectedToInternet) }
            return [.applying(first, to: nil)]
        })
        sync.activate(userID: "alice")
        await sync.waitForSync()
        XCTAssertEqual(store().read().pending, [first])
        fails = false
        sync.refresh()
        await sync.waitForSync()
        XCTAssertEqual(calls, 2)
        XCTAssertTrue(store().read().pending.isEmpty)
        XCTAssertEqual(store().read().records[first.itemID]?.lastFeedback, .familiar)
    }

    func testCloudResponseCannotLeakAfterAccountSwitch() async {
        let action = event()
        let started = expectation(description: "fetch started")
        var resume: CheckedContinuation<[AlbumFlipProgress], Never>?
        let sync = AlbumFlipHistorySync(defaults: defaults, debounce: .zero, fetch: { owner in
            if owner == "alice" {
                started.fulfill()
                return await withCheckedContinuation { resume = $0 }
            }
            return []
        }, upload: { _, _ in XCTFail("No pending events"); return [] })
        sync.activate(userID: "alice")
        await fulfillment(of: [started], timeout: 2)
        sync.activate(userID: "bob")
        resume?.resume(returning: [.applying(action, to: nil)])
        await sync.waitForSync()
        XCTAssertTrue(store().read().records.isEmpty)
        XCTAssertTrue(store("bob").read().records.isEmpty)
    }

    func testSyncWaitsForMemoryMigrationAndNeverUploadsGuestHistory() async {
        let action = event()
        store().record(action)
        var migrated = false
        var uploaded = 0
        let sync = AlbumFlipHistorySync(defaults: defaults, debounce: .zero,
                                       canUpload: { _, _ in migrated }, fetch: { _ in [] }, upload: { _, events in
            uploaded += events.count
            return [.applying(action, to: nil)]
        })
        sync.refresh()
        await sync.waitForSync()
        XCTAssertEqual(uploaded, 0)
        sync.activate(userID: "alice")
        await sync.waitForSync()
        XCTAssertEqual(uploaded, 0)
        XCTAssertEqual(store().read().pending, [action])
        migrated = true
        sync.refresh()
        await sync.waitForSync()
        XCTAssertEqual(uploaded, 1)
    }

    func testSwipesUploadWithoutRepeatedFullHistoryDownloads() async {
        var fetches = 0
        var uploads = 0
        let sync = AlbumFlipHistorySync(defaults: defaults, debounce: .zero, fetch: { _ in
            fetches += 1
            return []
        }, upload: { _, events in
            uploads += events.count
            return events.map { .applying($0, to: nil) }
        })
        sync.activate(userID: "alice")
        await sync.waitForSync()
        store().record(event())
        sync.uploadPending()
        await sync.waitForSync()
        XCTAssertEqual(fetches, 1)
        XCTAssertEqual(uploads, 1)
    }

    func testLargeOfflineOutboxIsUploadedInBoundedBatches() async {
        var history = AlbumFlipHistory()
        for index in 0..<205 { history.pending.append(event(after: Double(index))) }
        store().write(history)
        var sizes: [Int] = []
        let sync = AlbumFlipHistorySync(defaults: defaults, debounce: .zero, fetch: { _ in [] }, upload: { _, events in
            sizes.append(events.count)
            return []
        })
        sync.activate(userID: "alice")
        await sync.waitForSync()
        XCTAssertEqual(sizes, [100, 100, 5])
        XCTAssertTrue(store().read().pending.isEmpty)
    }

    func testRemoteHistoryRestoresWithoutAnyLocalFeedback() async {
        let action = event(.again)
        let sync = AlbumFlipHistorySync(defaults: defaults, debounce: .zero, fetch: { _ in
            [.applying(action, to: nil)]
        }, upload: { _, _ in XCTFail("No local feedback to upload"); return [] })
        sync.activate(userID: "alice")
        await sync.waitForSync()
        XCTAssertEqual(store().read().records[action.itemID]?.lastFeedback, .again)
        XCTAssertTrue(store().read().pending.isEmpty)
    }
}
