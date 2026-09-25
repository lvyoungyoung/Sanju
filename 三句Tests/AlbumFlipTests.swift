import SwiftUI
import XCTest
@testable import 三句

@MainActor
final class AlbumFlipTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        super.setUp()
        suite = "AlbumFlipTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
        super.tearDown()
    }

    func testIncludesAllSixSentencesWithoutRequiringFavorites() {
        let memory = makeMemory()
        let items = AlbumFlipItem.makeItems(from: [memory])
        XCTAssertEqual(items.count, 6)
        XCTAssertEqual(Set(items.map(\.sentence.presentationGroup)), Set(SentencePresentationGroup.allCases))
        XCTAssertTrue(items.allSatisfy { !$0.sentence.isFavorite })
    }

    func testFiltersBlankSentencesAndDuplicateMemories() {
        var memory = makeMemory()
        memory.sentences.append(SentenceRecord(english: "  \n", chinese: ""))
        XCTAssertEqual(AlbumFlipItem.makeItems(from: [memory, memory]).count, 6)
    }

    func testEmptyAlbumHasNoCards() {
        XCTAssertTrue(makeDeck([]).cards.isEmpty)
    }

    func testOneSentenceCanBeBrowsedIndefinitelyWithFreshPresentationIdentity() throws {
        let items = AlbumFlipItem.makeItems(from: [makeMemory(count: 1)])
        let deck = makeDeck(items)
        var appearances = Set<UUID>()
        for _ in 0..<40 {
            let current = try XCTUnwrap(deck.cards.first)
            XCTAssertTrue(appearances.insert(current.id).inserted)
            deck.advance(.familiar, cardID: current.id)
            XCTAssertEqual(deck.cards.count, 6)
            XCTAssertEqual(deck.visibleCards.count, 2)
        }
        XCTAssertEqual(deck.viewedCount, 40)
    }

    func testLookaheadIsTheNextFiveActualCardsWithoutChangingTheVisualStack() throws {
        let deck = makeDeck(AlbumFlipItem.makeItems(from: (0..<4).map { _ in makeMemory() }))
        for _ in 0..<20 {
            let current = try XCTUnwrap(deck.cards.first)
            let upcoming = Array(deck.cards.dropFirst())
            XCTAssertEqual(upcoming.count, 5)
            XCTAssertEqual(deck.upcomingSpeechTexts, upcoming.map { $0.item.sentence.english })
            XCTAssertEqual(deck.visibleCards.map(\.id), Array(deck.cards.prefix(2)).map(\.id))
            deck.advance(.familiar, cardID: current.id)
            XCTAssertEqual(Array(deck.cards.prefix(5)).map(\.id), upcoming.map(\.id))
        }
    }

    func testSmallAlbumsHaveStableLookaheadAndAvoidConsecutivePhotos() throws {
        for count in [2, 3] {
            let deck = makeDeck(AlbumFlipItem.makeItems(from: (0..<count).map { _ in makeMemory(count: 1) }))
            var previous: UUID?
            for _ in 0..<30 {
                let current = try XCTUnwrap(deck.cards.first)
                XCTAssertNotEqual(current.item.memoryID, previous)
                previous = current.item.memoryID
                XCTAssertEqual(deck.upcomingSpeechTexts.count, 5)
                deck.advance(.familiar, cardID: current.id)
            }
        }
    }

    func testDoesNotShowTheSamePhotoConsecutivelyWhenAlternativesExist() throws {
        for photoCount in [2, 3, 8] {
            let items = AlbumFlipItem.makeItems(from: (0..<photoCount).map { _ in makeMemory() })
            let deck = makeDeck(items)
            var lastPhoto: UUID?
            for _ in 0..<60 {
                let current = try XCTUnwrap(deck.cards.first)
                XCTAssertNotEqual(current.item.memoryID, lastPhoto)
                lastPhoto = current.item.memoryID
                deck.advance(.familiar, cardID: current.id)
            }
        }
    }

    func testOnePhotoStillRotatesThroughAllItsSentences() throws {
        let items = AlbumFlipItem.makeItems(from: [makeMemory()])
        let deck = makeDeck(items)
        var seen = Set<String>()
        for _ in 0..<6 {
            let current = try XCTUnwrap(deck.cards.first)
            seen.insert(current.item.id)
            deck.advance(.familiar, cardID: current.id)
        }
        XCTAssertEqual(seen, Set(items.map(\.id)))
    }

    func testAgainRevisitsTheExactSentenceAfterSeveralCards() throws {
        let items = AlbumFlipItem.makeItems(from: (0..<3).map { _ in makeMemory() })
        let deck = makeDeck(items)
        let first = try XCTUnwrap(deck.cards.first)
        deck.advance(.again, cardID: first.id)
        var repeatAt: Int?
        for index in 1...12 {
            let current = try XCTUnwrap(deck.cards.first)
            if current.item.id == first.item.id {
                repeatAt = index
                break
            }
            deck.advance(.familiar, cardID: current.id)
        }
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(repeatAt), 4)
        XCTAssertLessThanOrEqual(try XCTUnwrap(repeatAt), 9)
    }

    func testStaleSwipeCompletionCannotAdvanceTheNextCard() throws {
        let deck = makeDeck(AlbumFlipItem.makeItems(from: [makeMemory()]))
        let first = try XCTUnwrap(deck.cards.first)
        deck.advance(.again, cardID: first.id)
        let next = deck.cards.first?.id
        deck.advance(.familiar, cardID: first.id)
        XCTAssertEqual(deck.cards.first?.id, next)
        XCTAssertEqual(deck.viewedCount, 1)
        XCTAssertEqual(deck.feedback[first.item.id], .again)
    }

    func testFeedbackIsLocalAndAccountScoped() throws {
        let items = AlbumFlipItem.makeItems(from: [makeMemory()])
        let store = AlbumFlipHistoryStore(defaults: defaults, ownerID: "account-a")
        let deck = AlbumFlipDeck(items: items, store: store)
        let first = try XCTUnwrap(deck.cards.first)
        deck.advance(.familiar, cardID: first.id)
        XCTAssertEqual(AlbumFlipDeck(items: items, store: store).feedback[first.item.id], .familiar)
        XCTAssertTrue(AlbumFlipHistoryStore(defaults: defaults, ownerID: "account-b").read().records.isEmpty)
        XCTAssertTrue(AlbumFlipHistoryStore(defaults: defaults, ownerID: "guest").read().records.isEmpty)
        XCTAssertTrue(items.allSatisfy { !$0.sentence.isFavorite })
        XCTAssertNil(defaults.object(forKey: AppStorageKey.localSentenceStudyProgress))
        XCTAssertNil(defaults.object(forKey: AppStorageKey.remainingCredits))
    }

    func testRemovedSentencesAreNotRestoredFromHistory() throws {
        let items = AlbumFlipItem.makeItems(from: [makeMemory()])
        let store = AlbumFlipHistoryStore(defaults: defaults, ownerID: "guest")
        store.record(AlbumFlipEvent(id: UUID(), memoryID: items[0].memoryID, sentenceID: items[0].sentence.id,
                                    feedback: .familiar, occurredAt: Date(), timeZoneID: TimeZone.current.identifier))
        XCTAssertTrue(AlbumFlipDeck(items: Array(items.dropFirst()), store: store).feedback.isEmpty)
    }

    func testFamiliarFeedbackHasLowerSelectionWeight() throws {
        let items = AlbumFlipItem.makeItems(from: [makeMemory()])
        let store = AlbumFlipHistoryStore(defaults: defaults, ownerID: "guest")
        store.record(AlbumFlipEvent(id: UUID(), memoryID: items[0].memoryID, sentenceID: items[0].sentence.id,
                                    feedback: .familiar, occurredAt: Date(), timeZoneID: TimeZone.current.identifier))
        var initialWeight = 0
        _ = AlbumFlipDeck(items: items, store: store, randomIndex: { bound in
            if initialWeight == 0 { initialWeight = bound }
            return 0
        })
        XCTAssertEqual(initialWeight, 4 + (items.count - 1) * 12)
    }

    func testSwipeThresholdVelocityAndVerticalScrolling() {
        XCTAssertNil(AlbumFlipSwipe.feedback(x: 40, y: 1, predictedX: 60, width: 320))
        XCTAssertNil(AlbumFlipSwipe.feedback(x: 100, y: 200, predictedX: 300, width: 320))
        XCTAssertNil(AlbumFlipSwipe.feedback(x: 15, y: 1, predictedX: 300, width: 320))
        XCTAssertNil(AlbumFlipSwipe.feedback(x: 30, y: 1, predictedX: -250, width: 320))
        XCTAssertEqual(AlbumFlipSwipe.feedback(x: -90, y: 5, predictedX: -100, width: 320), .again)
        XCTAssertEqual(AlbumFlipSwipe.feedback(x: 90, y: 5, predictedX: 100, width: 320), .familiar)
        XCTAssertEqual(AlbumFlipSwipe.feedback(x: 30, y: 5, predictedX: 200, width: 320), .familiar)
        XCTAssertNil(AlbumFlipSwipe.feedback(x: 100, y: 0, predictedX: 200, width: 0))
    }

    func testCardRendersAtSmallAndLargeSizesInBothThemes() async throws {
        let item = AlbumFlipItem.makeItems(from: [makeMemory()])[0]
        for size in [CGSize(width: 272, height: 365), CGSize(width: 345, height: 535)] {
            for scheme in [ColorScheme.light, .dark] {
                let view = AlbumFlipSentenceCard(item: item, size: size, showsTranslation: true, onToggleTranslation: {}) {
                    Image(uiImage: self.samplePhoto).resizable().scaledToFill()
                }
                .environment(\.colorScheme, scheme)
                let image = try await renderInWindow(view, size: size)
                XCTAssertEqual(image.size.width, size.width, accuracy: 1)
                XCTAssertEqual(image.size.height, size.height, accuracy: 1)
                let attachment = XCTAttachment(image: image)
                attachment.name = "AlbumFlip-\(Int(size.width))-\(scheme)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }

    func testCardHandlesLongTextAndAccessibilityTypeWithoutChangingItsFrame() async throws {
        let item = AlbumFlipItem(memoryID: UUID(), sentence: SentenceRecord(
            english: String(repeating: "The afternoon light fills this little cafe with warmth. ", count: 5),
            chinese: "午后的阳光让这家小咖啡馆充满暖意。"
        ))
        let view = AlbumFlipSentenceCard(item: item, size: CGSize(width: 272, height: 365), showsTranslation: true, onToggleTranslation: {}) {
            Color.orange
        }.environment(\.dynamicTypeSize, .accessibility3)
        let image = try await renderInWindow(view, size: CGSize(width: 272, height: 365))
        XCTAssertEqual(image.size, CGSize(width: 272, height: 365))
    }

    func testFullScreenAlbumLayout() async throws {
        let model = AppModel()
        let memory = makeMemory()
        let data = try XCTUnwrap(samplePhoto.jpegData(compressionQuality: 0.8))
        model.memories = [MemoryEntry(id: memory.id, imageData: data, sentences: memory.sentences)]
        defer { model.speech.stop() }
        for scheme in [ColorScheme.light, .dark] {
            let view = AlbumFlipView(
                items: AlbumFlipItem.makeItems(from: model.memories), ownerID: "guest", defaults: defaults
            )
            .environmentObject(model)
            .environment(\.colorScheme, scheme)
            let image = try await renderInWindow(
                view, size: CGSize(width: 393, height: 852),
                safeAreaInsets: UIEdgeInsets(top: 59, left: 0, bottom: 34, right: 0)
            )
            let pageColor = try pixel(in: image, at: CGPoint(x: 1, y: 150))
            XCTAssertNotEqual(pageColor, [255, 255, 255, 255], "The page should use its themed background, not system white")
            XCTAssertEqual(try pixel(in: image, at: CGPoint(x: 1, y: 1)), pageColor, "The status bar area must match the page")
            XCTAssertEqual(try pixel(in: image, at: CGPoint(x: 1, y: 851)), pageColor, "The home indicator area must match the page")
            let attachment = XCTAttachment(image: image)
            attachment.name = "AlbumFlip-FullScreen-\(scheme)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func testImageDecoderDownsamplesAndRejectsInvalidData() throws {
        XCTAssertNil(AlbumFlipPhotoDecoder.decode(Data()))
        XCTAssertNil(AlbumFlipPhotoDecoder.decode(Data("not an image".utf8)))
        let source = UIGraphicsImageRenderer(size: CGSize(width: 2400, height: 1600)).image { context in
            UIColor.orange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2400, height: 1600))
        }
        let decoded = try XCTUnwrap(AlbumFlipPhotoDecoder.decode(try XCTUnwrap(source.jpegData(compressionQuality: 0.8))))
        XCTAssertLessThanOrEqual(max(decoded.size.width, decoded.size.height), 1280)
    }

    private var samplePhoto: UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 640, height: 480)).image { context in
            UIColor.orange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 640, height: 480))
            UIColor.brown.setFill()
            context.fill(CGRect(x: 0, y: 320, width: 640, height: 160))
        }
    }

    private func makeDeck(_ items: [AlbumFlipItem]) -> AlbumFlipDeck {
        AlbumFlipDeck(items: items, store: AlbumFlipHistoryStore(defaults: defaults, ownerID: "guest"), randomIndex: { _ in 0 })
    }

    private func renderInWindow<Content: View>(
        _ content: Content, size: CGSize, safeAreaInsets: UIEdgeInsets = .zero
    ) async throws -> UIImage {
        // ScrollView needs a mounted view hierarchy; ImageRenderer omits its contents.
        let controller = UIHostingController(rootView: content)
        controller.additionalSafeAreaInsets = safeAreaInsets
        let previousKeyWindow = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow)
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
        controller.view.frame = window.bounds
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(450))
        return UIGraphicsImageRenderer(size: size).image { _ in
            controller.view.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
    }

    private func pixel(in image: UIImage, at point: CGPoint) throws -> [UInt8] {
        let source = try XCTUnwrap(image.cgImage?.cropping(to: CGRect(
            x: point.x * image.scale, y: point.y * image.scale, width: 1, height: 1
        )))
        var bytes = [UInt8](repeating: 0, count: 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(
                data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(source, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return bytes
    }

    private func makeMemory(count: Int = 6) -> MemoryEntry {
        MemoryEntry(imageData: Data(), sentences: (0..<count).map { index in
            SentenceRecord(
                english: "The afternoon light fills this little cafe with warmth. \(index)",
                chinese: "午后的阳光让这家小咖啡馆充满暖意。",
                presentationGroup: index < 3 ? .whatISee : .whatIDSay
            )
        })
    }
}
