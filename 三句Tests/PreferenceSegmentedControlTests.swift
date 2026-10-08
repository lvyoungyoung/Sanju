import SwiftUI
import XCTest
@testable import 三句

@MainActor
final class PreferenceSegmentedControlTests: XCTestCase {
    func testSelectionAndRateLimitRejectionStayInSync() {
        var selection = 0
        let picker = PreferenceSegmentedControl(
            titles: ["Starter", "Beginner", "Intermediate", "Advanced"],
            selection: Binding(get: { selection }, set: { selection = $0 }),
            accessibilityTitle: "Difficulty"
        )
        let control = picker.makeControl()
        let coordinator = picker.makeCoordinator()
        control.selectedSegmentIndex = 2
        coordinator.changed(control)
        XCTAssertEqual(selection, 2)
        coordinator.parent = PreferenceSegmentedControl(
            titles: picker.titles, selection: .constant(selection), accessibilityTitle: "Difficulty"
        )
        control.selectedSegmentIndex = 1
        coordinator.changed(control)
        XCTAssertEqual(selection, 2)
        XCTAssertEqual(control.selectedSegmentIndex, 2)
    }

    func testDisabledOptionCannotBeSelectedAndCanBeReenabled() {
        var selection = 0
        var picker = PreferenceSegmentedControl(
            titles: ["Plain", "Lyrical"],
            selection: Binding(get: { selection }, set: { selection = $0 }),
            accessibilityTitle: "Style", disabledIndices: [1]
        )
        let control = picker.makeControl()
        XCTAssertFalse(control.isEnabledForSegment(at: 1))
        control.selectedSegmentIndex = 1
        picker.makeCoordinator().changed(control)
        XCTAssertEqual(selection, 0)
        XCTAssertEqual(control.selectedSegmentIndex, 0)
        picker.disabledIndices = []
        picker.update(control)
        XCTAssertTrue(control.isEnabledForSegment(at: 1))
        control.selectedSegmentIndex = 1
        picker.makeCoordinator().changed(control)
        XCTAssertEqual(selection, 1)
    }

    func testDifficultyPickerKeepsItsHeightAndAppearanceInBothThemes() throws {
        for style in [UIUserInterfaceStyle.light, .dark] {
            let host = UIHostingController(rootView: VStack(spacing: 20) {
                EnglishLevelPicker(selection: .constant(.starter))
            }
            .padding(20)
            .background(AppSurfaceColor.card))
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let previousKeyWindow = scene.windows.first { $0.isKeyWindow }
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 320, height: 240)
            window.overrideUserInterfaceStyle = style
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer {
                window.isHidden = true
                window.rootViewController = nil
                previousKeyWindow?.makeKeyAndVisible()
            }
            host.view.frame = window.bounds
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            let controls = segmentedControls(in: host.view)
            XCTAssertEqual(controls.count, 1)
            guard controls.count == 1 else { return }
            // Native controls can add a point of alignment padding on newer iOS.
            XCTAssertEqual(controls[0].bounds.height, 44, accuracy: 1)
            XCTAssertEqual(controls[0].numberOfSegments, 3)
            XCTAssertTrue(controls[0].isEnabledForSegment(at: 0))
            XCTAssertNotNil(controls[0].selectedSegmentTintColor)
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "GenerationPreferences-320-\(style.rawValue)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    private func segmentedControls(in view: UIView) -> [UISegmentedControl] {
        if let control = view as? UISegmentedControl { return [control] }
        return view.subviews.flatMap { segmentedControls(in: $0) }
    }
}
