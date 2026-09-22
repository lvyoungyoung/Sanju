import Foundation
import XCTest
@testable import 三句

@MainActor
final class SpeechAudioTests: XCTestCase {
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
