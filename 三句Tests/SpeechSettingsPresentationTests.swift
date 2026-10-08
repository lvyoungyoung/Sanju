import Combine
import SwiftUI
import XCTest
@testable import 三句

@MainActor
final class SpeechSettingsPresentationTests: XCTestCase {
    func testVoiceSheetOpensLargeWithoutResizingStudySettingsAndCanReopen() async throws {
        let suite = "SpeechPresentation.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let speech = SpeechService(defaults: defaults)
        let state = PresentationState()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        let root = UIViewController()
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer {
            root.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKeyAndVisible()
        }

        let parent = UIHostingController(rootView: PresentationHost(state: state, speech: speech))
        let compactID = UISheetPresentationController.Detent.Identifier("study-settings")
        let parentSheet = try XCTUnwrap(parent.sheetPresentationController)
        parentSheet.detents = [.custom(identifier: compactID) { _ in 330 }, .large()]
        parentSheet.selectedDetentIdentifier = compactID
        root.present(parent, animated: false)
        try await waitUntil { parent.view.window != nil }

        for attempt in 0..<2 {
            state.isShowingSpeech = true
            try await waitUntil {
                parent.presentedViewController?.view.window != nil
                    && parent.presentedViewController?.transitionCoordinator == nil
            }
            let voiceController = try XCTUnwrap(parent.presentedViewController)
            let voiceSheet = try XCTUnwrap(voiceController.sheetPresentationController)
            XCTAssertEqual(voiceSheet.detents.map(\.identifier), [.large])
            XCTAssertEqual(parentSheet.selectedDetentIdentifier, compactID)
            XCTAssertGreaterThan(voiceController.view.bounds.height, 330)

            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "SpeechSettingsSheet-open-\(attempt + 1)"
            attachment.lifetime = .keepAlways
            add(attachment)

            state.isShowingSpeech = false
            try await waitUntil { parent.presentedViewController == nil }
            XCTAssertTrue(root.presentedViewController === parent)
            XCTAssertEqual(parentSheet.selectedDetentIdentifier, compactID)
        }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertTrue(condition(), "Presentation did not settle before the timeout")
    }
}

@MainActor
private final class PresentationState: ObservableObject {
    nonisolated deinit {}

    @Published var isShowingSpeech = false
}

private struct PresentationHost: View {
    @ObservedObject var state: PresentationState
    let speech: SpeechService

    var body: some View {
        Text("Study settings")
            .sheet(isPresented: $state.isShowingSpeech) {
                SpeechSettingsSheet(speech: speech)
            }
    }
}
