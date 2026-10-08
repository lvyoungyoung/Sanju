import SwiftUI
import XCTest
@testable import 三句

@MainActor
final class StudySceneSuggestionsTests: XCTestCase {
    private let topicIDs = Array(LearningTopic.all.prefix(5).map(\.id))

    func testFirstOpenFetchesSuggestionsWithoutLocalCategories() async {
        let model = StudySceneSuggestions()
        await model.refresh(accountRevision: UUID(), localTopicIDs: []) {
            XCTAssertEqual(model.loadState, .loading)
            XCTAssertTrue(model.displayedTopics.isEmpty)
            return Set(self.topicIDs)
        }
        XCTAssertEqual(model.loadState, .loaded)
        XCTAssertEqual(model.displayedTopics.count, 3)
        XCTAssertTrue(Set(model.displayedTopics.map(\.id)).isSubset(of: Set(topicIDs)))
    }

    func testLocalSuggestionsStayVisibleWhileCloudLoadsOrFails() async {
        let model = StudySceneSuggestions()
        let localIDs = Set(topicIDs.prefix(3))
        model.prepare(accountRevision: UUID(), localTopicIDs: localIDs)
        await model.refresh(accountRevision: UUID(), localTopicIDs: localIDs) {
            XCTAssertEqual(Set(model.displayedTopics.map(\.id)), localIDs)
            XCTAssertEqual(model.loadState, .loading)
            throw URLError(.notConnectedToInternet)
        }
        XCTAssertEqual(model.loadState, .failed)
        XCTAssertEqual(Set(model.displayedTopics.map(\.id)), localIDs)
    }

    func testReopeningPreservesCachedSuggestionsAndReadsCloudAgain() async {
        let model = StudySceneSuggestions()
        let account = UUID()
        var calls = 0
        await model.refresh(accountRevision: account, localTopicIDs: []) {
            calls += 1
            return Set(self.topicIDs)
        }
        let original = model.displayedTopics
        model.prepare(accountRevision: account, localTopicIDs: [])
        await model.refresh(accountRevision: account, localTopicIDs: []) {
            calls += 1
            XCTAssertEqual(model.displayedTopics, original)
            throw URLError(.timedOut)
        }
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(model.displayedTopics, original)
    }

    func testEmptyAndFailedResponsesAreDistinctAndCanBeRetried() async {
        let model = StudySceneSuggestions()
        let account = UUID()
        await model.refresh(accountRevision: account, localTopicIDs: []) { [] }
        XCTAssertEqual(model.loadState, .loaded)
        XCTAssertTrue(model.displayedTopics.isEmpty)
        await model.refresh(accountRevision: account, localTopicIDs: []) { throw URLError(.timedOut) }
        XCTAssertEqual(model.loadState, .failed)
        await model.refresh(accountRevision: account, localTopicIDs: []) { [self.topicIDs[0]] }
        XCTAssertEqual(model.loadState, .loaded)
        XCTAssertEqual(model.displayedTopics.map(\.id), [topicIDs[0]])
    }

    func testFreshResponseRemovesDeletedCloudCategories() async {
        let model = StudySceneSuggestions()
        let account = UUID()
        await model.refresh(accountRevision: account, localTopicIDs: []) { Set(self.topicIDs) }
        await model.refresh(accountRevision: account, localTopicIDs: []) { [] }
        XCTAssertTrue(model.displayedTopics.isEmpty)
        XCTAssertEqual(model.loadState, .loaded)
    }

    func testCloudCompletionDoesNotReshuffleExistingVisibleTags() async {
        let model = StudySceneSuggestions()
        let account = UUID()
        let localIDs = Set(topicIDs.prefix(3))
        model.prepare(accountRevision: account, localTopicIDs: localIDs)
        let original = model.displayedTopics
        await model.refresh(accountRevision: account, localTopicIDs: localIDs) { Set(self.topicIDs) }
        XCTAssertEqual(model.displayedTopics, original)
    }

    func testShufflePicksThreeDifferentKnownTopicsAndChangesTheBatch() {
        let model = StudySceneSuggestions()
        model.prepare(accountRevision: UUID(), localTopicIDs: Set(topicIDs + ["obsolete-topic"]))
        for _ in 0..<20 {
            let previous = Set(model.displayedTopics)
            model.shuffle()
            XCTAssertEqual(Set(model.displayedTopics).count, 3)
            XCTAssertNotEqual(Set(model.displayedTopics), previous)
            XCTAssertTrue(model.displayedTopics.allSatisfy { topicIDs.contains($0.id) })
        }
    }

    func testClosingSheetDiscardsLateResponse() async {
        let model = StudySceneSuggestions()
        let gate = SuggestionResponseGate()
        let started = expectation(description: "Request started")
        let task = Task {
            await model.refresh(accountRevision: UUID(), localTopicIDs: []) {
                await gate.wait(started: started)
            }
        }
        await fulfillment(of: [started], timeout: 2)
        model.cancelLoading()
        gate.resume(with: Set(topicIDs))
        await task.value
        XCTAssertEqual(model.loadState, .idle)
        XCTAssertTrue(model.displayedTopics.isEmpty)
    }

    func testAccountSwitchDiscardsOldResponseAndCachedSuggestions() async {
        let model = StudySceneSuggestions()
        let gate = SuggestionResponseGate()
        let started = expectation(description: "Old account request started")
        let task = Task {
            await model.refresh(accountRevision: UUID(), localTopicIDs: [self.topicIDs[0]]) {
                await gate.wait(started: started)
            }
        }
        await fulfillment(of: [started], timeout: 2)
        await model.refresh(accountRevision: UUID(), localTopicIDs: []) { [self.topicIDs[4]] }
        gate.resume(with: [topicIDs[0]])
        await task.value
        XCTAssertEqual(model.loadState, .loaded)
        XCTAssertEqual(model.displayedTopics.map(\.id), [topicIDs[4]])
    }

    func testSupersededRequestCannotOverwriteNewSuggestions() async {
        let model = StudySceneSuggestions()
        let account = UUID()
        let gate = SuggestionResponseGate()
        let started = expectation(description: "First request started")
        let task = Task {
            await model.refresh(accountRevision: account, localTopicIDs: []) {
                await gate.wait(started: started)
            }
        }
        await fulfillment(of: [started], timeout: 2)
        await model.refresh(accountRevision: account, localTopicIDs: []) { [self.topicIDs[4]] }
        gate.resume(with: [topicIDs[0]])
        await task.value
        XCTAssertEqual(model.displayedTopics.map(\.id), [topicIDs[4]])
    }

    func testCancellationIsNotDisplayedAsNetworkFailure() async {
        for error: Error in [CancellationError(), URLError(.cancelled)] {
            let model = StudySceneSuggestions()
            await model.refresh(accountRevision: UUID(), localTopicIDs: [topicIDs[0]]) { throw error }
            XCTAssertEqual(model.loadState, .idle)
            XCTAssertEqual(model.displayedTopics.count, 1)
        }
    }

    func testTopicReaderPaginatesAndDecodesOnlyCategoryFields() async throws {
        let json = """
        [{"learning_topic_ids":["\(topicIDs[0])"],"memories":{"id":"memory"}},
         {"learning_topic_ids":null},
         {"learning_topic_ids":["\(topicIDs[4])","\(topicIDs[0])","old-topic"]}]
        """
        let records = try JSONDecoder().decode([StudySceneTopicRecord].self, from: Data(json.utf8))
        var ranges: [Range<Int>] = []
        let result = try await StudySceneTopicReader.load(pageSize: 2) { range in
            ranges.append(range)
            return Array(records.dropFirst(range.lowerBound).prefix(range.count))
        }
        XCTAssertEqual(ranges, [0..<2, 2..<4])
        XCTAssertEqual(result, [topicIDs[0], topicIDs[4]])
    }

    func testTopicReaderDoesNotReturnPartialResultsOnLaterPageFailure() async {
        do {
            _ = try await StudySceneTopicReader.load(pageSize: 1) { range in
                if range.lowerBound == 0 { return [StudySceneTopicRecord(learningTopicIDs: [self.topicIDs[0]])] }
                throw URLError(.timedOut)
            }
            XCTFail("Incomplete reads should preserve the previous suggestions rather than replace them")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .timedOut)
        }
    }

    func testSuggestionStatesRenderInLightAndDarkAppearance() async throws {
        for state in [ContentLoadState.idle, .loaded, .failed] {
            for hasTopics in [false, true] {
                let model = StudySceneSuggestions()
                let account = UUID()
                let localIDs: Set<String> = hasTopics ? Set(topicIDs.prefix(3)) : []
                model.prepare(accountRevision: account, localTopicIDs: localIDs)
                if state != .idle {
                    await model.refresh(accountRevision: account, localTopicIDs: localIDs) {
                        if state == .failed { throw URLError(.timedOut) }
                        return []
                    }
                }
                for scheme in [ColorScheme.light, .dark] {
                    let content = StudySceneSuggestionSection(
                        suggestions: model, selectedTopicID: nil, onRefresh: {}, onSelect: { _ in }
                    )
                    .padding(24)
                    .frame(width: 320)
                    .background(AppSurfaceColor.page)
                    .environment(\.colorScheme, scheme)
                    let image = try XCTUnwrap(ImageRenderer(content: content).uiImage)
                    XCTAssertEqual(image.size.width, 320, accuracy: 1)
                    XCTAssertLessThan(image.size.height, 270)
                    let attachment = XCTAttachment(image: image)
                    attachment.name = "Suggestions-\(state)-\(hasTopics)-\(scheme)"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                }
            }
        }
    }
}

@MainActor
private final class SuggestionResponseGate {
    private var continuation: CheckedContinuation<Set<String>, Never>?

    func wait(started: XCTestExpectation) async -> Set<String> {
        await withCheckedContinuation {
            continuation = $0
            started.fulfill()
        }
    }

    func resume(with topicIDs: Set<String>) {
        continuation?.resume(returning: topicIDs)
        continuation = nil
    }
}
