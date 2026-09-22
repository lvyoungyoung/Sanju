import Foundation
import XCTest
@testable import 三句

@MainActor
final class SpeechAudioTests: XCTestCase {
    func testVoiceAndSpeedDefaultsAndInvalidSavedValues() throws {
        let suite = "SpeechSettingsTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(SpeechPreferences(defaults: defaults).voice, .mia)
        XCTAssertEqual(SpeechPreferences(defaults: defaults).speed, .normal)
        defaults.set("unknown", forKey: SpeechPreferenceKey.voice)
        defaults.set("fast", forKey: SpeechPreferenceKey.speed)
        XCTAssertEqual(SpeechPreferences(defaults: defaults).voice, .mia)
        XCTAssertEqual(SpeechPreferences(defaults: defaults).speed, .normal)
    }

    func testVoiceAndSpeedPersistAndPreviewDoesNotChangeSelection() throws {
        let suite = "SpeechSettingsTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let speech = SpeechService(defaults: defaults)
        speech.setVoice(.dean)
        speech.setSpeed(.slower)
        let restored = SpeechService(defaults: defaults)
        XCTAssertEqual(restored.selectedVoice, .dean)
        XCTAssertEqual(restored.selectedSpeed, .slower)
        speech.preview(.chloe)
        XCTAssertEqual(speech.selectedVoice, .dean)
        XCTAssertEqual(speech.loadingVoice, .chloe)
        speech.stop()
        speech.speak("Use the selected voice")
        XCTAssertEqual(speech.loadingVoice, .dean)
        speech.stop()
        XCTAssertEqual(SpeechPreferences(defaults: defaults).voice, .dean)
    }

    func testCacheSeparatesEveryVoiceAndRetainsMiaDefaultKey() {
        let keys = SpeechVoice.allCases.map { SpeechAudioCache.key(text: "Hello", scope: "account", voice: $0) }
        XCTAssertEqual(Set(keys).count, 4)
        XCTAssertEqual(keys[0], SpeechAudioCache.key(text: "Hello", scope: "account"))
        XCTAssertEqual(SpeechSpeed.normal.playbackRate, 1)
        XCTAssertEqual(SpeechSpeed.slower.playbackRate, 0.85)
    }

    func testHTTPDiagnosticsPreserveStatusAndSafeBackendCode() {
        let error = SpeechResponseDiagnostics.error(status: 503,
            body: Data(#"{"error":"speech_budget_unavailable"}"#.utf8))
        XCTAssertTrue(error.localizedDescription.contains("HTTP 503"))
        XCTAssertTrue(error.localizedDescription.contains("speech_budget_unavailable"))
        let provider = SpeechResponseDiagnostics.error(status: 502,
            body: Data(#"{"error":"speech_provider_rejected","providerStatus":401}"#.utf8))
        XCTAssertTrue(provider.localizedDescription.contains("MiMo HTTP 401"))
    }

    func testHTTPDiagnosticsNeverExposeArbitraryBodies() {
        for body in ["<html>secret proxy details</html>", #"{"error":"Bearer secret-token"}"#,
                     #"{"error":"eyJtoken.payload.signature","text":"private sentence"}"#] {
            let error = SpeechResponseDiagnostics.error(status: 502, body: Data(body.utf8))
            XCTAssertEqual(error.localizedDescription, "Speech HTTP 502; code=unknown")
        }
    }

    func testStreamingErrorsIdentifyFailureStage() {
        var stream = SpeechAudioStream()
        XCTAssertThrowsError(try stream.consume(#"{"type":"error","code":"speech_provider_timeout"}"#)) { error in
            XCTAssertTrue(error.localizedDescription.contains("speech_provider_timeout"))
        }
    }

    func testOnlyExplicitCompletionMakesAudioCacheable() throws {
        var stream = SpeechAudioStream()
        XCTAssertEqual(try stream.consume(#"{"type":"audio","data":"AAABAA=="}"#), Data([0, 0, 1, 0]))
        XCTAssertFalse(stream.isComplete)
        XCTAssertNil(try stream.consume(#"{"type":"done"}"#))
        XCTAssertTrue(stream.isComplete)
        XCTAssertThrowsError(try stream.consume(#"{"type":"done"}"#))
    }

    func testMalformedAndIncompleteAudioIsRejected() throws {
        for line in [#"{"type":"done"}"#, #"{"type":"error"}"#,
                     #"{"type":"audio","data":"!"}"#, #"{"type":"audio","data":""}"#, "bad json"] {
            var stream = SpeechAudioStream()
            XCTAssertThrowsError(try stream.consume(line))
        }
        var odd = SpeechAudioStream()
        _ = try odd.consume(#"{"type":"audio","data":"AA=="}"#)
        XCTAssertThrowsError(try odd.consume(#"{"type":"done"}"#))
    }

    func testPCMChunksCanSplitASample() throws {
        var stream = SpeechAudioStream()
        _ = try stream.consume(#"{"type":"audio","data":"AA=="}"#)
        _ = try stream.consume(#"{"type":"audio","data":"AQ=="}"#)
        _ = try stream.consume(#"{"type":"done"}"#)
        XCTAssertEqual(stream.data, Data([0, 1]))
    }

    func testAudioSizeIsBounded() throws {
        var stream = SpeechAudioStream()
        let encoded = Data(repeating: 0, count: 100_000).base64EncodedString()
        let line = "{\"type\":\"audio\",\"data\":\"\(encoded)\"}"
        for _ in 0..<28 { _ = try stream.consume(line) }
        XCTAssertThrowsError(try stream.consume(line))
    }

    func testCacheKeysSeparateTextAccountsAndEnvironments() {
        let key = SpeechAudioCache.key(text: "Hello", scope: "staging|alice")
        XCTAssertEqual(key, SpeechAudioCache.key(text: "Hello", scope: "staging|alice"))
        XCTAssertNotEqual(key, SpeechAudioCache.key(text: "Hello", scope: "production|alice"))
        XCTAssertNotEqual(key, SpeechAudioCache.key(text: "Hello", scope: "staging|bob"))
        XCTAssertNotEqual(key, SpeechAudioCache.key(text: "Hello!", scope: "staging|alice"))
    }

    func testCacheRoundTripAndRejectsOddLengthAudio() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = SpeechAudioCache(directory: directory)
        await cache.save(Data([0, 0, 1, 0]), key: "complete")
        let loaded = await cache.load("complete")
        XCTAssertEqual(loaded, Data([0, 0, 1, 0]))
        await cache.save(Data([0]), key: "incomplete")
        let invalid = await cache.load("incomplete")
        XCTAssertNil(invalid)
    }

    func testRepeatedTapDoesNotStartAnotherRequestAndStopCancelsPendingWork() async {
        let speech = SpeechService()
        let started = expectation(description: "Preparing session")
        let cancelled = expectation(description: "Pending work cancelled")
        var requests = 0
        speech.ownerProvider = { UUID().uuidString }
        speech.sessionProvider = {
            requests += 1
            started.fulfill()
            do { try await Task.sleep(for: .seconds(60)) }
            catch { cancelled.fulfill(); throw error }
            throw CancellationError()
        }
        speech.speak("Same sentence")
        await fulfillment(of: [started], timeout: 2)
        speech.speak("Same sentence")
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(speech.loadingText, "Same sentence")
        speech.stop()
        XCTAssertNil(speech.loadingText)
        await fulfillment(of: [cancelled], timeout: 2)
    }

    func testSwitchingSentencesIgnoresCancelledRequestCleanup() async {
        let speech = SpeechService()
        let firstStarted = expectation(description: "First request")
        let secondStarted = expectation(description: "Second request")
        let firstCancelled = expectation(description: "First cancelled")
        var requests = 0
        speech.ownerProvider = { UUID().uuidString }
        speech.sessionProvider = {
            requests += 1
            let number = requests
            (number == 1 ? firstStarted : secondStarted).fulfill()
            do { try await Task.sleep(for: .seconds(60)) }
            catch {
                if number == 1 { firstCancelled.fulfill() }
                throw error
            }
            throw CancellationError()
        }
        speech.speak("First")
        await fulfillment(of: [firstStarted], timeout: 2)
        speech.speak("Second")
        await fulfillment(of: [firstCancelled, secondStarted], timeout: 2)
        XCTAssertEqual(speech.loadingText, "Second")
        XCTAssertEqual(requests, 2)
        speech.stop()
    }
}
