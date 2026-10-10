import SwiftUI
import XCTest
@testable import 三句

@MainActor
final class ContentFooterHintTests: XCTestCase {
    func testFinishedLoadingHasNoFooterOrReservedHeight() throws {
        for scheme in [ColorScheme.light, .dark] {
            let image = try render(isLoading: false, scheme: scheme)
            XCTAssertEqual(image.size.height, 1, accuracy: 0.01)
        }
    }

    func testSyncingStillShowsAVisibleFooter() throws {
        for scheme in [ColorScheme.light, .dark] {
            let image = try render(isLoading: true, scheme: scheme)
            XCTAssertGreaterThan(image.size.height, 20)
            XCTAssertEqual(image.size.width, 320)
        }
    }

    func testLoadingStateCanReturnToAnEmptyFooter() throws {
        let before = try render(isLoading: false)
        let during = try render(isLoading: true)
        let after = try render(isLoading: false)
        XCTAssertGreaterThan(during.size.height, before.size.height)
        XCTAssertEqual(after.size, before.size)
    }

    private func render(isLoading: Bool, scheme: ColorScheme = .light) throws -> UIImage {
        let view = VStack(spacing: 0) {
            Color.clear.frame(height: 1)
            ContentFooterHint(isLoading: isLoading)
        }
        .frame(width: 320)
        .fixedSize(horizontal: false, vertical: true)
        .environment(\.colorScheme, scheme)
        return try XCTUnwrap(ImageRenderer(content: view).uiImage)
    }
}
