import CryptoKit
import SwiftUI
import XCTest
@testable import 三句

@MainActor
final class SentenceExplanationTests: XCTestCase {
    private func explanation(version: Int = 2, pointCount: Int = 1, exampleEnglish: String = "Let's take a little break.") -> SentenceExplanation {
        SentenceExplanation(
            version: version,
            points: (0..<pointCount).map { index in
                .init(title: index == 0 ? "take a little break" : "need",
                      explanation: index == 0 ? "休息一小会儿。take a break 是一个自然的日常搭配。" : "表示需要某物或做某事。",
                      example: .init(english: index == 0 ? exampleEnglish : "I need a warm cup of tea.",
                                     chinese: index == 0 ? "我们休息一小会儿吧。" : "我需要一杯热茶。"))
            }
        )
    }

    private func request(language: String = "zh", english: String = "I need a little break.", generate: Bool = false) -> SentenceExplanationRequest {
        SentenceExplanationRequest(sentenceID: UUID(), english: english, chinese: "我需要休息一下。", language: language, generate: generate)
    }

    func testEveryKeyExpressionRequiresItsOwnTranslatedExample() {
        XCTAssertTrue(explanation().isValid)
        XCTAssertTrue(explanation(pointCount: 2).isValid)
        XCTAssertFalse(explanation(version: 1).isValid)
        XCTAssertFalse(explanation(pointCount: 0).isValid)
        XCTAssertFalse(explanation(pointCount: 5).isValid)
        XCTAssertFalse(explanation(exampleEnglish: " ").isValid)
        XCTAssertFalse(explanation(exampleEnglish: String(repeating: "x", count: 301)).isValid)
        XCTAssertFalse(SentenceExplanation(version: 2, points: Array(repeating: explanation().points[0], count: 2)).isValid)
    }

    func testCacheKeyIsScopedByAccountContentAndLanguageNotGenerationFlag() {
        XCTAssertEqual(request().cacheKey(owner: "USER"), request(generate: true).cacheKey(owner: "user"))
        XCTAssertNotEqual(request().cacheKey(owner: "guest"), request().cacheKey(owner: "account"))
        XCTAssertNotEqual(request().cacheKey(owner: "user"), request(language: "en").cacheKey(owner: "user"))
        XCTAssertNotEqual(request().cacheKey(owner: "user"), request(english: "A new sentence.").cacheKey(owner: "user"))
    }

    func testCachePersistsCompleteContentWithoutTheRemovedSections() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = SentenceExplanationCache(directory: directory)
        let key = request().cacheKey(owner: "user")
        let initial = await cache.load(key: key)
        XCTAssertNil(initial)
        await cache.save(explanation(), key: key)
        let reopened = SentenceExplanationCache(directory: directory)
        let stored = await reopened.load(key: key)
        XCTAssertEqual(stored, explanation())
        let raw = try String(contentsOf: directory.appendingPathComponent(key + ".json"), encoding: .utf8)
        XCTAssertTrue(raw.contains("\"example\""))
        XCTAssertFalse(raw.contains("\"examples\""))
        XCTAssertFalse(raw.contains("\"exercise\""))
        let otherUser = await reopened.load(key: request().cacheKey(owner: "another-user"))
        XCTAssertNil(otherUser)
    }

    func testCacheRejectsPartialResultsAndMalformedFiles() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = SentenceExplanationCache(directory: directory)
        await cache.save(explanation(exampleEnglish: ""), key: "invalid")
        let invalid = await cache.load(key: "invalid")
        XCTAssertNil(invalid)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("broken".utf8).write(to: directory.appendingPathComponent("broken.json"))
        let broken = await cache.load(key: "broken")
        XCTAssertNil(broken)
    }

    func testOpeningWithoutSavedContentDoesNotGenerate() async {
        let model = SentenceExplanationModel()
        var calls = 0
        await model.load(generate: false) { calls += 1; return nil }
        XCTAssertEqual(calls, 1)
        XCTAssertNil(model.explanation)
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.isLoading)
    }

    func testSavedLookupDoesNotShowGenerationActivityAndStillAllowsExplicitGeneration() async {
        let model = SentenceExplanationModel()
        await model.load(generate: false) {
            XCTAssertTrue(model.isLoading)
            XCTAssertFalse(model.isGenerating)
            return nil
        }
        XCTAssertFalse(model.isLoading)
        XCTAssertFalse(model.isGenerating)
        await model.load(generate: true) {
            XCTAssertTrue(model.isLoading)
            XCTAssertTrue(model.isGenerating)
            return self.explanation()
        }
        XCTAssertEqual(model.explanation, explanation())
        XCTAssertFalse(model.isGenerating)
    }

    func testSavedContentPreventsRepeatedGeneration() async {
        let model = SentenceExplanationModel()
        await model.load(generate: false) { self.explanation() }
        await model.load(generate: true) { XCTFail("Cached explanation must be reused"); return nil }
        XCTAssertEqual(model.explanation, explanation())
    }

    func testFailureAllowsRetryAndNeverDisplaysPartialContent() async {
        let model = SentenceExplanationModel()
        await model.load(generate: true) { self.explanation(exampleEnglish: "") }
        XCTAssertNil(model.explanation)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertFalse(model.isLoading)
        await model.load(generate: true) { self.explanation() }
        XCTAssertEqual(model.explanation, explanation())
        XCTAssertNil(model.errorMessage)
    }

    func testDuplicateTapsDoNotStartConcurrentRequests() async {
        let model = SentenceExplanationModel()
        var continuation: CheckedContinuation<SentenceExplanation?, Never>?
        let pending = Task {
            await model.load(generate: true) { await withCheckedContinuation { continuation = $0 } }
        }
        await Task.yield()
        XCTAssertTrue(model.isGenerating)
        await model.load(generate: true) { XCTFail("Repeated tap must be ignored"); return nil }
        continuation?.resume(returning: explanation())
        await pending.value
        XCTAssertFalse(model.isLoading)
        XCTAssertEqual(model.explanation, explanation())
    }

    func testResetWhileRequestIsRunningDiscardsThePreviousAccountsResult() async {
        let model = SentenceExplanationModel()
        var continuation: CheckedContinuation<SentenceExplanation?, Never>?
        let pending = Task {
            await model.load(generate: true) { await withCheckedContinuation { continuation = $0 } }
        }
        await Task.yield()
        model.reset()
        continuation?.resume(returning: explanation())
        await pending.value
        XCTAssertNil(model.explanation)
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.isLoading)
    }

    func testCancellationDoesNotShowAFailure() async {
        let model = SentenceExplanationModel()
        await model.load(generate: true) { throw CancellationError() }
        XCTAssertNil(model.errorMessage)
        XCTAssertNil(model.explanation)
        XCTAssertFalse(model.isLoading)
    }

    func testNewCacheKeysDoNotReuseThePreviousFormat() throws {
        let input = request()
        let legacyData = try JSONEncoder().encode(["user", "1", input.english, input.chinese, input.language])
        let legacyKey = SHA256.hash(data: legacyData).map { String(format: "%02x", $0) }.joined()
        XCTAssertNotEqual(input.cacheKey(owner: "user"), legacyKey)
        let oldJSON = Data(#"{"version":1,"points":[{"title":"break","explanation":"休息"}],"examples":[],"exercise":{}}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(SentenceExplanation.self, from: oldJSON))
    }

    func testExplanationCardsRenderInBothThemesAndWithLargeText() throws {
        for scheme in [ColorScheme.light, .dark] {
            for size in [DynamicTypeSize.large, .accessibility1] {
                let view = SentenceExplanationContent(explanation: explanation(pointCount: 2))
                    .padding(20).frame(width: 375)
                    .background(AppSurfaceColor.page)
                    .environment(\.colorScheme, scheme)
                    .environment(\.dynamicTypeSize, size)
                let image = try XCTUnwrap(ImageRenderer(content: view).uiImage)
                XCTAssertEqual(image.size.width, 375)
                XCTAssertGreaterThan(image.size.height, 300)
                let attachment = XCTAttachment(image: image)
                attachment.name = "SentenceExplanation-\(scheme)-\(size)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }
}
