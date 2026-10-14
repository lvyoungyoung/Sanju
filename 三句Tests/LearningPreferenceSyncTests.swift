import XCTest
@testable import 三句

@MainActor
final class LearningPreferenceSyncTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() async throws {
        suite = "LearningPreferenceSyncTests.\(UUID())"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }
    override func tearDown() async throws { defaults.removePersistentDomain(forName: suite) }

    private func remote(_ selection: LearningSelection, revision: Int = 1,
                        level: LearningLevel = .beginner) -> RemoteLearningPreferences {
        RemoteLearningPreferences(schemaVersion: 1,
            selection: .init(mode: selection.mode, targetLanguage: selection.targetLanguage,
                translationLanguage: selection.translationLanguage, explanationLanguage: selection.explanationLanguage,
                revision: revision),
            languages: [.init(targetLanguage: .english, level: level, levelRevision: 1, speechVoice: nil, voiceRevision: 0)])
    }

    func testGuestPreferencesPersistWithoutNetworkAndLevelsAreIndependent() throws {
        let sync = LearningPreferenceSync(defaults: defaults, initial: .legacy(),
            fetch: { _ in XCTFail("Guest fetch"); throw CancellationError() },
            save: { _, _ in XCTFail("Guest write"); throw CancellationError() })
        try sync.select(.standard(target: .japanese, support: .english))
        sync.select(level: .starter, language: .japanese)
        sync.select(level: .intermediate, language: .spanish)
        let restored = LearningPreferenceSync(defaults: defaults, initial: .legacy(),
            fetch: { _ in throw CancellationError() }, save: { _, _ in throw CancellationError() })
        XCTAssertEqual(restored.value.selection.targetLanguage, .japanese)
        XCTAssertEqual(restored.value.level(for: .japanese), .starter)
        XCTAssertEqual(restored.value.level(for: .spanish), .intermediate)
        XCTAssertEqual(restored.value.level(for: .english), .beginner)
    }

    func testRetiredAdvancedLevelUsesVisibleIntermediateWithoutRewritingStoredValue() {
        let preferences = LearningPreferences(selection: .legacyEnglish(explanationLanguage: .simplifiedChinese), levels: ["en": .advanced])
        XCTAssertEqual(preferences.level(for: .english), .intermediate)
        XCTAssertEqual(preferences.levels["en"], .advanced)
    }

    func testExistingAccountWinsAndLogoutRestoresGuestSelection() async throws {
        let server = try LearningSelection.standard(target: .french, support: .english)
        let guest = try LearningSelection.standard(target: .spanish, support: .simplifiedChinese)
        let sync = LearningPreferenceSync(defaults: defaults, initial: .legacy(),
            fetch: { _ in self.remote(server) },
            save: { _, _ in XCTFail("Existing account must win"); return self.remote(server) })
        try sync.select(guest)
        sync.activate(userID: "alice")
        await sync.waitForSync()
        XCTAssertEqual(sync.value.selection, server)
        sync.activate(userID: nil)
        XCTAssertEqual(sync.value.selection, guest)
    }

    func testCompareAndSwapConflictRefetchesBeforeRetryingExplicitChoice() async throws {
        let original = LearningSelection.legacyEnglish(explanationLanguage: .simplifiedChinese)
        let choice = try LearningSelection.standard(target: .japanese, support: .english)
        var fetches = 0
        var revisions: [Int] = []
        let sync = LearningPreferenceSync(defaults: defaults, initial: .legacy(), fetch: { _ in
            fetches += 1
            return self.remote(original, revision: fetches)
        }, save: { _, patch in
            revisions.append(patch.selection!.expectedRevision)
            if revisions.count == 1 { throw SupabaseServiceError.apiError("preference_revision_conflict") }
            return self.remote(choice, revision: 3)
        })
        sync.activate(userID: "alice")
        try sync.select(choice)
        await sync.waitForSync()
        XCTAssertEqual(revisions, [1, 2])
        XCTAssertEqual(sync.value.selection, choice)
    }

    func testCorruptOrUnsupportedCacheIsPreserved() throws {
        let key = "sanju.learning-preferences.v1.guest"
        for data in [Data("broken".utf8), Data(#"{"value":{"selection":{"mode":"standard","targetLanguage":"en","translationLanguage":"en","explanationLanguage":"en"},"levels":{}},"pendingSelection":false,"pendingLevels":[]}"#.utf8)] {
            defaults.set(data, forKey: key)
            let sync = LearningPreferenceSync(defaults: defaults, initial: .legacy(),
                fetch: { _ in throw CancellationError() }, save: { _, _ in throw CancellationError() })
            XCTAssertTrue(sync.hasInvalidCache)
            XCTAssertThrowsError(try sync.select(.standard(target: .spanish, support: .english)))
            sync.select(level: .starter, language: .spanish)
            XCTAssertEqual(defaults.data(forKey: key), data)
        }
    }

    func testFailedExplicitChoiceSurvivesRelaunchAndOwnerSwitch() async throws {
        let original = LearningSelection.legacyEnglish(explanationLanguage: .simplifiedChinese)
        let choice = try LearningSelection.standard(target: .french, support: .english)
        let sync = LearningPreferenceSync(defaults: defaults, initial: .legacy(), fetch: { _ in self.remote(original) },
            save: { _, _ in throw URLError(.notConnectedToInternet) })
        sync.activate(userID: "alice")
        try sync.select(choice)
        await sync.waitForSync()
        var saved: [String] = []
        let restored = LearningPreferenceSync(defaults: defaults, initial: .legacy(), fetch: { _ in self.remote(original) },
            save: { owner, _ in saved.append(owner); return self.remote(choice) })
        restored.activate(userID: "bob")
        await restored.waitForSync()
        XCTAssertEqual(restored.value.selection, original)
        XCTAssertTrue(saved.isEmpty)
        restored.activate(userID: "alice")
        XCTAssertEqual(restored.value.selection, choice)
        await restored.waitForSync()
        XCTAssertEqual(saved, ["alice"])
    }
}
