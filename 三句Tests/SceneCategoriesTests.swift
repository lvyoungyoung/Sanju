import XCTest
@testable import 三句

final class SceneCategoriesTests: XCTestCase {
    func testPhotosAndSentencesShareAllIDsAndLocalizedNames() {
        XCTAssertEqual(SceneCategory.all.count, 25)
        XCTAssertEqual(Set(SceneCategory.all.map(\.id)).count, 25)
        XCTAssertEqual(LearningTopic.all.map(\.id), SceneCategory.all.map(\.id))
        XCTAssertEqual(MemoryPhotoCategory.all.map(\.id), SceneCategory.all.map(\.id))
        XCTAssertEqual(LearningTopic.all.map(\.title), MemoryPhotoCategory.all.map(\.title))
    }

    func testEveryCategoryHasPackagedChineseAndEnglishTranslations() throws {
        for locale in ["zh-Hans", "en"] {
            let url = try XCTUnwrap(Bundle.main.url(forResource: locale, withExtension: "lproj"))
            let bundle = try XCTUnwrap(Bundle(url: url))
            for category in SceneCategory.all {
                let key = "scene_category.\(category.id)"
                let title = bundle.localizedString(forKey: key, value: nil, table: "SceneCategories")
                XCTAssertNotEqual(title, key)
                XCTAssertFalse(title.isEmpty)
                if locale == "zh-Hans" {
                    XCTAssertEqual(title, category.fallbackTitle)
                } else {
                    XCTAssertNil(title.range(of: "[\\u4e00-\\u9fff]", options: .regularExpression))
                }
            }
        }
    }

    func testNormalizationKeepsIndependentLimitsAndRejectsObsoleteIDs() {
        let ids = [" restaurants_and_cafes ", "restaurants_and_cafes", "food_and_drinks", "cooking"]
        XCTAssertEqual(MemoryPhotoCategory.normalizedIDs(ids), ["restaurants_and_cafes", "food_and_drinks", "cooking"])
        XCTAssertEqual(SceneCategory.normalizedIDs(ids, limit: 2), ["restaurants_and_cafes", "food_and_drinks"])
        for id in ["pet_life", "plants_and_wildlife", "cities_and_architecture", "work_and_office"] {
            XCTAssertNil(SceneCategory.category(for: id))
            XCTAssertNil(LearningTopic.topic(for: id))
            XCTAssertNil(MemoryPhotoCategory.category(for: id))
        }
    }
}
