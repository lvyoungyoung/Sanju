import Foundation
import XCTest
@testable import 三句

@MainActor
final class AlbumSpeechPrefetchTests: XCTestCase {
    private var directory: URL!
    private var cache: SpeechAudioCache!
    private var source: AlbumSpeechSource!
    private var queue: AlbumSpeechPrefetcher!
    private let pcm = Data([0, 0, 1, 0])

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        cache = SpeechAudioCache(directory: directory)
        source = AlbumSpeechSource()
        queue = AlbumSpeechPrefetcher(cache: cache, namespace: "test", fetch: source.fetch)
    }

    override func tearDown() {
        queue.cancelAll()
        source.cancelAll()
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func testOnlyNextFiveAreCheckedSeriallyAndCachedOnCompletion() async throws {
        update((1...8).map { "Sentence \($0)" })
        for index in 0..<5 {
            try await waitUntil { self.source.requests.count == index + 1 }
            XCTAssertEqual(source.requests[index].text, "Sentence \(index + 1)")
            source.send(pcm, at: index)
            source.finish(at: index)
        }
        try await waitForCache("Sentence 5")
        await Task.yield()
        XCTAssertEqual(source.requests.count, 5)
        for index in 1...5 {
            let audio = await cache.load(key("Sentence \(index)"))
            XCTAssertEqual(audio, pcm)
        }
    }

    func testSmallLibrarySkipsCurrentDuplicateBlankAndCachedSentences() async throws {
        await cache.save(pcm, key: key("Cached"))
        update(["Current", " Next ", "Next", "", "Cached"])
        try await waitUntil { self.source.requests.count == 1 }
        XCTAssertEqual(source.requests[0].text, "Next")
        source.send(pcm, at: 0)
        source.finish(at: 0)
        try await waitForCache("Next")
        update(["Next", "Cached", "New"])
        try await waitUntil { self.source.requests.count == 2 }
        XCTAssertEqual(source.requests[1].text, "New")
    }

    func testRollingWindowKeepsRelevantFlightAndDropsOldQueuedSentences() async throws {
        update(["Next", "Old second", "Old third"])
        try await waitUntil { self.source.requests.count == 1 }
        update(["Next", "New second"])
        source.send(pcm, at: 0)
        source.finish(at: 0)
        try await waitUntil { self.source.requests.count == 2 }
        XCTAssertEqual(source.requests.map(\.text), ["Next", "New second"])
    }

    func testQuickSwipesCancelObsoleteFlightAndIgnoreItsLateAudio() async throws {
        update(["Old", "Old queued"])
        try await waitUntil { self.source.requests.count == 1 }
        update(["New"])
        try await waitUntil { self.source.requests.count == 2 }
        source.send(pcm, at: 0)
        source.finish(at: 0)
        source.send(pcm, at: 1)
        source.finish(at: 1)
        try await waitForCache("New")
        let oldAudio = await cache.load(key("Old"))
        XCTAssertNil(oldAudio)
        XCTAssertEqual(source.requests.map(\.text), ["Old", "New"])
    }

    func testNewlyVisibleSentenceCanAdoptItsPrefixAndLiveAudio() async throws {
        update(["Next", "Later"])
        try await waitUntil { self.source.requests.count == 1 }
        source.send(Data([0]), at: 0)
        queue.setForegroundBusy(true)
        update(["Later", "Last"], current: "Next")
        let stream = try XCTUnwrap(queue.takeOver(text: "Next", voice: .mia, owner: "alice"))
        var received = Data()
        let playback = Task { for try await chunk in stream { received.append(chunk) } }
        try await waitUntil { received == Data([0]) }
        source.send(Data([1]), at: 0)
        try await waitUntil { received == Data([0, 1]) }
        source.finish(at: 0)
        try await playback.value
        XCTAssertEqual(source.requests.count, 1)
        queue.setForegroundBusy(false)
        try await waitUntil { self.source.requests.count == 2 }
        XCTAssertEqual(source.requests[1].text, "Later")
    }

    func testCurrentSentenceHasPriorityBeforeLookaheadStarts() async throws {
        queue.setForegroundBusy(true)
        update(["Next", "Later"])
        await Task.yield()
        XCTAssertTrue(source.requests.isEmpty)
        // Once the current audio source is ready, lookahead may run during playback.
        queue.setForegroundBusy(false)
        try await waitUntil { self.source.requests.count == 1 }
        XCTAssertEqual(source.requests[0].text, "Next")
    }

    func testDifferentVoiceOwnerOrTextCannotAdoptFlight() async throws {
        update(["Next"])
        try await waitUntil { self.source.requests.count == 1 }
        XCTAssertNil(queue.takeOver(text: "Next", voice: .dean, owner: "alice"))
        XCTAssertNil(queue.takeOver(text: "Next", voice: .mia, owner: "bob"))
        XCTAssertNil(queue.takeOver(text: "Other", voice: .mia, owner: "alice"))
    }

    func testDisabledWindowWaitsAndPauseCannotCachePartialAudio() async throws {
        update(["Next"], enabled: false)
        await Task.yield()
        XCTAssertTrue(source.requests.isEmpty)
        update(["Next"])
        try await waitUntil { self.source.requests.count == 1 }
        source.send(Data([0]), at: 0)
        queue.setEnabled(false)
        source.send(Data([1]), at: 0)
        source.finish(at: 0)
        await Task.yield()
        let partial = await cache.load(key("Next"))
        XCTAssertNil(partial)
        update(["Next"])
        try await waitUntil { self.source.requests.count == 2 }
        source.send(pcm, at: 1)
        source.finish(at: 1)
        try await waitForCache("Next")
    }

    func testClosingAlbumCancelsPendingWorkAndAdoptedPlayback() async throws {
        update(["Next", "Later"])
        try await waitUntil { self.source.requests.count == 1 }
        let stream = try XCTUnwrap(queue.takeOver(text: "Next", voice: .mia, owner: "alice"))
        queue.cancelAll()
        source.send(pcm, at: 0)
        source.finish(at: 0)
        do {
            for try await _ in stream {}
            XCTFail("Closed album must cancel the stream")
        } catch { XCTAssertTrue(error is CancellationError) }
        let audio = await cache.load(key("Next"))
        XCTAssertNil(audio)
        XCTAssertEqual(source.requests.count, 1)
    }

    func testAccountAndVoiceChangesKeepCachesIsolated() async throws {
        update(["Next"])
        try await waitUntil { self.source.requests.count == 1 }
        queue.updateWindow(currentText: "Current", upcoming: ["Next"], voice: .dean, owner: "bob", enabled: true)
        try await waitUntil { self.source.requests.count == 2 }
        source.send(pcm, at: 0)
        source.finish(at: 0)
        source.send(pcm, at: 1)
        source.finish(at: 1)
        try await waitUntil { await self.cache.load(self.key("Next", owner: "bob", voice: .dean)) != nil }
        let old = await cache.load(key("Next"))
        XCTAssertNil(old)
        XCTAssertEqual(source.requests[1].owner, "bob")
        XCTAssertEqual(source.requests[1].voice, .dean)
    }

    func testFailureAndRepeatedSwipesDoNotBurnMoreSpeechQuota() async throws {
        update(["Next", "Later"])
        try await waitUntil { self.source.requests.count == 1 }
        let stream = try XCTUnwrap(queue.takeOver(text: "Next", voice: .mia, owner: "alice"))
        source.send(pcm, at: 0)
        source.fail(at: 0)
        do {
            for try await _ in stream {}
            XCTFail("Failed stream must not complete successfully")
        } catch {}
        for index in 0..<10 { update(["New \(index)"]) }
        await Task.yield()
        XCTAssertEqual(source.requests.count, 1)
        let audio = await cache.load(key("Next"))
        XCTAssertNil(audio)
    }

    func testIncompletePCMAndTimeoutAreNotCached() async throws {
        queue = AlbumSpeechPrefetcher(cache: cache, namespace: "test", timeout: .milliseconds(100), fetch: source.fetch)
        update(["Next"])
        try await waitUntil { self.source.requests.count == 1 }
        let stream = try XCTUnwrap(queue.takeOver(text: "Next", voice: .mia, owner: "alice"))
        source.send(Data([0]), at: 0)
        source.finish(at: 0)
        do {
            for try await _ in stream {}
            XCTFail("Odd PCM cannot be cached")
        } catch {}
        let odd = await cache.load(key("Next"))
        XCTAssertNil(odd)
        queue.cancelAll()
        update(["Timeout"])
        try await waitUntil { self.source.requests.count == 2 }
        let stalled = try XCTUnwrap(queue.takeOver(text: "Timeout", voice: .mia, owner: "alice"))
        do {
            for try await _ in stalled {}
            XCTFail("Deadline must end an unresponsive request")
        } catch { XCTAssertTrue(error.localizedDescription.contains("speech_prefetch_timeout")) }
        source.send(pcm, at: 1)
        source.finish(at: 1)
        let late = await cache.load(key("Timeout"))
        XCTAssertNil(late)
    }

    func testServiceStartsOnlyInsideAlbumAndRemainsSilent() async throws {
        let speech = SpeechService(cache: cache, albumPrefetchFetch: source.fetch)
        defer { speech.cancelAlbumSpeechPrefetch(); speech.stop() }
        speech.ownerProvider = { "alice" }
        speech.updateAlbumSpeechPrefetch(id: UUID(), current: "Current", upcoming: ["Next"], enabled: true)
        await Task.yield()
        XCTAssertTrue(source.requests.isEmpty)
        let scope = speech.beginAlbumSpeechPrefetch()
        speech.updateAlbumSpeechPrefetch(id: scope, current: "Current", upcoming: ["Next"], enabled: true)
        try await waitUntil { self.source.requests.count == 1 }
        XCTAssertNil(speech.activeText)
        XCTAssertNil(speech.loadingText)
        XCTAssertFalse(speech.isUsingSystemVoice)
        speech.endAlbumSpeechPrefetch(id: scope)
        speech.updateAlbumSpeechPrefetch(id: scope, current: "Current", upcoming: ["Later"], enabled: true)
        await Task.yield()
        XCTAssertEqual(source.requests.count, 1)
    }

    func testServicePlaybackSharesPrefetchAndStaleViewCannotStopNewScope() async throws {
        let speech = SpeechService(cache: cache, albumPrefetchFetch: source.fetch)
        defer { speech.cancelAlbumSpeechPrefetch(); speech.stop() }
        speech.ownerProvider = { "alice" }
        speech.sessionProvider = { XCTFail("Playback should adopt prefetch, not make another request"); throw CloudSpeechError.noSession }
        let old = speech.beginAlbumSpeechPrefetch()
        let scope = speech.beginAlbumSpeechPrefetch()
        speech.endAlbumSpeechPrefetch(id: old)
        speech.updateAlbumSpeechPrefetch(id: scope, current: "Current", upcoming: ["Next"], enabled: true)
        try await waitUntil { self.source.requests.count == 1 }
        speech.speak("Next")
        await Task.yield()
        speech.speak("Next")
        XCTAssertEqual(source.requests.count, 1)
        XCTAssertEqual(speech.loadingText, "Next")
        speech.stop()
    }

    func testServiceChangesVoiceOnlyForActiveAlbumWindow() async throws {
        let speech = SpeechService(cache: cache, albumPrefetchFetch: source.fetch)
        defer { speech.cancelAlbumSpeechPrefetch(); speech.stop() }
        speech.ownerProvider = { "alice" }
        let scope = speech.beginAlbumSpeechPrefetch()
        speech.updateAlbumSpeechPrefetch(id: scope, current: "Current", upcoming: ["Next"], enabled: true)
        try await waitUntil { self.source.requests.count == 1 }
        let newVoice: SpeechVoice = speech.selectedVoice == .dean ? .mia : .dean
        speech.applyVoice(newVoice)
        try await waitUntil { self.source.requests.count == 2 }
        XCTAssertEqual(source.requests[1].voice, newVoice)
        speech.endAlbumSpeechPrefetch(id: scope)
        speech.applyVoice(newVoice == .mia ? .dean : .mia)
        await Task.yield()
        XCTAssertEqual(source.requests.count, 2)
    }

    func testServicePausesOfflineOrBackgroundWithoutStartingRequests() async throws {
        let speech = SpeechService(cache: cache, albumPrefetchFetch: source.fetch)
        defer { speech.cancelAlbumSpeechPrefetch(); speech.stop() }
        speech.ownerProvider = { "alice" }
        let scope = speech.beginAlbumSpeechPrefetch()
        speech.updateAlbumSpeechPrefetch(id: scope, current: "Current", upcoming: ["Next"], enabled: false)
        await Task.yield()
        XCTAssertTrue(source.requests.isEmpty)
        speech.updateAlbumSpeechPrefetch(id: scope, current: "Current", upcoming: ["Next"], enabled: true)
        try await waitUntil { self.source.requests.count == 1 }
        speech.pauseAlbumSpeechPrefetch(id: scope)
        speech.applyVoice(speech.selectedVoice == .dean ? .mia : .dean)
        await Task.yield()
        XCTAssertEqual(source.requests.count, 1)
    }

    private func update(_ upcoming: [String], current: String = "Current", enabled: Bool = true) {
        queue.updateWindow(currentText: current, upcoming: upcoming, voice: .mia, owner: "alice", enabled: enabled)
    }

    private func key(_ text: String, owner: String = "alice", voice: SpeechVoice = .mia) -> String {
        SpeechAudioCache.key(text: text, scope: "test|\(owner)", voice: voice)
    }

    private func waitForCache(_ text: String) async throws {
        try await waitUntil { await self.cache.load(self.key(text)) != nil }
    }

    private func waitUntil(_ condition: @MainActor () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await condition()) {
            guard ContinuousClock.now < deadline else {
                XCTFail("Timed out waiting for test condition", file: file, line: line)
                throw CloudSpeechError.invalidResponse
            }
            try await Task.sleep(for: .milliseconds(2))
        }
    }
}

@MainActor
private final class AlbumSpeechSource {
    private(set) var requests: [AlbumSpeechPrefetcher.Request] = []
    private var callbacks: [Int: @MainActor (Data) -> Void] = [:]
    private var continuations: [Int: CheckedContinuation<Data, Error>] = [:]
    private var audio: [Int: Data] = [:]

    func fetch(_ request: AlbumSpeechPrefetcher.Request, onAudio: @escaping @MainActor (Data) -> Void) async throws -> Data {
        let index = requests.count
        requests.append(request)
        callbacks[index] = onAudio
        audio[index] = Data()
        // Ignores cancellation deliberately to exercise late server replies.
        return try await withCheckedThrowingContinuation { continuations[index] = $0 }
    }

    func send(_ chunk: Data, at index: Int) {
        audio[index, default: Data()].append(chunk)
        callbacks[index]?(chunk)
    }

    func finish(at index: Int) {
        callbacks.removeValue(forKey: index)
        continuations.removeValue(forKey: index)?.resume(returning: audio[index] ?? Data())
    }

    func fail(at index: Int) {
        callbacks.removeValue(forKey: index)
        continuations.removeValue(forKey: index)?.resume(throwing: CloudSpeechError.invalidAudio)
    }

    func cancelAll() {
        for index in Array(continuations.keys) { fail(at: index) }
    }
}
