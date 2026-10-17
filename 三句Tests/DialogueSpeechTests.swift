import AVFoundation
import Combine
import Foundation
import XCTest
@testable import 三句

@MainActor
final class DialogueSpeechTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suite: String!
    private var cache: SpeechAudioCache!
    private var speech: SpeechService!
    private var source: DialogueSpeechSource!
    private var subscriptions: Set<AnyCancellable> = []
    private var started: [SpeechRequest] = []
    private let namespace = CloudSpeechClient().cacheNamespace
    private let pcm = Data(repeating: 0, count: 7_200) // 150 ms at 24 kHz, PCM16 mono.

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        suite = "DialogueSpeechTests.\(UUID())"
        defaults = UserDefaults(suiteName: suite)!
        cache = SpeechAudioCache(directory: directory)
        source = DialogueSpeechSource()
        speech = SpeechService(defaults: defaults, cache: cache, albumPrefetchFetch: source.fetch)
        speech.ownerProvider = { "alice" }
        speech.accountRevisionProvider = { 7 }
        speech.sessionProvider = {
            XCTFail("Dialogue tests must use cached or mocked audio, never the live API")
            throw CloudSpeechError.noSession
        }
        speech.$activeRequest.compactMap { $0 }.sink { [weak self] in
            self?.started.append($0)
        }.store(in: &subscriptions)
    }

    override func tearDown() {
        speech.stop()
        speech.cancelAlbumSpeechPrefetch()
        source.cancelAll()
        subscriptions.removeAll()
        started.removeAll()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func testCachedSequencePlaysInOrderWithFullStateDuringNaturalGaps() async throws {
        let a = request("Hello.", voice: .dean)
        let b = request("Good morning.", voice: .chloe)
        let requests = [a, b, a]
        await seed([a, b])
        var lastEnd: ContinuousClock.Instant?
        var wasActive = false
        var gaps: [Duration] = []
        speech.$activeRequest.dropFirst().sink { value in
            if value == nil, wasActive {
                lastEnd = .now
            } else if value != nil, let end = lastEnd {
                gaps.append(end.duration(to: .now))
                lastEnd = nil
            }
            wasActive = value != nil
        }.store(in: &subscriptions)

        speech.speakSequence(requests)
        XCTAssertEqual(speech.sequenceRequests, requests)
        try await waitForGap()
        XCTAssertEqual(started, [a])
        XCTAssertEqual(speech.sequenceRequests, requests)
        try await waitUntil { self.speech.sequenceRequests.isEmpty }

        XCTAssertEqual(started, requests)
        XCTAssertEqual(gaps.count, 2)
        XCTAssertTrue(gaps.allSatisfy { $0 >= .milliseconds(300) })
        XCTAssertNil(speech.activeRequest)
        XCTAssertFalse(speech.isUsingSystemVoice)
        XCTAssertTrue(source.requests.isEmpty)
    }

    func testScenarioSequencePlaysThreeDistinctLinesAndReplacementDropsOldThirdLine() async throws {
        let requests = [request("Would you like some coffee?", voice: .dean),
                        request("Yes, a small cup would be lovely.", voice: .chloe),
                        request("I'll get one for you too.", voice: .dean)]
        let replacement = request("A new scenario begins.", voice: .dean)
        await seed(requests + [replacement])
        speech.speakSequence(requests)
        try await waitUntil { self.speech.sequenceRequests.isEmpty }
        XCTAssertEqual(started, requests)

        started.removeAll()
        speech.speakSequence(requests)
        try await waitForGap()
        speech.speakSequence([replacement])
        try await waitUntil { self.speech.sequenceRequests.isEmpty }
        try await settleGap()
        XCTAssertEqual(started, [requests[0], replacement])
        XCTAssertTrue(source.requests.isEmpty)
    }

    func testStopDuringBufferedPlaybackIgnoresLateCompletion() async throws {
        let requests = [request("First"), request("Must not start")]
        await seed(requests, audio: Data(repeating: 0, count: 48_000))
        speech.speakSequence(requests)
        try await waitUntil { self.speech.loadingText == nil }
        XCTAssertEqual(speech.activeRequest, requests[0])
        speech.stop()
        XCTAssertTrue(speech.sequenceRequests.isEmpty)
        try await Task.sleep(for: .milliseconds(1_400))
        XCTAssertEqual(started, [requests[0]])
        XCTAssertNil(speech.activeRequest)
    }

    func testStopDuringGapCancelsPendingNextTurn() async throws {
        let requests = [request("First"), request("Must not start")]
        await seed(requests)
        speech.speakSequence(requests)
        try await waitForGap()
        speech.stop()
        XCTAssertTrue(speech.sequenceRequests.isEmpty)
        try await settleGap()
        XCTAssertEqual(started, [requests[0]])
        XCTAssertNil(speech.activeRequest)
    }

    func testReplacingSequenceDuringPlaybackOrGapCannotReviveOldQueue() async throws {
        let old = [request("Old first"), request("Old second")]
        let replacement = [request("New first"), request("New second")]
        await seed(old + replacement)
        for replaceInGap in [false, true] {
            started.removeAll()
            speech.speakSequence(old)
            if replaceInGap { try await waitForGap() }
            speech.speakSequence(replacement)
            XCTAssertEqual(speech.sequenceRequests, replacement)
            try await waitUntil { self.speech.sequenceRequests.isEmpty }
            try await settleGap()
            XCTAssertEqual(started, [old[0]] + replacement)
        }
    }

    func testBothSingleSpeechEntryPointsReplaceSequenceDuringGap() async throws {
        let old = [request("Old first"), request("Old second")]
        let single = request("Just this sentence")
        await seed(old + [single])
        for useText in [false, true] {
            started.removeAll()
            speech.speakSequence(old)
            try await waitForGap()
            if useText { speech.speak(single.text) } else { speech.speak(single) }
            XCTAssertTrue(speech.sequenceRequests.isEmpty)
            try await waitUntil { self.speech.activeRequest == nil }
            try await settleGap()
            XCTAssertEqual(started, [old[0], single])
        }
    }

    func testSingleRequestForSameLoadingUtteranceCancelsOnlySequence() async throws {
        let requests = [request("Pending first"), request("Never start")]
        try await prefetch(requests[0])
        speech.speakSequence(requests)
        try await waitUntil { self.speech.loadingText == requests[0].text }
        speech.speak(requests[0])
        XCTAssertTrue(speech.sequenceRequests.isEmpty)
        XCTAssertEqual(started, [requests[0]])
        source.send(pcm, at: 0)
        source.finish(at: 0)
        try await waitUntil { self.speech.activeRequest == nil }
        try await settleGap()
        XCTAssertEqual(started, [requests[0]])
        XCTAssertFalse(speech.isUsingSystemVoice)
    }

    func testAccountChangeDuringPlaybackCancelsSequenceAndLatePrefetch() async throws {
        let requests = [request("Pending first"), request("Never start")]
        try await prefetch(requests[0])
        speech.speakSequence(requests)
        source.send(pcm, at: 0)
        try await waitUntil { self.speech.loadingText == nil }
        speech.ownerProvider = { "bob" }
        speech.accountDidChange()
        source.send(pcm, at: 0)
        source.finish(at: 0)
        try await settleGap()
        XCTAssertTrue(speech.sequenceRequests.isEmpty)
        XCTAssertNil(speech.activeRequest)
        XCTAssertEqual(started, [requests[0]])
        let stale = await cache.load(request: requests[0], environment: namespace)
        XCTAssertNil(stale)
    }

    func testAccountRevisionChangeDuringGapIsRecheckedBeforeNextTurn() async throws {
        let requests = [request("First"), request("Never start")]
        await seed(requests)
        speech.speakSequence(requests)
        try await waitForGap()
        speech.accountRevisionProvider = { 8 }
        try await settleGap()
        XCTAssertTrue(speech.sequenceRequests.isEmpty)
        XCTAssertEqual(started, [requests[0]])
    }

    func testVoiceChangesCancelSequenceEvenWithDeferredSelectionHandler() async throws {
        let requests = [request("First"), request("Never start")]
        await seed(requests)
        speech.speakSequence(requests)
        speech.applyVoice(.dean)
        XCTAssertTrue(speech.sequenceRequests.isEmpty)
        try await settleGap()
        XCTAssertEqual(started, [requests[0]])

        started.removeAll()
        speech.speakSequence(requests)
        try await waitForGap()
        var selected: SpeechVoice?
        speech.onVoiceSelection = { selected = $0 }
        speech.setVoice(.chloe)
        XCTAssertEqual(selected, .chloe)
        XCTAssertTrue(speech.sequenceRequests.isEmpty)
        try await settleGap()
        XCTAssertEqual(started, [requests[0]])
    }

    func testReplyAdoptsPrefetchWithItsOriginalDescriptorAndCacheKey() async throws {
        let a = request("Hello", voice: .dean)
        let b = SpeechRequest(text: "Bonjour", language: .french, teachingLocale: .franceFrench,
                              owner: "alice", accountRevision: 7)
        await seed([a])
        try await prefetch(b)
        speech.speakSequence([a, b])
        try await waitUntil { self.speech.activeRequest == b }
        XCTAssertEqual(speech.sequenceRequests, [a, b])
        XCTAssertEqual(source.requests.map(\.speech), [b])
        XCTAssertFalse(source.requests[0].usesLegacyAPI)
        source.send(pcm, at: 0)
        source.finish(at: 0)
        try await waitUntil { self.speech.sequenceRequests.isEmpty }
        XCTAssertEqual(started, [a, b])
        XCTAssertFalse(speech.isUsingSystemVoice)
        let cached = await cache.load(request: b, environment: namespace)
        XCTAssertEqual(cached, pcm)
        let wrongDescriptor = await cache.load(request: request(b.text), environment: namespace)
        XCTAssertNil(wrongDescriptor)

        speech.speakSequence([a, b])
        try await waitUntil { self.speech.sequenceRequests.isEmpty }
        XCTAssertEqual(source.requests.count, 1)
        XCTAssertEqual(started, [a, b, a, b])
    }

    func testPrefetchCancellationStopsRatherThanAdvancingOrFallingBack() async throws {
        let requests = [request("Pending"), request("Never start")]
        try await prefetch(requests[0])
        speech.speakSequence(requests)
        speech.cancelAlbumSpeechPrefetch()
        try await waitUntil { self.speech.sequenceRequests.isEmpty }
        source.send(pcm, at: 0)
        source.finish(at: 0)
        try await settleGap()
        XCTAssertEqual(started, [requests[0]])
        XCTAssertNil(speech.activeRequest)
        XCTAssertFalse(speech.isUsingSystemVoice)
    }

    func testPrefetchFailureDoesNotAdvanceBeforeSystemFallbackFinishes() async throws {
        let requests = [request("First"), request("Reply")]
        let fallbackStarted = expectation(description: "Cloud failure starts fallback, not the next turn")
        speech.$isUsingSystemVoice.filter { $0 }.prefix(1).sink { [weak self] _ in
            guard let self else { return }
            // This is synchronous with fallback startup, before any system didFinish.
            XCTAssertEqual(speech.sequenceRequests, requests)
            XCTAssertEqual(speech.activeRequest, requests[0])
            XCTAssertFalse(started.contains(requests[1]))
            fallbackStarted.fulfill()
        }.store(in: &subscriptions)
        try await prefetch(requests[0])
        speech.speakSequence(requests)
        source.send(pcm, at: 0)
        source.fail(at: 0)
        await fulfillment(of: [fallbackStarted], timeout: 5)
        speech.stop()
        try await settleGap()
        XCTAssertFalse(started.contains(requests[1]))
    }

    func testOfflineSystemFallbackCompletesBothTurnsAndKeepsSequenceDuringGap() async throws {
        try requireSystemSpeechIntegration()
        let requests = [request("Hello."), request("Welcome.")]
        var offlineAttempts: [SpeechRequest] = []
        speech.sessionProvider = { [weak self] in
            if let active = self?.speech.activeRequest { offlineAttempts.append(active) }
            throw CloudSpeechError.noSession
        }
        speech.speakSequence(requests)
        try await waitUntil(timeout: .seconds(20)) {
            self.speech.activeRequest == nil && !self.speech.sequenceRequests.isEmpty
        }
        XCTAssertEqual(speech.sequenceRequests, requests)
        XCTAssertTrue(speech.isUsingSystemVoice)
        XCTAssertEqual(offlineAttempts, [requests[0]])
        XCTAssertFalse(started.contains(requests[1]))
        try await waitUntil(timeout: .seconds(20)) { self.speech.sequenceRequests.isEmpty }
        XCTAssertEqual(offlineAttempts, requests)
        // Each turn is published once for cloud preparation and again for system fallback.
        XCTAssertEqual(started, [requests[0], requests[0], requests[1], requests[1]])
        XCTAssertNil(speech.activeRequest)
        XCTAssertNil(speech.playbackError)
    }

    func testStoppingSystemFallbackCannotStartReply() async throws {
        try requireSystemSpeechIntegration()
        let requests = [request("This first sentence is deliberately long enough to stop before it finishes."),
                        request("Must not start")]
        speech.sessionProvider = { throw CloudSpeechError.noSession }
        speech.speakSequence(requests)
        try await waitUntil { self.speech.isUsingSystemVoice }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(speech.sequenceRequests, requests)
        speech.stop()
        try await settleGap()
        XCTAssertTrue(speech.sequenceRequests.isEmpty)
        XCTAssertNil(speech.activeRequest)
        XCTAssertFalse(started.contains(requests[1]))
    }

    private func requireSystemSpeechIntegration() throws {
        guard ProcessInfo.processInfo.environment["SANJU_SYSTEM_SPEECH_TESTS"] == "1" else {
            throw XCTSkip("Opt in on an audio-capable device with SANJU_SYSTEM_SPEECH_TESTS=1")
        }
        guard AVSpeechSynthesisVoice.speechVoices().contains(where: { $0.language == "en-US" }) else {
            throw XCTSkip("Requires an installed en-US system voice; no voice downloads are requested")
        }
    }

    func testSourceCompletionWithoutScheduledAudioDoesNotAdvance() async throws {
        let requests = [request("First"), request("Never start")]
        try await prefetch(requests[0])
        speech.speakSequence(requests)
        // The source delivers no complete sample, but claims to have completed valid PCM.
        source.send(Data([0]), at: 0)
        try await waitUntil { self.speech.loadingText == nil }
        source.finish(at: 0, returning: pcm)
        try await waitUntil { self.speech.sequenceRequests.isEmpty }
        try await settleGap()
        XCTAssertEqual(started, [requests[0]])
        XCTAssertEqual(speech.playbackErrorRequest, requests[0])
        XCTAssertNil(speech.activeRequest)
    }

    func testInterruptionDuringGapCancelsSequence() async throws {
        let requests = [request("First"), request("Never start")]
        await seed(requests)
        let interrupted = expectation(description: "Interruption posted as A finishes, before B starts")
        var firstStarted = false
        var interruptionPosted = false
        speech.$activeRequest.dropFirst().sink { [weak self] active in
            guard let self else { return }
            if active == requests[0] { firstStarted = true }
            guard active == nil, firstStarted, !interruptionPosted else { return }
            interruptionPosted = true
            XCTAssertEqual(started, [requests[0]])
            XCTAssertEqual(speech.sequenceRequests, requests)
            // Published delivers synchronously, before the completion hook schedules the gap.
            NotificationCenter.default.post(name: AVAudioSession.interruptionNotification,
                object: AVAudioSession.sharedInstance(),
                userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
            interrupted.fulfill()
        }.store(in: &subscriptions)
        speech.speakSequence(requests)
        await fulfillment(of: [interrupted], timeout: 5)
        try await waitUntil { self.speech.sequenceRequests.isEmpty }
        try await settleGap()
        XCTAssertEqual(started, [requests[0]])
        XCTAssertTrue(speech.sequenceRequests.isEmpty)
        XCTAssertNil(speech.activeRequest)
        XCTAssertFalse(speech.isUsingSystemVoice)
    }

    func testCancellationBeforeUncachedTaskRunsNeverRequestsSession() async {
        let requestedSession = expectation(description: "Cancelled cache miss must not request a session")
        requestedSession.isInverted = true
        speech.sessionProvider = {
            requestedSession.fulfill()
            throw CloudSpeechError.noSession
        }
        let requests = [request("Uncached first"), request("Uncached reply")]
        // Neither task can execute until this actor yields after the immediate cancellation.
        speech.speakSequence(requests)
        speech.speakSequence([])
        await fulfillment(of: [requestedSession], timeout: 0.5)
        XCTAssertEqual(started, [requests[0]])
        XCTAssertTrue(speech.sequenceRequests.isEmpty)
        XCTAssertNil(speech.activeRequest)
    }

    func testEmptyInvalidOrStaleSequenceDoesNotStartAnyUtterance() {
        let valid = request("Valid")
        let invalid = request(" ")
        speech.speakSequence([valid, invalid])
        XCTAssertTrue(speech.sequenceRequests.isEmpty)
        XCTAssertEqual(speech.playbackErrorRequest, invalid)
        XCTAssertTrue(started.isEmpty)
        speech.speakSequence([valid, .english("Wrong owner", owner: "bob")])
        XCTAssertTrue(speech.sequenceRequests.isEmpty)
        XCTAssertTrue(started.isEmpty)
        speech.speakSequence([valid])
        speech.speakSequence([])
        XCTAssertTrue(speech.sequenceRequests.isEmpty)
        XCTAssertNil(speech.activeRequest)
    }

    private func request(_ text: String, voice: SpeechVoice = .mia) -> SpeechRequest {
        .english(text, voice: voice, owner: "alice", accountRevision: 7)
    }

    private func seed(_ requests: [SpeechRequest], audio: Data? = nil) async {
        for request in requests {
            await cache.save(audio ?? pcm, key: SpeechAudioCache.key(request: request, environment: namespace))
        }
    }

    private func prefetch(_ request: SpeechRequest) async throws {
        let scope = speech.beginAlbumSpeechPrefetch()
        speech.updateAlbumSpeechPrefetch(id: scope, current: nil, upcoming: [request], enabled: true)
        try await waitUntil { self.source.requests.count == 1 }
    }

    private func waitForGap() async throws {
        try await waitUntil { self.speech.activeRequest == nil && !self.speech.sequenceRequests.isEmpty }
    }

    private func settleGap() async throws {
        try await Task.sleep(for: .milliseconds(600))
    }

    private func waitUntil(timeout: Duration = .seconds(5), _ condition: @MainActor () -> Bool,
                           file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("Timed out waiting for dialogue playback", file: file, line: line)
                throw CloudSpeechError.invalidResponse
            }
            try await Task.sleep(for: .milliseconds(2))
        }
    }
}

@MainActor
private final class DialogueSpeechSource {
    private(set) var requests: [AlbumSpeechPrefetcher.Request] = []
    private var callbacks: [Int: @MainActor (Data) -> Void] = [:]
    private var continuations: [Int: CheckedContinuation<Data, Error>] = [:]
    private var audio: [Int: Data] = [:]

    func fetch(_ request: AlbumSpeechPrefetcher.Request,
               onAudio: @escaping @MainActor (Data) -> Void) async throws -> Data {
        let index = requests.count
        requests.append(request)
        callbacks[index] = onAudio
        // Deliberately ignore cancellation so tests can deliver late audio and completion.
        return try await withCheckedThrowingContinuation { continuations[index] = $0 }
    }

    func send(_ chunk: Data, at index: Int) {
        audio[index, default: Data()].append(chunk)
        callbacks[index]?(chunk)
    }

    func finish(at index: Int, returning result: Data? = nil) {
        callbacks.removeValue(forKey: index)
        continuations.removeValue(forKey: index)?.resume(returning: result ?? audio[index] ?? Data())
    }

    func fail(at index: Int) {
        callbacks.removeValue(forKey: index)
        continuations.removeValue(forKey: index)?.resume(throwing: CloudSpeechError.invalidAudio)
    }

    func cancelAll() {
        for index in Array(continuations.keys) { fail(at: index) }
    }
}
