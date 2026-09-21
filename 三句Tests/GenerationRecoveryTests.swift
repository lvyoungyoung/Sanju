import XCTest
@testable import 三句

final class GenerationRecoveryTests: XCTestCase {
    func testDuplicatePendingRequestRecoversInsteadOfStartingAgain() throws {
        let payload = Data(#"{"error":"生成仍在处理中，请稍后查看回忆。","code":"generation_in_progress"}"#.utf8)
        let decoded = try JSONDecoder().decode(SupabaseAPIError.self, from: payload)
        XCTAssertEqual(SupabaseServiceError.apiError(decoded.message).generationRecoveryDisposition, .recoverable)
    }

    func testUncertainCommitTimeoutCanRecover() {
        XCTAssertEqual(SupabaseServiceError.apiError("request timed out").generationRecoveryDisposition, .recoverable)
    }

    func testPolicyRejectionStillStopsImmediately() {
        XCTAssertEqual(SupabaseServiceError.apiError("generation_policy_violation").generationRecoveryDisposition, .nonRecoverable)
    }
}
