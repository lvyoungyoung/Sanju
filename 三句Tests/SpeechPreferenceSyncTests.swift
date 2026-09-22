import Foundation
import XCTest
@testable import 三句

@MainActor
final class SpeechPreferenceSyncTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() async throws {
        suite = "SpeechPreferenceSyncTests.\(UUID())"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    func testGuestSelectionNeverCallsCloud() async {
        let sync = SpeechPreferenceSync(defaults: defaults, fetch: { _ in
            XCTFail("Guest preferences must stay local"); return nil
        }, save: { _, voice, _ in
            XCTFail("Guest preferences must stay local"); return voice
        })
        sync.select(.milo)
        sync.refresh()
        await sync.waitForSync()
        XCTAssertEqual(sync.status, .local)
        XCTAssertEqual(SpeechPreferences(defaults: defaults).voice, .milo)
    }

    func testCloudChoiceWinsOnLoginAndGuestChoiceReturnsOnLogout() async {
        defaults.set(SpeechVoice.milo.rawValue, forKey: SpeechPreferenceKey.voice)
        let sync = SpeechPreferenceSync(defaults: defaults, fetch: { _ in .chloe }, save: { _, voice, _ in
            XCTFail("Existing cloud preference should not be overwritten"); return voice
        })
        sync.activate(userID: "alice")
        await sync.waitForSync()
        XCTAssertEqual(sync.voice, .chloe)
        XCTAssertEqual(sync.status, .synced)
        sync.activate(userID: nil)
        XCTAssertEqual(sync.voice, .milo)
        XCTAssertEqual(sync.status, .local)
    }

    func testUnsetAccountSeedsGuestVoiceWithoutOverwritingConcurrentChoice() async {
        defaults.set(SpeechVoice.milo.rawValue, forKey: SpeechPreferenceKey.voice)
        let sync = SpeechPreferenceSync(defaults: defaults, fetch: { _ in nil }, save: { owner, voice, onlyIfUnset in
            XCTAssertEqual(owner, "alice")
            XCTAssertEqual(voice, .milo)
            XCTAssertTrue(onlyIfUnset)
            return .dean // Another device saved after our GET.
        })
        sync.activate(userID: "alice")
        await sync.waitForSync()
        XCTAssertEqual(sync.voice, .dean)
    }

    func testFailedSaveSurvivesRelaunchAndDoesNotLeakToAnotherAccount() async {
        let sync = SpeechPreferenceSync(defaults: defaults, fetch: { _ in .mia }, save: { _, _, _ in
            throw URLError(.notConnectedToInternet)
        })
        sync.activate(userID: "alice")
        await sync.waitForSync()
        sync.select(.dean)
        await sync.waitForSync()
        XCTAssertEqual(sync.status, .pending)

        var saves: [String] = []
        let restored = SpeechPreferenceSync(defaults: defaults, fetch: { _ in .chloe }, save: { owner, voice, onlyIfUnset in
            XCTAssertFalse(onlyIfUnset)
            XCTAssertEqual(voice, .dean)
            saves.append(owner)
            return voice
        })
        restored.activate(userID: "bob")
        await restored.waitForSync()
        XCTAssertEqual(restored.voice, .chloe)
        XCTAssertTrue(saves.isEmpty)
        restored.activate(userID: "alice")
        XCTAssertEqual(restored.voice, .dean)
        await restored.waitForSync()
        XCTAssertEqual(saves, ["alice"])
        XCTAssertEqual(restored.status, .synced)
    }

    func testDelayedFetchDoesNotOverwriteNewSelection() async {
        var sync: SpeechPreferenceSync!
        var saved: SpeechVoice?
        sync = SpeechPreferenceSync(defaults: defaults, fetch: { _ in
            sync.select(.dean)
            return .chloe
        }, save: { _, voice, _ in
            saved = voice
            return voice
        })
        sync.activate(userID: "alice")
        await sync.waitForSync()
        XCTAssertEqual(sync.voice, .dean)
        XCTAssertEqual(saved, .dean)
    }

    func testAccountSwitchDuringFetchIgnoresOldAccountResponse() async {
        var sync: SpeechPreferenceSync!
        sync = SpeechPreferenceSync(defaults: defaults, fetch: { owner in
            if owner == "alice" {
                sync.activate(userID: "bob")
                return .dean
            }
            return .chloe
        }, save: { _, voice, _ in voice })
        sync.activate(userID: "alice")
        await sync.waitForSync()
        XCTAssertEqual(sync.voice, .chloe)
        sync.activate(userID: nil)
        XCTAssertEqual(sync.voice, .mia)
    }

    func testRapidChoicesCoalesceAndInFlightSaveCannotLoseNewChoice() async {
        var sync: SpeechPreferenceSync!
        var saved: [SpeechVoice] = []
        sync = SpeechPreferenceSync(defaults: defaults, fetch: { _ in .mia }, save: { _, voice, _ in
            saved.append(voice)
            if voice == .milo { sync.select(.dean) }
            return voice
        })
        sync.activate(userID: "alice")
        await sync.waitForSync()
        sync.select(.chloe)
        sync.select(.milo)
        await sync.waitForSync()
        XCTAssertEqual(saved, [.milo, .dean])
        XCTAssertEqual(sync.voice, .dean)
        XCTAssertEqual(sync.status, .synced)
    }

    func testFailedFetchKeepsLocalChoiceUntilRetry() async {
        defaults.set(SpeechVoice.milo.rawValue, forKey: SpeechPreferenceKey.voice)
        var online = false
        let sync = SpeechPreferenceSync(defaults: defaults, fetch: { _ in
            guard online else { throw URLError(.notConnectedToInternet) }
            return .dean
        }, save: { _, voice, _ in
            XCTFail("Failed fetch must not overwrite cloud state"); return voice
        })
        sync.activate(userID: "alice")
        await sync.waitForSync()
        XCTAssertEqual(sync.voice, .milo)
        XCTAssertEqual(sync.status, .pending)
        online = true
        sync.refresh()
        await sync.waitForSync()
        XCTAssertEqual(sync.voice, .dean)
        XCTAssertEqual(sync.status, .synced)
    }

    func testSpeechVoiceResponseDecodesNullAndAllSupportedVoices() throws {
        let decoder = JSONDecoder()
        XCTAssertNil(try decoder.decode(SupabaseSpeechVoiceRecord.self, from: Data(#"{"speech_voice":null}"#.utf8)).voice)
        for voice in SpeechVoice.allCases {
            let data = try JSONSerialization.data(withJSONObject: ["speech_voice": voice.rawValue])
            XCTAssertEqual(try decoder.decode(SupabaseSpeechVoiceRecord.self, from: data).voice, voice)
        }
        XCTAssertThrowsError(try decoder.decode(SupabaseSpeechVoiceRecord.self, from: Data(#"{"speech_voice":"unknown"}"#.utf8)))
    }
}
