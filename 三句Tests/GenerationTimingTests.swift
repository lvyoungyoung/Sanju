import Foundation
import XCTest
@testable import 三句

@MainActor
final class GenerationTimingTests: XCTestCase {
    func testParsesOrderedServerDurations() {
        let values = GenerationTiming.serverDurations("auth;dur=12.5, mimo;dur=2050.0, finalize;dur=18, total;dur=2080.5")
        XCTAssertEqual(values.map(\.stage), ["auth", "mimo", "finalize", "total"])
        XCTAssertEqual(values.map(\.milliseconds), [12.5, 2050, 18, 2080.5])
    }

    func testRejectsUntrustedOrInvalidMetrics() {
        let values = GenerationTiming.serverDurations("secret;dur=1, auth;dur=NaN, mimo;dur=inf, kimi;dur=-1, total;dur=3600001, profile;dur=no, auth;dur=4, auth;dur=99, moderation;dur=0")
        XCTAssertEqual(values.map(\.stage), ["auth", "moderation"])
        XCTAssertEqual(values.map(\.milliseconds), [4, 0])
        XCTAssertTrue(GenerationTiming.serverDurations("").isEmpty)
        XCTAssertTrue(GenerationTiming.serverDurations(String(repeating: "auth;dur=1,", count: 1000)).isEmpty)
    }

    func testIncludesDeepSeekAndFallbackDurations() {
        let values = GenerationTiming.serverDurations("deepseek;dur=1800, model_result;dur=0.2, mimo;dur=20000, kimi;dur=2500, total;dur=24300")
        XCTAssertEqual(values.map(\.stage), ["deepseek", "model_result", "mimo", "kimi", "total"])
        XCTAssertEqual(values.map(\.milliseconds), [1800, 0.2, 20000, 2500, 24300])
    }

    func testElapsedTimeIsMillisecondsNotSeconds() {
        XCTAssertEqual(GenerationTiming.milliseconds(.milliseconds(1250)), "1250.0")
        XCTAssertEqual(GenerationTiming.milliseconds(.microseconds(1500)), "1.5")
        XCTAssertEqual(GenerationTiming.milliseconds(.seconds(-1)), "0.0")
    }

    func testDefaultTraceIsAUUID() {
        let timing = GenerationTiming()
        XCTAssertNotNil(UUID(uuidString: timing.requestID))
        XCTAssertEqual(timing.requestID, timing.requestID.lowercased())
    }
}
