import XCTest
@testable import 三句

@MainActor
final class SupabaseEnvironmentTests: XCTestCase {
    func testDirectConnectionRetainsExistingHistoryAndPendingFeedback() throws {
        let suite = "SupabaseEnvironmentTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        for (direct, proxy) in [
            ("https://spb-bp103246ivn7q0nl.supabase.opentrust.net", "https://api.sanju.cc"),
            ("https://spb-bp1364k407p37qn7.supabase.opentrust.net", "https://api-staging.sanju.cc")
        ] {
            let event = AlbumFlipEvent(id: UUID(), memoryID: UUID(), sentenceID: UUID(),
                                      feedback: .familiar, occurredAt: Date(), timeZoneID: "UTC")
            let oldStore = AlbumFlipHistoryStore(defaults: defaults, ownerID: "alice", namespace: proxy)
            oldStore.record(event)
            let namespace = SupabaseEnvironment.persistenceNamespace(for: direct)
            let newStore = AlbumFlipHistoryStore(defaults: defaults, ownerID: "alice", namespace: namespace)
            XCTAssertEqual(newStore.read().pending, [event])
            XCTAssertEqual(newStore.read().records[event.itemID]?.lastEventID, event.id)
            XCTAssertTrue(AlbumFlipHistoryStore(defaults: defaults, ownerID: "bob", namespace: namespace)
                .read().pending.isEmpty)
        }
    }

    func testPersistenceNamespaceKeepsProjectsSeparate() {
        let production = SupabaseEnvironment.persistenceNamespace(for: "https://spb-bp103246ivn7q0nl.supabase.opentrust.net")
        let staging = SupabaseEnvironment.persistenceNamespace(for: "https://spb-bp1364k407p37qn7.supabase.opentrust.net")
        XCTAssertNotEqual(production, staging)
        for url in ["https://api.sanju.cc", "https://api-staging.sanju.cc", "https://other.example"] {
            XCTAssertEqual(SupabaseEnvironment.persistenceNamespace(for: url), url)
        }
    }

    func testReplacementProjectDoesNotReuseOldSessionsOrQueues() throws {
        let isolationID = "spb-bp112jga6hk29sgb"
        let proxy = "https://api-staging.sanju.cc"
        let replacement = SupabaseEnvironment.persistenceNamespace(for: proxy, isolationID: isolationID)
        XCTAssertEqual(replacement, isolationID)
        XCTAssertEqual(replacement, SupabaseEnvironment.persistenceNamespace(
            for: "https://\(isolationID).supabase.opentrust.net", isolationID: isolationID))
        XCTAssertNotEqual(replacement, SupabaseEnvironment.persistenceNamespace(for: proxy))
        for key in [AppStorageKey.supabaseSession, AppStorageKey.pendingGuestCreditMigration,
                    AppStorageKey.initialCreditsGrantMarker] {
            XCTAssertEqual(SupabaseEnvironment.storageKey(key, isolationID: nil), key)
            XCTAssertEqual(SupabaseEnvironment.storageKey(key, isolationID: isolationID), "\(isolationID).\(key)")
        }
        let root = URL(fileURLWithPath: "/tmp/sanju-isolation-tests")
        XCTAssertEqual(SupabaseEnvironment.dataDirectory(in: root, isolationID: nil).path,
                       root.appendingPathComponent("Sanju").path)
        XCTAssertEqual(SupabaseEnvironment.dataDirectory(in: root, isolationID: isolationID).path,
                       root.appendingPathComponent("Sanju/environments/\(isolationID)").path)
        let suite = "SupabaseEnvironmentTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let event = AlbumFlipEvent(id: UUID(), memoryID: UUID(), sentenceID: UUID(),
                                  feedback: .familiar, occurredAt: Date(), timeZoneID: "UTC")
        let old = AlbumFlipHistoryStore(defaults: defaults, ownerID: "guest", namespace: proxy)
        old.record(event)
        XCTAssertTrue(AlbumFlipHistoryStore(defaults: defaults, ownerID: "guest", namespace: replacement)
            .read().pending.isEmpty)
        XCTAssertEqual(old.read().pending, [event])
    }
}
