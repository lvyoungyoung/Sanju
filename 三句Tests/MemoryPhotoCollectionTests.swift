import SwiftUI
import XCTest
@testable import 三句

@MainActor
final class MemoryPhotoCollectionTests: XCTestCase {
    func testBrowseDefaultsToTime() {
        XCTAssertEqual(MemoryBrowseMode.allCases.first, .time)
        XCTAssertEqual(MemoryBrowseMode.time.rawValue, 0)
        XCTAssertEqual(MemoryBrowseMode.topic.rawValue, 1)
    }

    func testEmptyLibraryHasNoTopicsOrFlipItems() {
        let collection = MemoryPhotoCollection(memories: [])
        XCTAssertTrue(collection.topics.isEmpty)
        XCTAssertTrue(collection.memories(in: nil).isEmpty)
        XCTAssertTrue(collection.flipItems(in: nil).isEmpty)
    }

    func testUsesPhotoCategoriesNotSentenceTopicsWithoutDuplicateCounts() throws {
        let photo = memory(categories: ["food_and_drinks", "food_and_drinks", "restaurants_and_cafes"], topics: [["travel"], ["friends_gatherings"]])
        let collection = MemoryPhotoCollection(memories: [photo, photo])
        XCTAssertEqual(collection.allMemories.count, 1)
        XCTAssertEqual(Set(collection.topics.map(\.id)), ["food_and_drinks", "restaurants_and_cafes"])
        for topic in collection.topics {
            XCTAssertEqual(topic.memories.map(\.id), [photo.id])
            XCTAssertEqual(try XCTUnwrap(topic.cover).id, photo.id)
        }
    }

    func testUnknownAndMissingCategoriesRemainInUncategorized() {
        let old = memory(topics: [["travel", "natural_scenery"]])
        let unknown = memory(categories: ["风景", "legacy_topic"], topics: [["food_and_drinks"]])
        let known = memory(categories: ["natural_scenery", "legacy_topic"], topics: [[]])
        let collection = MemoryPhotoCollection(memories: [old, unknown, known])
        XCTAssertEqual(Set(collection.memories(in: MemoryPhotoCollection.uncategorizedID).map(\.id)), [old.id, unknown.id])
        XCTAssertEqual(collection.memories(in: "natural_scenery").map(\.id), [known.id])
        XCTAssertEqual(collection.topics.last?.id, MemoryPhotoCollection.uncategorizedID)
    }

    func testTimeAndTopicPhotosAreNewestFirst() {
        let older = memory(categories: ["natural_scenery"], topics: [[]], date: Date(timeIntervalSince1970: 100))
        let newer = memory(categories: ["natural_scenery"], topics: [[]], date: Date(timeIntervalSince1970: 200))
        let collection = MemoryPhotoCollection(memories: [older, newer])
        XCTAssertEqual(collection.memories(in: nil).map(\.id), [newer.id, older.id])
        XCTAssertEqual(collection.memories(in: "natural_scenery").map(\.id), [newer.id, older.id])
    }

    func testTopicsKeepCatalogOrderAndOnlyShowNonemptyAlbums() {
        let photo = memory(categories: ["natural_scenery", "food_and_drinks"], topics: [[]])
        let collection = MemoryPhotoCollection(memories: [photo])
        XCTAssertEqual(collection.topics.map(\.id), MemoryPhotoCategory.all.map(\.id).filter { ["natural_scenery", "food_and_drinks"].contains($0) })
    }

    func testFlipIncludesAllSentencesOfOnlyTheTopicsPhotos() {
        let food = memory(categories: ["food_and_drinks"], topics: [["food_and_drinks"], ["home_life"], [], [], [], []])
        let scenery = memory(categories: ["natural_scenery"], topics: [[]])
        let collection = MemoryPhotoCollection(memories: [food, scenery])
        let items = collection.flipItems(in: "food_and_drinks")
        XCTAssertEqual(items.count, 6)
        XCTAssertEqual(Set(items.map(\.memoryID)), [food.id])
        XCTAssertEqual(Set(items.map(\.sentence.id)), Set(food.sentences.map(\.id)))
        XCTAssertEqual(collection.flipItems(in: nil).count, 7)
        XCTAssertTrue(collection.flipItems(in: "nonexistent_topic").isEmpty)
    }

    func testFlipIsNotLimitedToTheFirstPhotoPage() {
        let photos = (0..<45).map { memory(categories: ["natural_scenery"], topics: [[]], date: Date(timeIntervalSince1970: Double($0))) }
        let collection = MemoryPhotoCollection(memories: photos)
        XCTAssertEqual(collection.memories(in: "natural_scenery").count, 45)
        XCTAssertEqual(Set(collection.flipItems(in: "natural_scenery").map(\.memoryID)), Set(photos.map(\.id)))
    }

    func testDeletingOrUpdatingPhotosRebuildsMembership() {
        let photo = memory(categories: ["city_life"], topics: [["travel"]])
        var updated = photo
        updated.sentences = [SentenceRecord(english: "A quiet lake.", chinese: "安静的湖。", learningTopicIDs: ["natural_scenery"])]
        XCTAssertEqual(MemoryPhotoCollection(memories: [updated]).topics.map(\.id), ["city_life"])
        updated.tags = ["natural_scenery"]
        let changed = MemoryPhotoCollection(memories: [updated])
        XCTAssertTrue(changed.memories(in: "city_life").isEmpty)
        XCTAssertEqual(changed.memories(in: "natural_scenery").map(\.id), [photo.id])
        XCTAssertTrue(MemoryPhotoCollection(memories: []).topics.isEmpty)
    }

    func testScopedFlipDeckNeverDrawsAnOutsidePhoto() throws {
        let inside = memory(categories: ["natural_scenery"], topics: [["travel"], ["travel"]])
        let outside = memory(categories: ["food_and_drinks"], topics: [[]])
        let collection = MemoryPhotoCollection(memories: [inside, outside])
        let suite = "MemoryPhotoCollectionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let deck = AlbumFlipDeck(items: collection.flipItems(in: "natural_scenery"),
                                 store: AlbumFlipHistoryStore(defaults: defaults, ownerID: "guest"), randomIndex: { _ in 0 })
        for index in 0..<30 {
            let card = try XCTUnwrap(deck.cards.first)
            XCTAssertEqual(card.item.memoryID, inside.id)
            deck.advance(index.isMultiple(of: 2) ? .again : .familiar, cardID: card.id)
        }
    }

    func testExternalMemoryLinkStillOpensPhotoDetail() async {
        let model = AppModel()
        let id = UUID()
        model.openMemoryFromExternalLink(id)
        await Task.yield()
        XCTAssertEqual(model.selectedTab, .memories)
        XCTAssertEqual(model.memoriesNavigationPath, [.memory(id)])
    }

    func testMemoryBrowsingAndTopicDetailRenderInBothThemes() async throws {
        let model = AppModel()
        let photo = UIGraphicsImageRenderer(size: CGSize(width: 480, height: 480)).image { context in
            UIColor.systemOrange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 480, height: 480))
        }
        var travel = memory(categories: ["restaurants_and_cafes", "food_and_drinks"], topics: [["travel"], ["natural_scenery"]])
        travel = MemoryEntry(id: travel.id, imageData: try XCTUnwrap(photo.jpegData(compressionQuality: 0.8)), tags: travel.tags, sentences: travel.sentences)
        model.memories = [travel, memory(topics: [[]])]
        model.memoryLoadState = .loaded
        model.selectedTab = .memories
        defer { model.speech.stop() }
        for scheme in [ColorScheme.light, .dark] {
            for mode in MemoryBrowseMode.allCases {
                let image = try await render(
                    MainTabView().environmentObject(model)
                        .environment(\.colorScheme, scheme),
                    selectingTopics: mode == .topic
                )
                attach(image, name: "Memories-\(mode)-\(scheme)")
            }
            model.memoriesNavigationPath = [.photoTopic("restaurants_and_cafes")]
            let detail = try await render(
                MainTabView().environmentObject(model)
                    .environment(\.colorScheme, scheme)
            )
            attach(detail, name: "Memories-TopicDetail-\(scheme)")
            model.memoriesNavigationPath = []
        }
    }

    func testCategoryNormalizationKeepsPrimaryAndAtMostTwoSecondaryCategories() {
        XCTAssertEqual(MemoryPhotoCategory.all.count, 25)
        XCTAssertEqual(Set(MemoryPhotoCategory.all.map(\.id)).count, 25)
        XCTAssertEqual(MemoryPhotoCategory.normalizedIDs(["unknown", " natural_scenery ", "natural_scenery", "flowers_and_plants", "pets_and_animals", "home_life"]),
                       ["natural_scenery", "flowers_and_plants", "pets_and_animals"])
    }

    func testPhotoCategoriesSurviveLocalSerialization() throws {
        let photo = memory(categories: ["natural_scenery", "flowers_and_plants"], topics: [["travel"]])
        let restored = try JSONDecoder().decode(MemoryEntry.self, from: JSONEncoder().encode(photo))
        XCTAssertEqual(restored.tags, photo.tags)
        XCTAssertEqual(MemoryPhotoCollection(memories: [restored]).topics.map(\.id), ["flowers_and_plants", "natural_scenery"])
    }

    private func memory(categories: [String] = [], topics: [[String]], date: Date = .now) -> MemoryEntry {
        MemoryEntry(createdAt: date, imageData: Data(), tags: categories, sentences: topics.enumerated().map { index, ids in
            SentenceRecord(english: "A moment to remember \(index).", chinese: "值得记住的时刻。", learningTopicIDs: ids)
        })
    }

    private func render<Content: View>(_ content: Content, selectingTopics: Bool = false) async throws -> UIImage {
        let size = CGSize(width: 393, height: 852)
        let controller = UIHostingController(rootView: content)
        let previous = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow)
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
        }
        controller.view.frame = window.bounds
        controller.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(500))
        if selectingTopics {
            let control = try XCTUnwrap(findTabs(in: controller.view))
            XCTAssertEqual(control.selectedSegmentIndex, 0)
            control.selectedSegmentIndex = 1
            control.sendActions(for: .valueChanged)
            try await Task.sleep(for: .milliseconds(500))
            XCTAssertEqual(control.selectedSegmentIndex, 1)
        }
        return UIGraphicsImageRenderer(size: size).image { _ in
            controller.view.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
    }

    private func findTabs(in view: UIView) -> UISegmentedControl? {
        if let control = view as? UISegmentedControl { return control }
        return view.subviews.lazy.compactMap { self.findTabs(in: $0) }.first
    }

    private func attach(_ image: UIImage, name: String) {
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
