import Foundation
import XCTest
@testable import 三句

@MainActor
final class StudyOverviewSnapshotTests: XCTestCase {
    private let session = SupabaseSession(
        accessToken: "token", refreshToken: "refresh", userID: "user",
        expiresAt: .distantFuture, isAnonymous: false
    )

    func testSuccessfulRefreshReturnsTheCompleteOverview() async throws {
        let service = StubStudyOverviewService()
        let sentenceID = UUID()
        service.favoriteCounts = [sentenceID: 4]
        let scene = makeScene()
        service.scenes = [scene]

        let snapshot = try await StudyOverviewSnapshot.load(
            from: service, session: session, favoriteSentenceIDs: [sentenceID]
        )

        XCTAssertEqual(snapshot.dueCount, 3)
        XCTAssertEqual(snapshot.todayCount, 2)
        XCTAssertEqual(snapshot.reviewableTodayCount, 2)
        XCTAssertEqual(snapshot.sentenceCount, 12)
        XCTAssertEqual(snapshot.masteredCount, 1)
        XCTAssertEqual(snapshot.favoriteCounts, [sentenceID: 4])
        XCTAssertEqual(snapshot.scenes, [scene])
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
        XCTAssertNil(snapshot.scenes)
    }

    func testPartialFailureOnlyLeavesFailedFieldsUnchanged() async throws {
        let service = StubStudyOverviewService()
        service.failedRequests = [.today, .scenes]
        let snapshot = try await StudyOverviewSnapshot.load(
            from: service, session: session, favoriteSentenceIDs: []
        )

        XCTAssertEqual(snapshot.dueCount, 3)
        XCTAssertNil(snapshot.todayCount)
        XCTAssertEqual(snapshot.sentenceCount, 12)
        XCTAssertNil(snapshot.scenes)
    }

    func testSuccessfulEmptyResponseCanClearStaleContent() async throws {
        let service = StubStudyOverviewService()
        service.dueCount = 0
        service.scenes = []
        let snapshot = try await StudyOverviewSnapshot.load(
            from: service, session: session, favoriteSentenceIDs: []
        )

        XCTAssertEqual(snapshot.dueCount, 0)
        XCTAssertEqual(snapshot.scenes, [])
        XCTAssertEqual(snapshot.favoriteCounts, [:])
        XCTAssertFalse(service.requests.contains(.favorites))
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
            XCTAssertEqual(service.requests, [.due])
        }
    }

    func testSlowRefreshKeepsExistingContentUntilAllResponsesArrive() async throws {
        let service = StubStudyOverviewService()
        let oldScene = makeScene(name: "Old topic")
        let newScene = makeScene(name: "New topic")
        var displayedScenes = [oldScene]
        var continuation: CheckedContinuation<[UserStudySceneSummary], Never>?
        let waitingForScenes = expectation(description: "Waiting for the final response")
        service.loadScenes = {
            await withCheckedContinuation {
                continuation = $0
                waitingForScenes.fulfill()
            }
        }

        let task = Task {
            let snapshot = try await StudyOverviewSnapshot.load(
                from: service, session: session, favoriteSentenceIDs: []
            )
            if let scenes = snapshot.scenes { displayedScenes = scenes }
        }
        await fulfillment(of: [waitingForScenes], timeout: 2)
        XCTAssertEqual(displayedScenes, [oldScene])

        continuation?.resume(returning: [newScene])
        try await task.value
        XCTAssertEqual(displayedScenes, [newScene])
    }

    private func makeScene(name: String = "Topic") -> UserStudySceneSummary {
        UserStudySceneSummary(id: UUID(), name: name, coverMemoryID: nil, summary: .empty)
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
    var scenes: [UserStudySceneSummary] = []
    var loadScenes: (() async -> [UserStudySceneSummary])?

    private func record(_ request: Request) throws {
        requests.append(request)
        if failedRequests.contains(request) { throw failure }
    }

    func fetchSentenceStudyDueCount(session: SupabaseSession) async throws -> Int {
        try record(.due)
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
        if let loadScenes { return await loadScenes() }
        return scenes
    }
}
