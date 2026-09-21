import XCTest
import SwiftUI
@testable import 三句

final class GenerationPreferenceTests: XCTestCase {
    func testStarterIsFirstAndPreservesExistingStoredValues() {
        XCTAssertEqual(EnglishLevel.allCases, [.starter, .simple, .intermediate, .advanced])
        XCTAssertEqual(EnglishLevel(rawValue: "启蒙"), .starter)
        XCTAssertEqual(EnglishLevel(rawValue: "简单"), .simple)
        XCTAssertEqual(EnglishLevel(rawValue: "中等"), .intermediate)
        XCTAssertEqual(EnglishLevel(rawValue: "高级"), .advanced)
    }

    func testOnlyStarterDisablesLyricalAndResolvesToPlain() {
        for level in EnglishLevel.allCases {
            XCTAssertTrue(level.allows(.plain))
            XCTAssertEqual(level.resolvedStyle(.plain), .plain)
            XCTAssertEqual(level.allows(.lyrical), level != .starter)
            XCTAssertEqual(level.resolvedStyle(.lyrical), level == .starter ? .plain : .lyrical)
        }
    }

    func testStarterSurvivesPreferenceCodableRoundTrip() throws {
        let data = try JSONEncoder().encode(EnglishLevel.starter)
        XCTAssertEqual(try JSONDecoder().decode(EnglishLevel.self, from: data), .starter)
    }

    @MainActor
    func testNativePickerDisablesAndDimsLyricalOnlyForStarter() async throws {
        func findControl(in view: UIView) -> UISegmentedControl? {
            if let control = view as? UISegmentedControl { return control }
            return view.subviews.lazy.compactMap { findControl(in: $0) }.first
        }
        for level in EnglishLevel.allCases {
            let host = UIHostingController(rootView: LanguageStylePicker(selection: .constant(.plain), englishLevel: level))
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 100))
            window.rootViewController = host
            window.isHidden = false
            defer { window.isHidden = true }
            await Task.yield()
            host.view.layoutIfNeeded()
            let control = try XCTUnwrap(findControl(in: host.view))
            XCTAssertTrue(control.isEnabledForSegment(at: 0))
            XCTAssertEqual(control.isEnabledForSegment(at: 1), level != .starter)
            XCTAssertNotNil(control.titleTextAttributes(for: .disabled)?[.foregroundColor])
        }
    }

    @MainActor
    func testPickerRestoresSelectionWhenBindingRejectsChange() {
        let picker = LanguageStylePicker(selection: .constant(.plain), englishLevel: .simple)
        let control = UISegmentedControl(items: ["Plain", "Lyrical"])
        control.selectedSegmentIndex = 1
        picker.makeCoordinator().changed(control)
        XCTAssertEqual(control.selectedSegmentIndex, 0)
    }
}
