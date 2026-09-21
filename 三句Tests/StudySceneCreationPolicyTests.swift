import XCTest
@testable import 三句

final class StudySceneCreationPolicyTests: XCTestCase {
    func testAllowsTwentiethButNotTwentyFirstTopic() {
        XCTAssertTrue(StudySceneCreationPolicy.canCreate(currentCount: 0))
        XCTAssertTrue(StudySceneCreationPolicy.canCreate(currentCount: 19))
        XCTAssertFalse(StudySceneCreationPolicy.canCreate(currentCount: 20))
        XCTAssertFalse(StudySceneCreationPolicy.canCreate(currentCount: 25))
    }

    func testLocalAndServerLimitsUseTheSameLocalizedMessage() throws {
        let payload = Data(#"{"error":"最多可以创建20个学习主题","code":"study_scene_limit_reached"}"#.utf8)
        let decoded = try JSONDecoder().decode(SupabaseAPIError.self, from: payload)
        let error = SupabaseServiceError.apiError(decoded.message)
        XCTAssertEqual(error.localizedDescription, StudySceneCreationPolicy.limitMessage)
        XCTAssertEqual(SentenceStudyTopicLoadingError.limitReached.localizedDescription, StudySceneCreationPolicy.limitMessage)
        XCTAssertTrue(error.localizedDescription.contains("20"))
        XCTAssertFalse(error.localizedDescription.contains("study_scene_limit_reached"))
    }
}
