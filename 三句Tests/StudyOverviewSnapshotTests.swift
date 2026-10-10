import Foundation
import XCTest
@testable import 三句

@MainActor
final class StudyOverviewSnapshotTests: XCTestCase {
    private let session = SupabaseSession(
        accessToken: "token", refreshToken: "refresh", userID: "user",
        expiresAt: .distantFuture, isAnonymous: false
    )

    func testSuccessfulRefreshReturnsFavoritesWithoutLoadingCustomTopics() async throws {
        let service = StubStudyOverviewService()
        let sentenceID = UUID()
        service.favoriteCounts = [sentenceID: 4]
        let snapshot = try await StudyOverviewSnapshot.load(
            from: service, session: session, favoriteSentenceIDs: [sentenceID]
        )
        XCTAssertEqual(snapshot.dueCount, 3)
        XCTAssertEqual(snapshot.todayCount, 2)
        XCTAssertEqual(snapshot.reviewableTodayCount, 2)
        XCTAssertEqual(snapshot.sentenceCount, 12)
        XCTAssertEqual(snapshot.masteredCount, 1)
        XCTAssertEqual(snapshot.favoriteCounts, [sentenceID: 4])
        XCTAssertFalse(service.requests.contains(.scenes))
    }

    func testNetworkFailuresDoNotProduceEmptyReplacementData() async throws {
        let service = StubStudyOverviewService()
        service.failedRequests = Set(StubStudyOverviewService.Request.allCases)
        let snapshot = try await StudyOverviewSnapshot.load(
            from: service, session: session, favoriteSentenceIDs: [UUID()]
        )
        XCTAssertNil(snapshot.dueCount)
        XCTAssertNil(snapshot.todayCount)
        XCTAssertNil(snapshot.reviewableTodayCount)
        XCTAssertNil(snapshot.sentenceCount)
        XCTAssertNil(snapshot.masteredCount)
        XCTAssertNil(snapshot.favoriteCounts)
    }

    func testPartialFailureOnlyLeavesFailedFieldsUnchanged() async throws {
        let service = StubStudyOverviewService()
        service.failedRequests = [.today]
        let snapshot = try await StudyOverviewSnapshot.load(
            from: service, session: session, favoriteSentenceIDs: []
        )
        XCTAssertEqual(snapshot.dueCount, 3)
        XCTAssertNil(snapshot.todayCount)
        XCTAssertEqual(snapshot.sentenceCount, 12)
    }

    func testEmptyFavoritesSkipTheStudyCountQuery() async throws {
        let service = StubStudyOverviewService()
        service.dueCount = 0
        let snapshot = try await StudyOverviewSnapshot.load(
            from: service, session: session, favoriteSentenceIDs: []
        )
        XCTAssertEqual(snapshot.dueCount, 0)
        XCTAssertEqual(snapshot.favoriteCounts, [:])
        XCTAssertFalse(service.requests.contains(.favorites))
        XCTAssertFalse(service.requests.contains(.scenes))
    }

    func testCancellationStopsRefreshWithoutPublishingAnEmptyOverview() async {
        for error: Error in [CancellationError(), URLError(.cancelled)] {
            let service = StubStudyOverviewService()
            service.failedRequests = [.due]
            service.failure = error
            do {
                _ = try await StudyOverviewSnapshot.load(
                    from: service, session: session, favoriteSentenceIDs: []
                )
                XCTFail("Cancellation must abort the snapshot")
            } catch {
                XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled)
            }
        }
    }

    func testSlowRefreshKeepsExistingCountsUntilResponseArrives() async throws {
        let service = StubStudyOverviewService()
        var displayedCount = 8
        var continuation: CheckedContinuation<Int, Never>?
        let waiting = expectation(description: "Waiting for due count")
        service.loadDueCount = {
            await withCheckedContinuation { continuation = $0; waiting.fulfill() }
        }
        let task = Task {
            let snapshot = try await StudyOverviewSnapshot.load(
                from: service, session: session, favoriteSentenceIDs: []
            )
            if let count = snapshot.dueCount { displayedCount = count }
        }
        await fulfillment(of: [waiting], timeout: 2)
        XCTAssertEqual(displayedCount, 8)
        continuation?.resume(returning: 3)
        try await task.value
        XCTAssertEqual(displayedCount, 3)
    }
}

@MainActor
private final class StubStudyOverviewService: StudyOverviewFetching {
    enum Request: CaseIterable {
        case due, today, reviewable, sentences, mastered, favorites, scenes
    }

    var failedRequests: Set<Request> = []
    var failure: Error = URLError(.notConnectedToInternet)
    var requests: [Request] = []
    var dueCount = 3
    var favoriteCounts: [UUID: Int] = [:]
    var loadDueCount: (() async -> Int)?

    private func record(_ request: Request) throws {
        requests.append(request)
        if failedRequests.contains(request) { throw failure }
    }

    func fetchSentenceStudyDueCount(session: SupabaseSession) async throws -> Int {
        try record(.due)
        if let loadDueCount { return await loadDueCount() }
        return dueCount
    }

    func fetchSentenceStudyTodayCount(session: SupabaseSession) async throws -> Int {
        try record(.today)
        return 2
    }

    func fetchSentenceStudyReviewableTodayCount(session: SupabaseSession) async throws -> Int {
        try record(.reviewable)
        return 2
    }

    func fetchMemorySentencesCount(session: SupabaseSession) async throws -> Int {
        try record(.sentences)
        return 12
    }

    func fetchMasteredSentenceCount(session: SupabaseSession) async throws -> Int {
        try record(.mastered)
        return 1
    }

    func fetchSentenceStudyCounts(session: SupabaseSession, sentenceIDs: [UUID]) async throws -> [UUID: Int] {
        try record(.favorites)
        return favoriteCounts
    }

    func fetchUserStudySceneSummaries(session: SupabaseSession) async throws -> [UserStudySceneSummary] {
        try record(.scenes)
        XCTFail("Favorites must not load removed custom topics")
        return []
    }
}
