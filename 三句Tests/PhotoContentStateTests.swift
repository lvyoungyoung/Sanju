import SwiftUI
import XCTest
@testable import 三句

@MainActor
final class PhotoContentStateTests: XCTestCase {
    func testFirstLoadFailureIsNotEmptyAndRetryCanShowLoading() {
        XCTAssertEqual(PhotoContentState.resolve(hasContent: false, isLoading: false, hasError: true), .failed)
        XCTAssertEqual(PhotoContentState.resolve(hasContent: false, isLoading: true, hasError: true), .loading)
        XCTAssertEqual(PhotoContentState.resolve(hasContent: true, isLoading: false, hasError: true), .content)
    }

    func testNewUserSeesEmptyStateOnceLoadingFinishes() {
        XCTAssertEqual(PhotoContentState.resolve(hasContent: false, isLoading: false), .empty)
    }

    func testRestorationAndInitialSyncDoNotShowEmptyState() {
        XCTAssertEqual(PhotoContentState.resolve(hasContent: false, isLoading: true), .loading)
    }

    func testRefreshPreservesExistingContent() {
        XCTAssertEqual(PhotoContentState.resolve(hasContent: true, isLoading: true), .content)
        XCTAssertEqual(PhotoContentState.resolve(hasContent: true, isLoading: false), .content)
    }

    func testEmptyStateUpdatesAfterAddingOrRemovingContent() {
        let states = [(false, false), (true, false), (true, true), (false, false)]
            .map { PhotoContentState.resolve(hasContent: $0.0, isLoading: $0.1) }
        XCTAssertEqual(states, [.empty, .content, .content, .empty])
    }

    func testEmptyStatesRenderInBothThemesWithLargeText() throws {
        for destination in AddPhotoEmptyState.Destination.allCases {
            for scheme in [ColorScheme.light, .dark] {
                for size in [DynamicTypeSize.large, .accessibility1] {
                    let content = AddPhotoEmptyState(destination: destination, onAddPhoto: {})
                        .padding(.horizontal, 24)
                        .frame(width: 320)
                        .background(AppSurfaceColor.page)
                        .environment(\.colorScheme, scheme)
                        .environment(\.dynamicTypeSize, size)
                    let renderer = ImageRenderer(content: content)
                    let image = try XCTUnwrap(renderer.uiImage)
                    XCTAssertEqual(image.size.width, 320, accuracy: 1)
                    XCTAssertLessThan(image.size.height, 700)
                    let attachment = XCTAttachment(image: image)
                    attachment.name = "AddPhoto-\(destination)-\(scheme)-\(size)"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                }
            }
        }
    }
}
