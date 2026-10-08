import XCTest
import SwiftUI
@testable import 三句

final class GenerationPreferenceTests: XCTestCase {
    func testThreeDifficultyOptionsNormalizeLegacyAdvancedValues() {
        XCTAssertEqual(EnglishLevel.allCases, [.starter, .simple, .intermediate])
        XCTAssertEqual(EnglishLevel(rawValue: "启蒙"), .starter)
        XCTAssertEqual(EnglishLevel(rawValue: "简单"), .simple)
        XCTAssertEqual(EnglishLevel(rawValue: "中等"), .intermediate)
        XCTAssertEqual(EnglishLevel(rawValue: "高级"), .intermediate)
        XCTAssertNil(EnglishLevel(rawValue: "unknown"))
    }

    func testLegacyAdvancedCodableValueBecomesIntermediateAndWritesCurrentValue() throws {
        let stored = Data("\"高级\"".utf8)
        let level = try JSONDecoder().decode(EnglishLevel.self, from: stored)
        XCTAssertEqual(level, .intermediate)
        XCTAssertTrue(EnglishLevel.allCases.contains(level))
        let saved = try JSONEncoder().encode(level)
        XCTAssertEqual(try JSONDecoder().decode(String.self, from: saved), "中等")
    }

    func testCurrentDifficultyValuesKeepTheirWireFormat() throws {
        XCTAssertEqual(EnglishLevel.allCases.map(\.rawValue), ["启蒙", "简单", "中等"])
        for level in EnglishLevel.allCases {
            let saved = try JSONEncoder().encode(level)
            XCTAssertEqual(try JSONDecoder().decode(EnglishLevel.self, from: saved), level)
        }
    }

    func testStarterSurvivesPreferenceCodableRoundTrip() throws {
        let data = try JSONEncoder().encode(EnglishLevel.starter)
        XCTAssertEqual(try JSONDecoder().decode(EnglishLevel.self, from: data), .starter)
    }

    @MainActor
    func testNativePickerKeepsAllThreeDifficultyOptionsEnabled() async throws {
        func findControl(in view: UIView) -> UISegmentedControl? {
            if let control = view as? UISegmentedControl { return control }
            return view.subviews.lazy.compactMap { findControl(in: $0) }.first
        }
        for level in EnglishLevel.allCases {
            let host = UIHostingController(rootView: EnglishLevelPicker(selection: .constant(level)))
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 100))
            window.rootViewController = host
            window.isHidden = false
            defer { window.isHidden = true }
            await Task.yield()
            host.view.layoutIfNeeded()
            let control = try XCTUnwrap(findControl(in: host.view))
            XCTAssertEqual(control.numberOfSegments, 3)
            for index in 0..<3 { XCTAssertTrue(control.isEnabledForSegment(at: index)) }
            XCTAssertEqual(control.selectedSegmentIndex, EnglishLevel.allCases.firstIndex(of: level))
        }
    }

    @MainActor
    func testPickerRestoresSelectionWhenBindingRejectsChange() async throws {
        func findControl(in view: UIView) -> UISegmentedControl? {
            if let control = view as? UISegmentedControl { return control }
            return view.subviews.lazy.compactMap { findControl(in: $0) }.first
        }
        let host = UIHostingController(rootView: EnglishLevelPicker(selection: .constant(.simple)))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 100))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        await Task.yield()
        host.view.layoutIfNeeded()
        let control = try XCTUnwrap(findControl(in: host.view))
        control.selectedSegmentIndex = 2
        control.sendActions(for: .valueChanged)
        XCTAssertEqual(control.selectedSegmentIndex, 1)
    }

    func testGenerationRequestAndProfilePatchContainNoStyleSetting() throws {
        let request = SupabaseGenerateMemoryRequest(
            imageBase64: "AA==", englishLevel: "简单", guestJobID: nil,
            clientRequestID: "request", generationFormat: "dual_tabs_v1"
        )
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        XCTAssertNil(json["languageStyle"])
        XCTAssertEqual(json["englishLevel"] as? String, "简单")
        let patch = SupabaseProfilePatchPayload(nickname: nil, englishLevel: "中等")
        let patchJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(patch)) as? [String: Any])
        XCTAssertEqual(patchJSON["english_level"] as? String, "中等")
        XCTAssertNil(patchJSON["language_style"])
    }

    func testProfileCreationRetainsTheLegacyColumnWithoutASelectableStyle() throws {
        let payload = SupabaseProfileUpsertPayload(
            id: "user", appleUserID: "email:user", nickname: "name", email: nil,
            englishLevel: "启蒙", initialAvailableGenerations: nil
        )
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any])
        XCTAssertEqual(json["language_style"] as? String, "平铺直叙")
        let profile = try JSONDecoder().decode(SupabaseProfileRecord.self, from: Data(
            #"{"id":"user","nickname":"name","english_level":"简单","available_generations":9,"language_style":"抒情优美"}"#.utf8
        ))
        XCTAssertEqual(profile.englishLevel, "简单")
        XCTAssertEqual(profile.availableGenerations, 9)
    }
}
