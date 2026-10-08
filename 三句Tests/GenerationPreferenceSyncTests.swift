import XCTest
@testable import 三句

@MainActor
final class GenerationPreferenceSyncTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    private let basic = GenerationPreferences(level: .simple)
    private let intermediate = GenerationPreferences(level: .intermediate)

    override func setUp() async throws {
        suite = "GenerationPreferenceSyncTests.\(UUID())"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDown() async throws { defaults.removePersistentDomain(forName: suite) }

    func testGuestPreferencesStayLocalAndReturnAfterLogout() async {
        let sync = GenerationPreferenceSync(defaults: defaults, fetch: { _ in self.basic }, save: { _, _ in XCTFail("No guest write") })
        sync.select(intermediate)
        sync.activate(userID: "alice")
        await sync.waitForSync()
        XCTAssertEqual(sync.value, basic)
        sync.activate(userID: nil)
        XCTAssertEqual(sync.value, intermediate)
    }

    func testFailedSaveSurvivesRelaunchAndIsAccountScoped() async {
        let sync = GenerationPreferenceSync(defaults: defaults, fetch: { _ in self.basic }, save: { _, _ in throw URLError(.notConnectedToInternet) })
        sync.activate(userID: "alice")
        sync.select(intermediate)
        await sync.waitForSync()
        var owners: [String] = []
        let restored = GenerationPreferenceSync(defaults: defaults, fetch: { _ in self.basic }, save: { owner, value in
            owners.append(owner)
            XCTAssertEqual(value, self.intermediate)
        })
        restored.activate(userID: "bob")
        await restored.waitForSync()
        XCTAssertEqual(restored.value, basic)
        XCTAssertTrue(owners.isEmpty)
        restored.activate(userID: "alice")
        XCTAssertEqual(restored.value, intermediate)
        await restored.waitForSync()
        XCTAssertEqual(owners, ["alice"])
    }

    func testReconnectionRetriesPendingSaveWithoutFetchingOldValues() async {
        var online = false
        var saved: [GenerationPreferences] = []
        let sync = GenerationPreferenceSync(defaults: defaults, fetch: { _ in XCTFail("Dirty preferences must be saved first"); return self.basic }, save: { _, value in
            guard online else { throw URLError(.notConnectedToInternet) }
            saved.append(value)
        })
        sync.activate(userID: "alice")
        sync.select(intermediate)
        await sync.waitForSync()
        online = true
        sync.refresh()
        await sync.waitForSync()
        XCTAssertEqual(saved, [intermediate])
    }

    func testDelayedFetchCannotOverwriteNewSelection() async {
        var sync: GenerationPreferenceSync!
        var saved: [GenerationPreferences] = []
        sync = GenerationPreferenceSync(defaults: defaults, fetch: { _ in
            sync.select(self.intermediate)
            return self.basic
        }, save: { _, value in saved.append(value) })
        sync.activate(userID: "alice")
        await sync.waitForSync()
        XCTAssertEqual(sync.value, intermediate)
        XCTAssertEqual(saved, [intermediate])
    }

    func testNewSelectionDuringSaveIsNotLostAndRequestsAreCoalesced() async {
        var sync: GenerationPreferenceSync!
        var saved: [GenerationPreferences] = []
        let starter = GenerationPreferences(level: .starter)
        sync = GenerationPreferenceSync(defaults: defaults, fetch: { _ in self.basic }, save: { _, value in
            saved.append(value)
            if value == self.intermediate { sync.select(starter) }
        })
        sync.activate(userID: "alice")
        sync.select(GenerationPreferences(level: .simple))
        sync.select(intermediate)
        await sync.waitForSync()
        XCTAssertEqual(saved, [intermediate, starter])
        XCTAssertEqual(sync.value.level, .starter)
    }

    func testAccountSwitchIgnoresPreviousAccountsDelayedProfile() async {
        var sync: GenerationPreferenceSync!
        sync = GenerationPreferenceSync(defaults: defaults, fetch: { owner in
            if owner == "alice" {
                sync.activate(userID: "bob")
                return self.intermediate
            }
            return self.basic
        }, save: { _, _ in })
        sync.activate(userID: "alice")
        await sync.waitForSync()
        XCTAssertEqual(sync.value, basic)
    }

    func testLegacyStyleCachePreservesDifficultyAndPendingSave() async throws {
        defaults.set(Data(#"{"value":{"level":"中等","style":"抒情优美"},"pending":true}"#.utf8),
                     forKey: "sanju.generation.preferences.alice")
        var saved: [GenerationPreferences] = []
        let sync = GenerationPreferenceSync(defaults: defaults, fetch: { _ in
            XCTFail("Pending difficulty must be saved before fetching")
            return self.basic
        }, save: { _, value in saved.append(value) })
        sync.activate(userID: "alice")
        XCTAssertEqual(sync.value, intermediate)
        await sync.waitForSync()
        XCTAssertEqual(saved, [intermediate])
        let data = try XCTUnwrap(defaults.data(forKey: "sanju.generation.preferences.alice"))
        let cache = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let value = try XCTUnwrap(cache["value"] as? [String: Any])
        XCTAssertEqual(value["level"] as? String, "中等")
        XCTAssertNil(value["style"])
    }
}
