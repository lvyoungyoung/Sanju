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
}
