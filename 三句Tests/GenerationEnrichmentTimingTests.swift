import Foundation
import XCTest
@testable import 三句

@MainActor
final class GenerationEnrichmentTimingTests: XCTestCase {
    private func snapshot(report: Bool = true) -> GenerationEnrichmentSnapshot {
        GenerationEnrichmentSnapshot(status: "completed", attempt: 1, report: report ? .init(version: 1, stages: [
            .init(stage: "metadata_generate", outcome: "success", ms: 1250.5),
            .init(stage: "job_total", outcome: "completed", ms: 2200)
        ]) : nil)
    }

    func testOnlyTrustedStagingURLsAreEnabled() {
        for url in ["https://api-staging.sanju.cc", "https://spb-bp1364k407p37qn7.supabase.opentrust.net"] {
            XCTAssertTrue(GenerationEnrichmentTiming.isStagingURL(url))
        }
        for url: String? in [nil, "", "https://api.sanju.cc", "https://spb-bp103246ivn7q0nl.supabase.opentrust.net", "https://api-staging.sanju.cc.evil.test", "http://api-staging.sanju.cc"] {
            XCTAssertFalse(GenerationEnrichmentTiming.isStagingURL(url))
        }
    }

    func testPrintsDurationsOnceAndWaitsForReportEvenAfterJobCompletes() async {
        var reads = 0
        var waits = 0
        var output: [String] = []
        await GenerationEnrichmentTiming.observe(isActive: { true }, fetchSnapshot: {
            reads += 1
            return self.snapshot(report: reads > 1)
        }, output: { output.append($0) }, wait: { waits += 1 })
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(waits, 1)
        XCTAssertEqual(output, [
            "background.metadata_generate ms=1250.5 outcome=success attempt=1",
            "background.job_total ms=2200.0 outcome=completed attempt=1"
        ])
    }

    func testSignOutOrBackgroundingDiscardsInFlightResponse() async {
        var active = true
        var output: [String] = []
        await GenerationEnrichmentTiming.observe(isActive: { active }, fetchSnapshot: {
            active = false
            return self.snapshot()
        }, output: { output.append($0) }, wait: {})
        XCTAssertTrue(output.isEmpty)
    }

    func testMissingMigrationOrNetworkFailureOnlyProducesDiagnosticMessage() async {
        var output: [String] = []
        await GenerationEnrichmentTiming.observe(isActive: { true }, fetchSnapshot: {
            throw URLError(.timedOut)
        }, output: { output.append($0) }, wait: {})
        XCTAssertEqual(output.count, 1)
        XCTAssertTrue(output[0].contains("background.timings_unavailable"))
    }

    func testExpiredBudgetDoesNotMakeAnyRequests() async {
        var output: [String] = []
        await GenerationEnrichmentTiming.observe(isActive: { true }, fetchSnapshot: {
            XCTFail("Must not keep polling after the diagnostic budget")
            return nil
        }, output: { output.append($0) }, wait: {}, budget: .zero)
        XCTAssertEqual(output.count, 1)
        XCTAssertTrue(output[0].contains("observation_timeout"))
    }

    func testUntrustedStageNamesAndInvalidDurationsAreNotPrinted() {
        let value = GenerationEnrichmentSnapshot(status: "completed", attempt: 1, report: .init(version: 1, stages: [
            .init(stage: "private text", outcome: "success", ms: 1),
            .init(stage: "metadata_generate", outcome: "secret", ms: 1),
            .init(stage: "purpose_embedding", outcome: "success", ms: .infinity),
            .init(stage: "sentence_embedding", outcome: "success", ms: -1),
            .init(stage: "job_total", outcome: "completed", ms: 2200)
        ]))
        XCTAssertEqual(GenerationEnrichmentTiming.lines(for: value), ["background.job_total ms=2200.0 outcome=completed attempt=1"])
    }
}
