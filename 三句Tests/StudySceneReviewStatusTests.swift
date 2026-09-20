import XCTest
@testable import 三句

final class StudySceneReviewStatusTests: XCTestCase {
    func testSuccessfulBatchContinuesPendingWork() throws {
        let status = try decode("{\"reviewedCount\":20,\"pendingCount\":12,\"retryAfterSeconds\":1}")
        XCTAssertEqual(status.reviewedCount, 20)
        XCTAssertTrue(status.shouldContinueAutomatically)
    }

    func testCompletedAndDeferredBatchesStopPolling() throws {
        let completed = try decode("{\"reviewedCount\":20,\"pendingCount\":0,\"retryAfterSeconds\":0}")
        let deferred = try decode("{\"reviewedCount\":0,\"pendingCount\":20,\"retryAfterSeconds\":30}")
        XCTAssertFalse(completed.shouldContinueAutomatically)
        XCTAssertFalse(deferred.shouldContinueAutomatically)
        XCTAssertEqual(deferred.pendingCount, 20)
    }

    func testAnotherActiveBatchCanBePolledWithoutResubmittingIt() throws {
        let busy = try decode("{\"reviewedCount\":0,\"pendingCount\":20,\"retryAfterSeconds\":2}")
        XCTAssertTrue(busy.shouldContinueAutomatically)
    }

    func testMalformedStatusIsNotTreatedAsCompleted() {
        XCTAssertThrowsError(try decode("{\"reviewedCount\":0}"))
    }

    private func decode(_ json: String) throws -> SupabaseStudySceneReviewStatus {
        try JSONDecoder().decode(SupabaseStudySceneReviewStatus.self, from: Data(json.utf8))
    }
}
