import XCTest
@testable import 三句

private enum DeinitTestContext {
    @TaskLocal static var marker = 0
}

@MainActor
final class DeinitCompatibilityTests: XCTestCase {
    func testSynchronousReleaseWithTaskLocalStorageOnOlderRuntimes() {
        // Regression for swiftlang/swift#88036: implicit MainActor deinit used
        // the broken back-deployed runtime path when released in this context.
        let suite = "sanju.deinit-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        DeinitTestContext.$marker.withValue(1) {
            assertReleased { AlbumFlipDeck(items: [], store: AlbumFlipHistoryStore(defaults: defaults, ownerID: "offline-test")) }
            assertReleased { MemoryImageLoader() }
            assertReleased { LocalRateLimiter(defaults: defaults) }
            assertReleased { NetworkStatusMonitor() }
            assertReleased { PurchaseConfirmationScope() }
            assertReleased { SpeechPreferenceSync(defaults: defaults, fetch: { _ in nil }, save: { _, voice, _ in voice }) }
            assertReleased { AlbumFlipHistorySync(defaults: defaults, fetch: { _ in [] }, upload: { _, _ in [] }) }
        }
    }

    private func assertReleased<T: AnyObject>(_ make: () -> T, file: StaticString = #filePath, line: UInt = #line) {
        var object: T? = make()
        weak var reference = object
        XCTAssertNotNil(reference, file: file, line: line)
        object = nil
        XCTAssertNil(reference, file: file, line: line)
    }
}
