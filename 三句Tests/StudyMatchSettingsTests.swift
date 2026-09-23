import Foundation
import XCTest
@testable import 三句

@MainActor
final class StudyMatchSettingsTests: XCTestCase {
    private func settings(_ threshold: Double = 0.42, count: Int = 14) -> StudySceneMatchSettings {
        StudySceneMatchSettings(sceneID: UUID(), threshold: threshold, canAdjust: true, matchedCount: count)
    }

    func testRangeDirectionDefaultAndBounds() {
        XCTAssertEqual(StudyMatchRange.threshold(at: 0), 0.48)
        XCTAssertEqual(StudyMatchRange.threshold(at: 6), 0.36)
        XCTAssertEqual(StudyMatchRange.threshold(at: 3), 0.42)
        XCTAssertEqual(StudyMatchRange.threshold(at: -100), 0.48)
        XCTAssertEqual(StudyMatchRange.threshold(at: .nan), 0.42)
        for (index, threshold) in StudyMatchRange.thresholds.enumerated() {
            XCTAssertEqual(StudyMatchRange.index(for: threshold), index)
        }
    }

    func testSuccessfulSaveUpdatesCountAndSupportsReset() async {
        var calls: [Double] = []
        var reloads = 0
        let editor = StudyMatchSettingsEditor(settings: settings(), save: { value in
            calls.append(value)
            return self.settings(value, count: 27)
        }, didSave: { reloads += 1 })
        await editor.saveDraft()
        XCTAssertTrue(calls.isEmpty)
        editor.position = 6
        await editor.saveDraft()
        XCTAssertEqual(calls, [0.36])
        XCTAssertEqual(editor.settings.matchedCount, 27)
        XCTAssertEqual(reloads, 1)
        XCTAssertFalse(editor.isSaving)
        editor.position = Double(StudyMatchRange.defaultIndex)
        await editor.saveDraft()
        XCTAssertEqual(calls, [0.36, 0.42])
        XCTAssertEqual(editor.settings.threshold, 0.42)
    }

    func testFailureKeepsSavedRangeAndCount() async {
        let editor = StudyMatchSettingsEditor(settings: settings(), save: { _ in
            throw URLError(.notConnectedToInternet)
        }, didSave: { XCTFail("A failed save must not reload results") })
        editor.position = 6
        await editor.saveDraft()
        XCTAssertEqual(editor.settings.threshold, 0.42)
        XCTAssertEqual(editor.settings.matchedCount, 14)
        XCTAssertEqual(editor.position, 3)
        XCTAssertNotNil(editor.errorMessage)
        XCTAssertFalse(editor.isSaving)
    }

    func testOnlyOneSaveCanRunAtATime() async {
        var resume: CheckedContinuation<StudySceneMatchSettings, Error>?
        let started = expectation(description: "save started")
        var calls = 0
        let editor = StudyMatchSettingsEditor(settings: settings(), save: { _ in
            calls += 1
            return try await withCheckedThrowingContinuation { resume = $0; started.fulfill() }
        }, didSave: {})
        editor.position = 6
        let task = Task { await editor.saveDraft() }
        await fulfillment(of: [started], timeout: 2)
        await editor.saveDraft()
        XCTAssertEqual(calls, 1)
        resume?.resume(returning: settings(0.36))
        await task.value
        XCTAssertFalse(editor.isSaving)
    }

    func testFetchPayloadOmitsThresholdAndResponseDecodes() throws {
        let data = try JSONEncoder().encode(StudySceneMatchSettingsRequest(p_scene_id: "scene", p_threshold: nil))
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"p_scene_id":"scene"}"#)
        let json = #"{"scene_id":"10000000-0000-0000-0000-000000000001","threshold":0.38,"can_adjust":true,"matched_count":0}"#
        let result = try JSONDecoder().decode(StudySceneMatchSettings.self, from: Data(json.utf8))
        XCTAssertEqual(result.threshold, 0.38)
        XCTAssertEqual(result.matchedCount, 0)
    }
}
