import SwiftUI
import XCTest
@testable import 三句

@MainActor
final class SentenceExplanationTests: XCTestCase {
    private func explanation(answer: Int = 0, examples: Int = 2, options: [String] = ["take", "make", "do", "put"]) -> SentenceExplanation {
        SentenceExplanation(
            version: 1,
            points: [.init(title: "take a little break", explanation: "休息一小会儿。take a break 是一个自然的日常搭配。")],
            examples: (0..<examples).map { index in
                .init(english: index == 0 ? "Let's take a little break." : "I need a little break from work.",
                      chinese: index == 0 ? "我们休息一小会儿吧。" : "我需要暂时放下工作休息一下。")
            },
            exercise: .init(prompt: "选择合适的词。", sentence: "Let's ____ a little break.", options: options, answerIndex: answer, explanation: "take a break 表示休息。")
        )
    }

    private func request(language: String = "zh", english: String = "I need a little break.", generate: Bool = false) -> SentenceExplanationRequest {
        SentenceExplanationRequest(sentenceID: UUID(), english: english, chinese: "我需要休息一下。", language: language, generate: generate)
    }

    func testValidResultRequiresTwoExamplesAndAnUnambiguousExerciseShape() {
        XCTAssertTrue(explanation().isValid)
        XCTAssertFalse(explanation(answer: -1).isValid)
        XCTAssertFalse(explanation(answer: 4).isValid)
        XCTAssertFalse(explanation(examples: 1).isValid)
        XCTAssertFalse(explanation(options: ["take", "Take ", "do", "put"]).isValid)
        XCTAssertFalse(explanation(options: ["take", "make", "do"]).isValid)
    }

    func testCacheKeyIsScopedByAccountContentAndLanguageNotGenerationFlag() {
        XCTAssertEqual(request().cacheKey(owner: "USER"), request(generate: true).cacheKey(owner: "user"))
        XCTAssertNotEqual(request().cacheKey(owner: "guest"), request().cacheKey(owner: "account"))
        XCTAssertNotEqual(request().cacheKey(owner: "user"), request(language: "en").cacheKey(owner: "user"))
        XCTAssertNotEqual(request().cacheKey(owner: "user"), request(english: "A new sentence.").cacheKey(owner: "user"))
    }

    func testCachePersistsCompleteContentAndDoesNotPersistExerciseAttempts() async throws {
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
        XCTAssertFalse(raw.contains("selectedIndex"))
        let otherUser = await reopened.load(key: request().cacheKey(owner: "another-user"))
        XCTAssertNil(otherUser)
    }

    func testCacheRejectsPartialResultsAndMalformedFiles() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = SentenceExplanationCache(directory: directory)
        await cache.save(explanation(examples: 1), key: "invalid")
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

    func testSavedContentPreventsRepeatedGeneration() async {
        let model = SentenceExplanationModel()
        await model.load(generate: false) { self.explanation() }
        await model.load(generate: true) { XCTFail("Cached explanation must be reused"); return nil }
        XCTAssertEqual(model.explanation, explanation())
    }

    func testFailureAllowsRetryAndNeverDisplaysPartialContent() async {
        let model = SentenceExplanationModel()
        await model.load(generate: true) { self.explanation(examples: 1) }
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

    func testExerciseLocksFirstChoiceAndCanBePracticedAgain() {
        var attempt = SentenceExerciseAttempt()
        let exercise = explanation().exercise
        attempt.select(-1, exercise: exercise)
        XCTAssertNil(attempt.selectedIndex)
        attempt.select(2, exercise: exercise)
        XCTAssertEqual(attempt.selectedIndex, 2)
        attempt.select(0, exercise: exercise)
        XCTAssertEqual(attempt.selectedIndex, 2)
        attempt.reset()
        XCTAssertNil(attempt.selectedIndex)
        attempt.select(0, exercise: exercise)
        XCTAssertEqual(attempt.selectedIndex, exercise.answerIndex)
        XCTAssertNil(SentenceExerciseAttempt().selectedIndex)
    }

    func testExplanationCardsRenderInBothThemesAndWithLargeText() throws {
        for scheme in [ColorScheme.light, .dark] {
            for size in [DynamicTypeSize.large, .accessibility1] {
                let view = SentenceExplanationContent(explanation: explanation())
                    .padding(20).frame(width: 375)
                    .background(AppSurfaceColor.page)
                    .environment(\.colorScheme, scheme)
                    .environment(\.dynamicTypeSize, size)
                let image = try XCTUnwrap(ImageRenderer(content: view).uiImage)
                XCTAssertEqual(image.size.width, 375)
                XCTAssertGreaterThan(image.size.height, 400)
                let attachment = XCTAttachment(image: image)
                attachment.name = "SentenceExplanation-\(scheme)-\(size)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }
}
