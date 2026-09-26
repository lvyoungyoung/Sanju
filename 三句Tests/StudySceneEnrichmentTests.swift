import XCTest
@testable import 三句

final class StudySceneEnrichmentTests: XCTestCase {
    func testPendingStatusAndBoundedPollingDelay() throws {
        let response = try JSONDecoder().decode(StudySceneEnrichmentResponse.self, from: Data(
            #"{"enrichment":{"pendingCount":2,"completedCount":1,"failedCount":0,"retryAfterSeconds":0}}"#.utf8
        ))
        XCTAssertTrue(response.enrichment.isPending)
        XCTAssertEqual(response.enrichment.pollingDelay, 3)
        XCTAssertEqual(response.enrichment.completedCount, 1)
        let stopped = StudySceneEnrichmentStatus(pendingCount: 0, completedCount: 1, failedCount: 2, retryAfterSeconds: 900)
        XCTAssertFalse(stopped.isPending)
        XCTAssertEqual(stopped.pollingDelay, 30)
    }

    func testContinuationRequestCannotCreateOrEnrollNewWork() throws {
        let data = try JSONEncoder().encode(StudySceneEnrichmentRequest(scene_id: "scene"))
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(payload.keys), ["scene_id", "enrichment_status_only"])
        XCTAssertEqual(payload["enrichment_status_only"] as? Bool, true)
        XCTAssertNil(payload["name"])
    }
}
