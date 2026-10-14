import XCTest
@testable import 三句

@MainActor
final class MultilingualAPIErrorTests: XCTestCase {
    func testStableCodesRenderSafeMessagesFromPlainAndJSONErrors() throws {
        for code in ["generation_disabled", "invalid_generation_spec", "request_context_mismatch",
                     "unsupported_explanation_language", "generation_pending", "generation_failed",
                     "preference_revision_conflict", "invalid_learning_material"] {
            let expected = try XCTUnwrap(MultilingualAPIError.message(for: code))
            for payload in [code, "{\"code\":\"\(code)\",\"error\":\"internal detail\"}",
                            "{\"code\":\"P0001\",\"message\":\"\(code)\"}",
                            "{\"error\":{\"code\":\"\(code)\"}}"] {
                XCTAssertEqual(MultilingualAPIError.code(in: payload), code)
                XCTAssertEqual(SupabaseServiceError.apiError(payload).errorDescription, expected)
                XCTAssertFalse(expected.contains("internal detail"))
                XCTAssertNotEqual(expected, code)
            }
        }
    }

    func testOnlyBoundedExactCodesAreMapped() {
        XCTAssertNil(MultilingualAPIError.code(in: "future_multilingual_error"))
        XCTAssertNil(MultilingualAPIError.code(in: "prefix_generation_disabled_suffix"))
        XCTAssertNil(MultilingualAPIError.code(in: "{\"details\":\"generation_disabled\"}"))
        XCTAssertNil(MultilingualAPIError.code(in: "not JSON {generation_disabled}"))
    }

    func testDisplayMappingDoesNotRewriteRawPayloadOrRecoveryDisposition() {
        let raw = "{\"code\":\"generation_pending\",\"error\":\"original detail\"}"
        let error = SupabaseServiceError.apiError(raw)
        _ = error.errorDescription
        guard case .apiError(let stored) = error else { return XCTFail("Raw API error must be retained") }
        XCTAssertEqual(stored, raw)
        guard case .recoverable = error.generationRecoveryDisposition else {
            return XCTFail("Pending generation must remain recoverable")
        }
        guard case .unknown = SupabaseServiceError.apiError("request_context_mismatch").generationRecoveryDisposition else {
            return XCTFail("Display mapping must not discard an uncertain pending request")
        }
    }
}
