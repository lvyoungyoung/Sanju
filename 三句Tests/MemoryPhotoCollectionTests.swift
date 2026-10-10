import Combine
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

    func testPhotoPrintStyleIsStableAndVariesAcrossPhotos() throws {
        let ids = try (0..<60).map { index in
            try XCTUnwrap(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index)))
        }
        let styles = ids.map(MemoryPhotoPrintStyle.init(memoryID:))
        XCTAssertEqual(styles, ids.map(MemoryPhotoPrintStyle.init(memoryID:)))
        XCTAssertGreaterThan(Set(styles.map(\.rotationDegrees)).count, 3)
        XCTAssertGreaterThan(Set(styles.map(\.horizontalBias)).count, 3)
        for style in styles {
            XCTAssertGreaterThanOrEqual(abs(style.rotationDegrees), 1.25)
            XCTAssertLessThanOrEqual(abs(style.rotationDegrees), 2.75)
        }
        let before = Dictionary(uniqueKeysWithValues: zip(ids, styles))
        let after = Dictionary(uniqueKeysWithValues: ids.reversed().map { ($0, MemoryPhotoPrintStyle(memoryID: $0)) })
        XCTAssertEqual(before, after, "Reordering or refreshing photos must not reshuffle their visual style")
    }

    func testPhotoPrintsShareSizeAndVerticalCenterWithinEachRow() throws {
        let widths: [CGFloat] = [124, 132, 164, 200, 320]
        for width in widths {
            let slot = CGSize(width: width, height: width / MemoryPhotoPrintStyle.slotAspectRatio)
            let expectedWidth = min(width * MemoryPhotoPrintStyle.widthFraction, 170)
            for index in 0..<60 {
                let id = try XCTUnwrap(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index)))
                let style = MemoryPhotoPrintStyle(memoryID: id)
                XCTAssertEqual(style.printSize(in: slot).width, expectedWidth, accuracy: 0.001)
                XCTAssertEqual(style.center(in: slot).y, slot.height / 2, accuracy: 0.001,
                               "Photos in the same row must not receive random vertical offsets")
            }
        }
    }

    func testPhotoPrintRowGapsAreAboutThirtyPercentSmaller() throws {
        let widths: [CGFloat] = [124, 132, 164, 200]
        for width in widths {
            let slot = CGSize(width: width, height: width / MemoryPhotoPrintStyle.slotAspectRatio)
            for index in 0..<60 {
                let id = try XCTUnwrap(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index)))
                let style = MemoryPhotoPrintStyle(memoryID: id)
                let printHeight = style.rotatedSize(in: slot).height
                let previousGap = width / 0.80 + AppSpacing.small - printHeight
                let currentGap = slot.height + AppSpacing.small - printHeight
                XCTAssertEqual(currentGap / previousGap, 0.70, accuracy: 0.05)
                XCTAssertGreaterThan(currentGap, 0, "Tighter rows must not overlap their photos")
            }
        }
    }

    func testRotatedPhotoPrintsStayWithinTheirSlotsOnCompactAndWideScreens() throws {
        let widths: [CGFloat] = [124, 132, 164, 200, 320]
        for index in 0..<100 {
            let id = try XCTUnwrap(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index)))
            let style = MemoryPhotoPrintStyle(memoryID: id)
            for width in widths {
                let slot = CGSize(width: width, height: width / MemoryPhotoPrintStyle.slotAspectRatio)
                let size = style.printSize(in: slot)
                let rotated = style.rotatedSize(in: slot)
                let center = style.center(in: slot)
                let bounds = CGRect(x: center.x - rotated.width / 2, y: center.y - rotated.height / 2,
                                    width: rotated.width, height: rotated.height)
                XCTAssertEqual(size.width, min(width * MemoryPhotoPrintStyle.widthFraction, 170), accuracy: 0.001)
                XCTAssertEqual(size.height - size.width, 18, accuracy: 0.001,
                               "Polaroid prints must preserve the larger bottom margin around square photos")
                XCTAssertEqual(size.height - MemoryPhotoPrintStyle.sideInset - MemoryPhotoPrintStyle.bottomInset,
                               size.width - MemoryPhotoPrintStyle.sideInset * 2, accuracy: 0.001)
                XCTAssertGreaterThanOrEqual(bounds.minX, 0)
                XCTAssertGreaterThanOrEqual(bounds.minY, 0)
                XCTAssertLessThanOrEqual(bounds.maxX, slot.width)
                XCTAssertLessThanOrEqual(bounds.maxY, slot.height)
            }
        }
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

    func testTopicCoverStaysOnOldestPhotoWhenNewPhotosAreAdded() throws {
        let older = memory(categories: ["natural_scenery"], topics: [[]], date: Date(timeIntervalSince1970: 100))
        let newer = memory(categories: ["natural_scenery"], topics: [[]], date: Date(timeIntervalSince1970: 200))
        let first = try XCTUnwrap(MemoryPhotoCollection(memories: [older]).topics.first)
        let updated = try XCTUnwrap(MemoryPhotoCollection(memories: [newer, older]).topics.first)
        XCTAssertEqual(first.cover?.id, older.id)
        XCTAssertEqual(updated.cover?.id, older.id)
        XCTAssertEqual(updated.previewMemories.map(\.id), [older.id, newer.id])
        XCTAssertEqual(updated.memories.map(\.id), [newer.id, older.id])
    }

    func testDeletingOldestCoverPromotesNextOldestPhoto() throws {
        let photos = (0..<3).map {
            memory(categories: ["food_and_drinks"], topics: [[]], date: Date(timeIntervalSince1970: Double($0)))
        }
        let before = try XCTUnwrap(MemoryPhotoCollection(memories: photos).topics.first)
        let after = try XCTUnwrap(MemoryPhotoCollection(memories: Array(photos.dropFirst())).topics.first)
        XCTAssertEqual(before.cover?.id, photos[0].id)
        XCTAssertEqual(after.cover?.id, photos[1].id)
        XCTAssertEqual(after.previewMemories.map(\.id), [photos[1].id, photos[2].id])
    }

    func testTopicStackUsesAtMostThreeOldestPhotos() throws {
        let photos = (0..<30).map {
            memory(categories: ["natural_scenery"], topics: [[]], date: Date(timeIntervalSince1970: Double($0)))
        }
        let topic = try XCTUnwrap(MemoryPhotoCollection(memories: photos).topics.first)
        XCTAssertEqual(topic.previewMemories.map(\.id), Array(photos.prefix(3)).map(\.id))
        XCTAssertEqual(topic.previewMemories.first?.id, topic.cover?.id)
        XCTAssertEqual(topic.memories.count, 30)
    }

    func testTopicCoverAndStackAreStableWhenSyncChangesInputOrder() throws {
        let photos = (0..<4).map { _ in memory(categories: ["natural_scenery"], topics: [[]], date: Date(timeIntervalSince1970: 100)) }
        let before = try XCTUnwrap(MemoryPhotoCollection(memories: photos).topics.first)
        let after = try XCTUnwrap(MemoryPhotoCollection(memories: Array(photos.reversed())).topics.first)
        XCTAssertEqual(before.cover?.id, after.cover?.id)
        XCTAssertEqual(before.previewMemories.map(\.id), after.previewMemories.map(\.id))
    }

    func testEmptyTopicHasNoCoverOrPreviewPhotos() {
        let topic = MemoryPhotoTopic(id: "natural_scenery", memories: [])
        XCTAssertNil(topic.cover)
        XCTAssertTrue(topic.previewMemories.isEmpty)
    }

    func testTopicPhotoCountBadgeCapsAt99Plus() {
        let photo = memory(categories: ["natural_scenery"], topics: [[]])
        for (count, expected) in [(0, "0"), (1, "1"), (99, "99"), (100, "99+"), (1000, "99+")] {
            let topic = MemoryPhotoTopic(id: "natural_scenery", memories: Array(repeating: photo, count: count))
            XCTAssertEqual(topic.photoCountBadgeTitle, expected)
        }
    }

    func testTopicPhotoCountBadgeRendersInBothThemes() async throws {
        let model = AppModel()
        let photo = try photoMemory("OnboardingCafe", categories: ["restaurants_and_cafes"], timestamp: 100)
        model.memories = [photo]
        for scheme in [ColorScheme.light, .dark] {
            for count in [1, 99, 100] {
                let topic = MemoryPhotoTopic(id: "restaurants_and_cafes", memories: Array(repeating: photo, count: count))
                let image = try await render(
                    MemoryPhotoTopicCard(topic: topic)
                        .environmentObject(model)
                        .frame(width: 164)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(AppSurfaceColor.page)
                        .environment(\.colorScheme, scheme)
                )
                attach(image, name: "Memories-CountBadge-\(count)-\(scheme)")
            }
        }
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
        model.memories = [
            try photoMemory("OnboardingCafe", categories: ["restaurants_and_cafes", "food_and_drinks"], timestamp: 100),
            try photoMemory("LoginPreview", categories: ["restaurants_and_cafes", "food_and_drinks"], timestamp: 200),
            try photoMemory("LoginPreviewToddler", categories: ["restaurants_and_cafes"], timestamp: 300),
            try photoMemory("LoginPreviewHiking", categories: ["natural_scenery"], timestamp: 400),
            memory(topics: [[]])
        ]
        model.memoryLoadState = .loaded
        model.selectedTab = .memories
        defer { model.speech.stop() }
        for scheme in [ColorScheme.light, .dark] {
            for mode in MemoryBrowseMode.allCases {
                let image = try await render(
                    NavigationStack {
                        MemoriesView(browseMode: mode)
                    }
                    .environmentObject(model)
                    .environment(\.colorScheme, scheme)
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

    func testPhotoPrintAlbumsRenderOnSmallScreensAndInBothThemes() async throws {
        let model = AppModel()
        let assets = ["OnboardingCafe", "LoginPreview", "LoginPreviewToddler", "LoginPreviewHiking"]
        model.memories = try (0..<12).map { index in
            let photo = try photoMemory(assets[index % assets.count], categories: ["restaurants_and_cafes"],
                                        timestamp: 1_786_000_000 + Double(index / 3) * 86_400 + Double(index))
            return MemoryEntry(id: try XCTUnwrap(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))),
                               createdAt: photo.createdAt, imageData: photo.imageData, tags: photo.tags,
                               sentences: photo.sentences)
        }
        model.memoryLoadState = .loaded
        defer { model.speech.stop() }
        let widths: [CGFloat] = [320, 393]
        let topicIDs: [String?] = [nil, "restaurants_and_cafes"]
        for width in widths {
            for scheme in [ColorScheme.light, .dark] {
                for topicID in topicIDs {
                    let size = CGSize(width: width, height: 852)
                    let image = try await render(
                        NavigationStack { MemoriesView(topicID: topicID) }
                            .environmentObject(model)
                            .environment(\.colorScheme, scheme),
                        size: size
                    )
                    XCTAssertEqual(image.size, size)
                    attach(image, name: "Memories-PhotoPrints-\(Int(width))-\(scheme)-\(topicID == nil ? "time" : "topic")")
                }
            }
        }
    }

    func testTopicStackLayoutIsBoundedOnCompactScreensAndWithLargeText() throws {
        let model = AppModel()
        let photos = try ["OnboardingCafe", "LoginPreview", "LoginPreviewToddler"].enumerated().map {
            try photoMemory($0.element, categories: ["restaurants_and_cafes"], timestamp: Double($0.offset))
        }
        model.memories = photos
        for count in 1...3 {
            let topic = try XCTUnwrap(MemoryPhotoCollection(memories: Array(photos.prefix(count))).topics.first)
            for typeSize in [DynamicTypeSize.large, .accessibility3] {
                // Large accessibility text uses the page's single-column layout.
                let widths: [CGFloat] = typeSize.isAccessibilitySize ? [272, 345] : [124, 164, 280]
                for width in widths {
                    let host = UIHostingController(rootView: MemoryPhotoTopicCard(topic: topic)
                        .environmentObject(model)
                        .environment(\.dynamicTypeSize, typeSize)
                        .frame(width: width))
                    let size = host.sizeThatFits(in: CGSize(width: width, height: 1000))
                    XCTAssertEqual(size.width, width, accuracy: 0.1)
                    XCTAssertGreaterThan(size.height, min(width, 240))
                    XCTAssertLessThan(size.height, width + 200)
                }
            }
        }
    }

    func testBrowseTabsFitCompactScreensAndKeepTheirHeightOnSelection() async throws {
        for typeSize in [DynamicTypeSize.large, .xxxLarge, .accessibility3] {
            var previousHeight: CGFloat?
            for mode in MemoryBrowseMode.allCases {
                let view = MemoryBrowseTabs(mode: .constant(mode))
                    .environment(\.dynamicTypeSize, typeSize)
                    .frame(width: 272)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(AppSurfaceColor.page)
                let host = UIHostingController(rootView: view)
                let size = host.sizeThatFits(in: CGSize(width: 272, height: 500))
                XCTAssertEqual(size.width, 272, accuracy: 0.1)
                XCTAssertGreaterThanOrEqual(size.height, MemoryBrowseTabs.regularSize.height,
                                            "The photo-picker style tabs must preserve their accessible tap targets")
                if let previousHeight {
                    XCTAssertEqual(size.height, previousHeight, accuracy: 0.1)
                }
                previousHeight = size.height
                let image = try await render(
                    view.frame(maxWidth: .infinity, maxHeight: .infinity),
                    size: CGSize(width: 320, height: max(160, size.height + 40))
                )
                attach(image, name: "Memories-Tabs-Compact-\(typeSize)-\(mode)")
            }
        }
    }

    func testGlassBrowseTabsKeepTheirSizeWhenSelectionChanges() async throws {
        let selection = BrowseTabsTestSelection()
        let host = UIHostingController(rootView: BrowseTabsTestView(selection: selection))
        let window = try makeWindow(size: CGSize(width: 320, height: 160))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(300))

        let originalSurface = try XCTUnwrap(browseTabsSurface(in: host.view))
        let originalFrame = originalSurface.convert(originalSurface.bounds, to: window)
        for mode in [MemoryBrowseMode.topic, .time] {
            selection.mode = mode
            try await Task.sleep(for: .milliseconds(300))
            host.view.layoutIfNeeded()
            let surface = try XCTUnwrap(browseTabsSurface(in: host.view))
            XCTAssertEqual(surface.convert(surface.bounds, to: window), originalFrame,
                           "Changing selection must not resize or move the floating glass capsule")
            let image = UIGraphicsImageRenderer(size: window.bounds.size).image { _ in
                host.view.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            attach(image, name: "Memories-GlassTabs-Selection-\(mode)")
        }
    }

    func testBrowseTabsStayPinnedWhileBothPhotoAndTopicListsScroll() async throws {
        let model = AppModel()
        let photo = try photoMemory("OnboardingCafe", categories: [], timestamp: 100)
        model.memories = (0..<40).map { index in
            MemoryEntry(createdAt: Date(timeIntervalSince1970: Double(index)),
                        imageData: photo.imageData,
                        tags: [MemoryPhotoCategory.all[index % MemoryPhotoCategory.all.count].id],
                        sentences: photo.sentences)
        }
        model.memoryLoadState = .loaded
        defer { model.speech.stop() }

        func descendants(of view: UIView) -> [UIView] {
            [view] + view.subviews.flatMap { descendants(of: $0) }
        }

        for mode in MemoryBrowseMode.allCases {
            let host = UIHostingController(rootView: NavigationStack {
                MemoriesView(browseMode: mode)
            }.environmentObject(model))
            let previous = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows).first(where: \.isKeyWindow)
            let window = try makeWindow()
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer {
                window.isHidden = true
                window.rootViewController = nil
                previous?.makeKey()
            }
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(500))
            let views = descendants(of: host.view)
            let tabs = try XCTUnwrap(browseTabsSurface(in: host.view))
            let scroll = try XCTUnwrap(views.compactMap { $0 as? UIScrollView }.first {
                $0.contentSize.height > $0.bounds.height + 200
            })
            XCTAssertFalse(tabs.isDescendant(of: scroll), "The glass capsule must not move with the scrolling content")
            let originalFrame = tabs.convert(tabs.bounds, to: window)
            XCTAssertGreaterThanOrEqual(originalFrame.minY, window.safeAreaInsets.top)
            XCTAssertTrue(scroll.convert(scroll.bounds, to: window).contains(originalFrame),
                          "The tabs must float over the scroll view instead of occupying an opaque header strip")
            XCTAssertNotNil(scroll.refreshControl, "Pinning the picker must preserve pull-to-refresh")

            for offset in [CGFloat(200), CGFloat(-60)] {
                scroll.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
                host.view.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(150))
                XCTAssertEqual(scroll.contentOffset.y, offset, accuracy: 1)
                XCTAssertNotNil(tabs.window)
                XCTAssertEqual(tabs.convert(tabs.bounds, to: window).minY, originalFrame.minY, accuracy: 1,
                               "The picker must stay fixed during scrolling and pull-down")
            }
            scroll.setContentOffset(CGPoint(x: 0, y: 200), animated: false)
            host.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(size: window.bounds.size).image { _ in
                host.view.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            attach(image, name: "Memories-PinnedTabs-\(mode)")
        }
    }

    func testPhotoTopicDetailDoesNotAddBrowseTabs() async throws {
        let model = AppModel()
        model.memories = [try photoMemory("OnboardingCafe", categories: ["restaurants_and_cafes"], timestamp: 100)]
        model.memoryLoadState = .loaded
        let host = UIHostingController(rootView: NavigationStack {
            MemoriesView(topicID: "restaurants_and_cafes")
        }.environmentObject(model))
        let window = try makeWindow()
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; model.speech.stop() }
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(browseTabsSurface(in: host.view),
                     "Topic detail must retain its own navigation, without root browse tabs")
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

    private func photoMemory(_ asset: String, categories: [String], timestamp: TimeInterval) throws -> MemoryEntry {
        let photo = try XCTUnwrap(UIImage(named: asset)?.preparingThumbnail(of: CGSize(width: 480, height: 480)))
        return MemoryEntry(createdAt: Date(timeIntervalSince1970: timestamp),
                           imageData: try XCTUnwrap(photo.jpegData(compressionQuality: 0.8)),
                           tags: categories,
                           sentences: [SentenceRecord(english: "A moment to remember.", chinese: "值得记住的时刻。")])
    }

    private func makeWindow(size: CGSize = CGSize(width: 393, height: 852)) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        return window
    }

    private func browseTabsSurface(in view: UIView) -> UIView? {
        // SwiftUI draws the labels itself; locate the rendered surface by its specified size, not private UIKit class names.
        let size = MemoryBrowseTabs.regularSize
        if abs(view.bounds.width - size.width) < 0.1, abs(view.bounds.height - size.height) < 0.1 { return view }
        return view.subviews.lazy.compactMap { self.browseTabsSurface(in: $0) }.first
    }

    private func render<Content: View>(_ content: Content, size: CGSize = CGSize(width: 393, height: 852)) async throws -> UIImage {
        let controller = UIHostingController(rootView: content)
        let previous = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow)
        let window = try makeWindow(size: size)
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
        return UIGraphicsImageRenderer(size: size).image { _ in
            controller.view.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
    }

    private func attach(_ image: UIImage, name: String) {
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

@MainActor
private final class BrowseTabsTestSelection: ObservableObject {
    @Published var mode = MemoryBrowseMode.time
}

private struct BrowseTabsTestView: View {
    @ObservedObject var selection: BrowseTabsTestSelection

    var body: some View {
        MemoryBrowseTabs(mode: $selection.mode)
    }
}
