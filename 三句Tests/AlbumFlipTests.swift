import Combine
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

    func testPlaybackIndicatorFollowsCurrentSentenceFromLoadingToFinished() {
        let text = "A quiet afternoon."
        XCTAssertEqual(SpeechPlaybackState(text: text, activeText: nil, loadingText: nil), .idle)
        XCTAssertEqual(SpeechPlaybackState(text: text, activeText: text, loadingText: text), .loading)
        XCTAssertEqual(SpeechPlaybackState(text: text, activeText: text, loadingText: nil), .playing)
        XCTAssertEqual(SpeechPlaybackState(text: text, activeText: nil, loadingText: nil), .idle)
    }

    func testPlaybackIndicatorIgnoresOtherSentencesAndNormalizesWhitespace() {
        let text = "A quiet afternoon."
        XCTAssertEqual(SpeechPlaybackState(text: " \(text)\n", activeText: text, loadingText: nil), .playing)
        XCTAssertEqual(SpeechPlaybackState(text: " \(text)\n", activeText: text, loadingText: text), .loading)
        XCTAssertEqual(SpeechPlaybackState(text: text, activeText: "Another sentence.", loadingText: nil), .idle)
        XCTAssertEqual(SpeechPlaybackState(text: text, activeText: "Another sentence.", loadingText: "Another sentence."), .idle)
        XCTAssertEqual(SpeechPlaybackState(text: " \n", activeText: "", loadingText: ""), .idle)
    }

    func testIncludesAllSixSentencesWithoutRequiringFavorites() {
        let memory = makeMemory()
        let items = AlbumFlipItem.makeItems(from: [memory])
        XCTAssertEqual(items.count, 6)
        XCTAssertEqual(Set(items.map(\.sentence.presentationGroup)), Set(SentencePresentationGroup.allCases))
        XCTAssertTrue(items.allSatisfy { !$0.sentence.isFavorite })
        XCTAssertTrue(items.allSatisfy { $0.memoryCreatedAt == memory.createdAt })
    }

    func testFavoriteToggleOnlyChangesCurrentSentenceWithoutRecordingStudyOrFlipFeedback() async throws {
        let model = AppModel()
        model.memories = [makeMemory()]
        model.favoriteSentencesCount = 0
        model.localSentenceStudyProgress = [:]
        defer { model.speech.stop() }
        let deck = makeDeck(AlbumFlipItem.makeItems(from: model.memories))
        let card = try XCTUnwrap(deck.cards.first)
        let cardIDs = deck.cards.map(\.id)
        XCTAssertTrue(model.toggleAlbumFlipSentenceFavorite(card.item, ownerID: "guest"))
        await model.refreshSentenceStudyDueCount()

        XCTAssertEqual(model.memories[0].sentences.filter(\.isFavorite).map(\.id), [card.item.sentence.id])
        XCTAssertEqual(model.favoriteSentencesCount, 1)
        XCTAssertEqual(model.sentenceStudyDueCount, 1)
        XCTAssertTrue(model.localSentenceStudyProgress.isEmpty)
        XCTAssertEqual(deck.cards.map(\.id), cardIDs)
        XCTAssertEqual(deck.viewedCount, 0)
        XCTAssertTrue(AlbumFlipHistoryStore(defaults: defaults, ownerID: "guest").read().pending.isEmpty)

        XCTAssertTrue(model.toggleAlbumFlipSentenceFavorite(card.item, ownerID: "guest"))
        await model.refreshSentenceStudyDueCount()
        XCTAssertTrue(model.memories[0].sentences.allSatisfy { !$0.isFavorite })
        XCTAssertEqual(model.favoriteSentencesCount, 0)
        XCTAssertEqual(model.sentenceStudyDueCount, 0)
        XCTAssertTrue(model.localSentenceStudyProgress.isEmpty)
        XCTAssertEqual(deck.cards.map(\.id), cardIDs)
        XCTAssertEqual(deck.viewedCount, 0)
        XCTAssertTrue(AlbumFlipHistoryStore(defaults: defaults, ownerID: "guest").read().pending.isEmpty)
    }

    func testRepeatedDoubleTapTogglesLiveStateInsteadOfStaleDeckItem() throws {
        let model = AppModel()
        model.memories = [makeMemory(count: 1)]
        model.favoriteSentencesCount = 0
        defer { model.speech.stop() }
        let item = try XCTUnwrap(AlbumFlipItem.makeItems(from: model.memories).first)
        XCTAssertFalse(item.sentence.isFavorite)
        for expectedState in [true, false, true, false] {
            XCTAssertTrue(model.toggleAlbumFlipSentenceFavorite(item, ownerID: "guest"))
            XCTAssertEqual(model.memories[0].sentences[0].isFavorite, expectedState)
            XCTAssertEqual(model.favoriteSentencesCount, expectedState ? 1 : 0)
        }
    }

    func testDoubleTapUsesLiveStateIfFavoriteWasRemovedAfterDeckCreation() throws {
        let model = AppModel()
        model.memories = [makeMemory(count: 1)]
        model.memories[0].sentences[0].isFavorite = true
        defer { model.speech.stop() }
        let item = try XCTUnwrap(AlbumFlipItem.makeItems(from: model.memories).first)
        model.memories[0].sentences[0].isFavorite = false
        model.favoriteSentencesCount = 0
        XCTAssertTrue(item.sentence.isFavorite)
        XCTAssertTrue(model.toggleAlbumFlipSentenceFavorite(item, ownerID: "guest"))
        XCTAssertTrue(model.memories[0].sentences[0].isFavorite)
        XCTAssertEqual(model.favoriteSentencesCount, 1)
    }

    func testDoubleTapRejectsChangedOwnerAndRemovedMemoryOrSentence() throws {
        let model = AppModel()
        model.memories = [makeMemory(count: 1)]
        model.favoriteSentencesCount = 0
        defer { model.speech.stop() }
        let item = try XCTUnwrap(AlbumFlipItem.makeItems(from: model.memories).first)
        XCTAssertFalse(model.toggleAlbumFlipSentenceFavorite(item, ownerID: "another-owner"))
        let wrongMemory = AlbumFlipItem(memoryID: UUID(), memoryCreatedAt: item.memoryCreatedAt, sentence: item.sentence)
        XCTAssertFalse(model.toggleAlbumFlipSentenceFavorite(wrongMemory, ownerID: "guest"))
        model.memories[0].sentences = []
        XCTAssertFalse(model.toggleAlbumFlipSentenceFavorite(item, ownerID: "guest"))
        model.memories = []
        XCTAssertFalse(model.toggleAlbumFlipSentenceFavorite(item, ownerID: "guest"))
        XCTAssertEqual(model.favoriteSentencesCount, 0)
    }

    func testButtonAndDoubleTapCanAlternateUsingTheSameLiveFavoriteState() throws {
        let model = AppModel()
        model.memories = [makeMemory(count: 1)]
        model.favoriteSentencesCount = 0
        defer { model.speech.stop() }
        let item = try XCTUnwrap(AlbumFlipItem.makeItems(from: model.memories).first)
        let button = AlbumFlipFavoriteButton(isFavorite: false) {
            XCTAssertTrue(model.toggleAlbumFlipSentenceFavorite(item, ownerID: "guest"))
        }
        button.action()
        XCTAssertTrue(model.memories[0].sentences[0].isFavorite)
        XCTAssertTrue(model.toggleAlbumFlipSentenceFavorite(item, ownerID: "guest"))
        XCTAssertFalse(model.memories[0].sentences[0].isFavorite)
        button.action()
        XCTAssertTrue(model.memories[0].sentences[0].isFavorite)
        XCTAssertEqual(model.favoriteSentencesCount, 1)
    }

    func testFavoriteToggleRemovesSentenceFavoritedAfterDeckCreation() throws {
        let model = AppModel()
        model.memories = [makeMemory(count: 1)]
        model.favoriteSentencesCount = 0
        defer { model.speech.stop() }
        let item = try XCTUnwrap(AlbumFlipItem.makeItems(from: model.memories).first)
        model.toggleFavorite(sentenceID: item.sentence.id)
        XCTAssertTrue(model.toggleAlbumFlipSentenceFavorite(item, ownerID: "guest"))
        XCTAssertFalse(model.memories[0].sentences[0].isFavorite)
        XCTAssertEqual(model.favoriteSentencesCount, 0)
    }

    func testRecencyWeightDecaysWithoutExcludingOldMemories() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let weights = [0, 7, 30, 90, 365].map { days in
            let item = AlbumFlipItem(
                memoryID: UUID(), memoryCreatedAt: now.addingTimeInterval(-Double(days) * 86_400),
                sentence: SentenceRecord(english: "A quiet afternoon.", chinese: "安静的午后。")
            )
            return item.selectionWeight(at: now, progress: nil)
        }
        XCTAssertEqual(weights, [48, 43, 30, 17, 12])
        for index in 1..<weights.count { XCTAssertLessThan(weights[index], weights[index - 1]) }

        let future = AlbumFlipItem(memoryID: UUID(), memoryCreatedAt: now.addingTimeInterval(86_400),
                                   sentence: SentenceRecord(english: "Tomorrow.", chinese: "明天。"))
        XCTAssertEqual(future.selectionWeight(at: now, progress: nil), weights[0])
    }

    func testRecencyStillPreservesFamiliarityWeighting() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        for days in [0, 30, 365] {
            let item = AlbumFlipItem(memoryID: UUID(), memoryCreatedAt: now.addingTimeInterval(-Double(days) * 86_400),
                                     sentence: SentenceRecord(english: "A quiet afternoon.", chinese: "安静的午后。"))
            func progress(_ feedback: AlbumFlipFeedback) -> AlbumFlipProgress {
                .applying(AlbumFlipEvent(id: UUID(), memoryID: item.memoryID, sentenceID: item.sentence.id,
                                        feedback: feedback, occurredAt: now, timeZoneID: "UTC"), to: nil)
            }
            let unseen = item.selectionWeight(at: now, progress: nil)
            XCTAssertGreaterThan(item.selectionWeight(at: now, progress: progress(.again)), unseen)
            XCTAssertLessThan(item.selectionWeight(at: now, progress: progress(.familiar)), unseen)
        }
    }

    func testDeckUsesRecencyWeightsAndCanStillSelectOldContent() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let memories = [0, 30, 365].map { days in
            MemoryEntry(createdAt: now.addingTimeInterval(-Double(days) * 86_400), imageData: Data(),
                        sentences: [SentenceRecord(english: "A day to remember.", chinese: "值得记住的一天。")])
        }
        let items = AlbumFlipItem.makeItems(from: memories)
        let store = AlbumFlipHistoryStore(defaults: defaults, ownerID: "guest")
        // Check every boundary of the weighted draw, without statistical/flaky assertions.
        for (ticket, expectedIndex) in [(0, 0), (47, 0), (48, 1), (77, 1), (78, 2), (89, 2)] {
            var isFirstDraw = true
            let deck = AlbumFlipDeck(items: items, store: store, now: { now }, randomIndex: { bound in
                guard isFirstDraw else { return 0 }
                isFirstDraw = false
                XCTAssertEqual(bound, 90)
                return ticket
            })
            XCTAssertEqual(try XCTUnwrap(deck.cards.first).item.id, items[expectedIndex].id)
        }
    }

    func testFiltersBlankSentencesAndDuplicateMemories() {
        var memory = makeMemory()
        memory.sentences.append(SentenceRecord(english: "  \n", chinese: ""))
        XCTAssertEqual(AlbumFlipItem.makeItems(from: [memory, memory]).count, 6)
    }

    func testEmptyAlbumHasNoCards() {
        XCTAssertTrue(makeDeck([]).cards.isEmpty)
    }

    func testPhotoRoundVisitsAllSixSentencesBeforeShowingASwipeableInterlude() throws {
        let currentMemory = makeMemory()
        let otherMemory = makeMemory()
        let items = AlbumFlipItem.makeItems(from: [currentMemory])
        let store = AlbumFlipHistoryStore(defaults: defaults, ownerID: "guest")
        let deck = AlbumFlipDeck(items: items, store: store, mode: .photoRounds, randomIndex: { $0 - 1 })
        XCTAssertFalse(deck.isShowingRoundBreak)
        XCTAssertEqual(deck.cards.count, 6)
        XCTAssertEqual(deck.upcomingSpeechTexts.count, 5)
        var visited = Set<String>()
        for index in 0..<6 {
            let current = try XCTUnwrap(deck.cards.first)
            XCTAssertEqual(deck.currentPageID, current.id)
            XCTAssertEqual(deck.currentItem, current.item)
            XCTAssertEqual(current.item.memoryID, currentMemory.id)
            XCTAssertNotEqual(current.item.memoryID, otherMemory.id)
            XCTAssertTrue(visited.insert(current.item.id).inserted)
            XCTAssertEqual(current.item.id, items[5 - index].id)
            let lookahead = Array(deck.cards.dropFirst())
            XCTAssertEqual(deck.upcomingSpeechTexts, lookahead.map { $0.item.sentence.english })
            if index == 5 {
                XCTAssertEqual(deck.visiblePages.count, 2)
                XCTAssertNil(deck.visiblePages.last?.item, "The interlude must already sit behind the last sentence")
            }
            let nextPageID = deck.visiblePages.last?.id
            deck.advance(index.isMultiple(of: 2) ? .again : .familiar, cardID: current.id)
            XCTAssertEqual(deck.currentPageID, nextPageID)
            if index < 5 { XCTAssertEqual(deck.cards.map(\.id), lookahead.map(\.id)) }
            XCTAssertEqual(deck.isShowingRoundBreak, index == 5)
        }
        XCTAssertEqual(visited, Set(items.map(\.id)))
        XCTAssertEqual(deck.viewedCount, 6)
        XCTAssertNil(deck.currentItem, "The interlude must never be treated as a sentence for narration or favorites")
        XCTAssertEqual(deck.cards.count, 6, "The next round is buffered behind the interlude")
        XCTAssertEqual(deck.upcomingSpeechTexts, deck.cards.prefix(5).map { $0.item.sentence.english })
        XCTAssertNil(deck.visiblePages.first?.item)
        XCTAssertEqual(deck.visiblePages.last?.id, deck.cards.first?.id)
        XCTAssertEqual(store.read().pending.count, 6)
        XCTAssertEqual(store.read().records.count, 6)
        XCTAssertTrue(currentMemory.sentences.allSatisfy { !$0.isFavorite })
    }

    func testPhotoRoundDeduplicatesAndIgnoresStaleSentenceAndInterludeAdvances() throws {
        let items = AlbumFlipItem.makeItems(from: [makeMemory(count: 1)])
        let store = AlbumFlipHistoryStore(defaults: defaults, ownerID: "guest")
        let deck = AlbumFlipDeck(items: items + items, store: store, mode: .photoRounds)
        XCTAssertEqual(deck.cards.count, 1)
        let card = try XCTUnwrap(deck.cards.first)
        deck.advance(.again, cardID: UUID())
        XCTAssertEqual(deck.viewedCount, 0)
        deck.advance(.again, cardID: card.id)
        XCTAssertTrue(deck.isShowingRoundBreak)
        deck.advance(.familiar, cardID: card.id)
        deck.reloadHistory()
        XCTAssertTrue(deck.isShowingRoundBreak)
        XCTAssertEqual(deck.viewedCount, 1)
        XCTAssertEqual(store.read().pending.count, 1)
        XCTAssertEqual(deck.feedback[items[0].id], .again)
        let interludeID = try XCTUnwrap(deck.currentPageID)
        let nextCardID = try XCTUnwrap(deck.cards.first?.id)
        deck.advance(.familiar, cardID: interludeID)
        XCTAssertFalse(deck.isShowingRoundBreak)
        XCTAssertEqual(deck.currentPageID, nextCardID)
        XCTAssertNotEqual(nextCardID, card.id)
        deck.advance(.again, cardID: interludeID)
        deck.advance(.familiar, cardID: card.id)
        XCTAssertEqual(deck.currentPageID, nextCardID)
        XCTAssertEqual(deck.viewedCount, 1)
        XCTAssertEqual(store.read().pending.count, 1)
    }

    func testEmptyPhotoRoundDoesNotShowAnInterlude() {
        let deck = AlbumFlipDeck(items: [], store: AlbumFlipHistoryStore(defaults: defaults, ownerID: "guest"), mode: .photoRounds)
        XCTAssertTrue(deck.cards.isEmpty)
        XCTAssertTrue(deck.visiblePages.isEmpty)
        XCTAssertNil(deck.currentPageID)
        XCTAssertNil(deck.currentItem)
        XCTAssertFalse(deck.isShowingRoundBreak)
    }

    func testPhotoRoundRefillsLookaheadWithoutRepeatingAndKeepsBufferedCardsStable() throws {
        let items = AlbumFlipItem.makeItems(from: [makeMemory(count: 10)])
        let store = AlbumFlipHistoryStore(defaults: defaults, ownerID: "guest")
        let deck = AlbumFlipDeck(items: items, store: store, mode: .photoRounds, randomIndex: { _ in 0 })
        let initialCards = deck.cards.map(\.id)
        deck.reloadHistory()
        XCTAssertEqual(deck.cards.map(\.id), initialCards)
        var visited = Set<String>()
        for index in 0..<items.count {
            XCTAssertEqual(deck.cards.count, min(6, items.count - index))
            let current = try XCTUnwrap(deck.cards.first)
            XCTAssertTrue(visited.insert(current.item.id).inserted)
            deck.advance(.again, cardID: current.id)
        }
        XCTAssertTrue(deck.isShowingRoundBreak)
        XCTAssertEqual(visited.count, items.count)
    }

    func testPhotoRoundFeedbackIsAvailableToSubsequentContinuousBrowsing() throws {
        let items = AlbumFlipItem.makeItems(from: [makeMemory(count: 1)])
        let store = AlbumFlipHistoryStore(defaults: defaults, ownerID: "guest")
        let deck = AlbumFlipDeck(items: items, store: store, mode: .photoRounds)
        deck.advance(.familiar, cardID: try XCTUnwrap(deck.cards.first).id)
        let continuous = AlbumFlipDeck(items: items, store: store)
        XCTAssertEqual(continuous.feedback[items[0].id], .familiar)
        XCTAssertEqual(continuous.cards.count, 6)
        XCTAssertFalse(continuous.isShowingRoundBreak)
    }

    func testPhotoRoundsRepeatOnlyTheSameSentencesAndDoNotRecordFeedbackForInterludes() throws {
        let items = AlbumFlipItem.makeItems(from: [makeMemory()])
        let store = AlbumFlipHistoryStore(defaults: defaults, ownerID: "guest")
        let deck = AlbumFlipDeck(items: items, store: store, mode: .photoRounds)
        var appearances = Set<UUID>()
        var callbacks = 0
        deck.onFeedback = { callbacks += 1 }
        for round in 0..<4 {
            var visited = Set<String>()
            for _ in items.indices {
                let pageID = try XCTUnwrap(deck.currentPageID)
                let item = try XCTUnwrap(deck.currentItem)
                XCTAssertTrue(appearances.insert(pageID).inserted)
                XCTAssertTrue(visited.insert(item.id).inserted)
                deck.advance(.familiar, cardID: pageID)
            }
            XCTAssertEqual(visited, Set(items.map(\.id)))
            XCTAssertTrue(deck.isShowingRoundBreak)
            XCTAssertNil(deck.currentItem)
            let interludeID = try XCTUnwrap(deck.currentPageID)
            XCTAssertTrue(appearances.insert(interludeID).inserted)
            let buffered = deck.cards.map(\.id)
            deck.reloadHistory()
            XCTAssertEqual(deck.currentPageID, interludeID)
            XCTAssertEqual(deck.cards.map(\.id), buffered)
            deck.advance(round.isMultiple(of: 2) ? .again : .familiar, cardID: interludeID)
            XCTAssertFalse(deck.isShowingRoundBreak)
            XCTAssertEqual(deck.currentPageID, buffered.first)
            XCTAssertEqual(deck.cards.map(\.id), buffered)
            XCTAssertEqual(deck.viewedCount, (round + 1) * items.count)
            XCTAssertEqual(store.read().pending.count, (round + 1) * items.count)
            XCTAssertEqual(callbacks, (round + 1) * items.count)
        }
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
        let items = AlbumFlipItem.makeItems(from: (0..<3).map { index in
            let memory = makeMemory()
            return MemoryEntry(id: memory.id, createdAt: Date().addingTimeInterval(index == 0 ? -365 * 86_400 : 0),
                               imageData: memory.imageData, sentences: memory.sentences)
        })
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
        XCTAssertEqual(initialWeight, (4 + (items.count - 1) * 12) * 4)
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
        let item = AlbumFlipItem(memoryID: UUID(), memoryCreatedAt: .now, sentence: SentenceRecord(
            english: String(repeating: "The afternoon light fills this little cafe with warmth. ", count: 5),
            chinese: "午后的阳光让这家小咖啡馆充满暖意。"
        ))
        let view = AlbumFlipSentenceCard(item: item, size: CGSize(width: 272, height: 365), showsTranslation: true, onToggleTranslation: {}) {
            Color.orange
        }.environment(\.dynamicTypeSize, .accessibility3)
        let image = try await renderInWindow(view, size: CGSize(width: 272, height: 365))
        XCTAssertEqual(image.size, CGSize(width: 272, height: 365))
    }

    func testFavoriteButtonRendersBothStatesOverThePhotoInBothThemes() async throws {
        let item = AlbumFlipItem.makeItems(from: [makeMemory()])[0]
        let size = CGSize(width: 272, height: 365)
        for scheme in [ColorScheme.light, .dark] {
            var images = [UIImage]()
            for isFavorite in [false, true] {
                let view = AlbumFlipSentenceCard(item: item, size: size, showsTranslation: false, onToggleTranslation: {}) {
                    Image(uiImage: self.samplePhoto).resizable().scaledToFill()
                }
                .overlay(alignment: .topTrailing) {
                    AlbumFlipFavoriteButton(isFavorite: isFavorite, action: {}).padding(12)
                }
                .environment(\.colorScheme, scheme)
                let image = try await renderInWindow(view, size: size)
                images.append(image)
                XCTAssertEqual(image.size, size)
                let attachment = XCTAttachment(image: image)
                attachment.name = "AlbumFlip-Favorite-\(scheme)-\(isFavorite ? "saved" : "unsaved")"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
            XCTAssertNotEqual(images[0].pngData(), images[1].pngData(), "Saved and unsaved icons must be visually distinct")
        }
    }

    func testFavoriteFeedbackAddsHintOnlyWhenSavingAndFitsCompactScreens() async throws {
        for typeSize in [DynamicTypeSize.large, .accessibility3] {
            let saved = UIHostingController(rootView: AlbumFlipFavoriteFeedbackView(isFavorite: true)
                .environment(\.dynamicTypeSize, typeSize))
            let unsaved = UIHostingController(rootView: AlbumFlipFavoriteFeedbackView(isFavorite: false)
                .environment(\.dynamicTypeSize, typeSize))
            let proposal = CGSize(width: 272, height: 500)
            let savedSize = saved.sizeThatFits(in: proposal)
            let unsavedSize = unsaved.sizeThatFits(in: proposal)
            XCTAssertLessThanOrEqual(savedSize.width, proposal.width)
            XCTAssertLessThanOrEqual(unsavedSize.width, proposal.width)
            XCTAssertGreaterThan(savedSize.height, unsavedSize.height,
                                 "Only the saved feedback should include the double-tap hint")
            for scheme in [ColorScheme.light, .dark] {
                for isFavorite in [true, false] {
                    let view = AlbumFlipFavoriteFeedbackView(isFavorite: isFavorite)
                        .frame(maxWidth: 272)
                        .frame(width: 320, height: 240)
                        .background(AppSurfaceColor.page)
                        .environment(\.dynamicTypeSize, typeSize)
                        .environment(\.colorScheme, scheme)
                    let image = try await renderInWindow(view, size: CGSize(width: 320, height: 240))
                    let attachment = XCTAttachment(image: image)
                    attachment.name = "AlbumFlip-FavoriteFeedback-\(isFavorite)-\(scheme)-\(typeSize)"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                }
            }
        }
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

    func testPreloadedPhotoStaysVisibleWhenCardMovesToFront() async throws {
        let state = PhotoRevealTestState(image: samplePhoto, isFront: false)
        let image = try await renderInWindow(
            PhotoRevealTestView(state: state).ignoresSafeArea(), size: CGSize(width: 120, height: 160)
        ) {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { state.isFront = true }
            // Inspect the next frames, not the final image after a new fade could finish.
            try await Task.sleep(for: .milliseconds(40))
        }
        XCTAssertEqual(try pixel(in: image, at: CGPoint(x: 60, y: 40)),
                       try pixel(in: samplePhoto, at: CGPoint(x: 320, y: 80)),
                       "A photo exposed during a swipe must not disappear when it becomes the front card")
    }

    func testPreloadedPhotoStaysVisibleWhenPromotedImmediately() async throws {
        let state = PhotoRevealTestState(image: samplePhoto, isFront: false)
        let image = try await renderInWindow(
            PhotoRevealTestView(state: state).ignoresSafeArea(), size: CGSize(width: 120, height: 160),
            settleDuration: .zero
        ) {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { state.isFront = true }
            try await Task.sleep(for: .milliseconds(40))
        }
        XCTAssertEqual(try pixel(in: image, at: CGPoint(x: 60, y: 40)),
                       try pixel(in: samplePhoto, at: CGPoint(x: 320, y: 80)))
    }

    func testLatePhotoRevealsAfterLoadingWithoutRemainingTransparent() async throws {
        let state = PhotoRevealTestState(image: nil, isFront: true)
        let image = try await renderInWindow(
            PhotoRevealTestView(state: state).ignoresSafeArea(), size: CGSize(width: 120, height: 160)
        ) {
            state.image = self.samplePhoto
            try await Task.sleep(for: .seconds(1))
        }
        XCTAssertEqual(try pixel(in: image, at: CGPoint(x: 60, y: 40)),
                       try pixel(in: samplePhoto, at: CGPoint(x: 320, y: 80)))
    }

    func testPhotoImmediatelyVisibleWithReducedMotionAndOnBufferedCards() async throws {
        for (isFront, reduceMotion) in [(true, true), (false, false)] {
            let view = AlbumFlipPhotoImage(image: samplePhoto, isFront: isFront, reduceMotion: reduceMotion)
                .background(Color.white)
                .ignoresSafeArea()
            let image = try await renderInWindow(view, size: CGSize(width: 120, height: 160), settleDuration: .zero)
            XCTAssertEqual(try pixel(in: image, at: CGPoint(x: 60, y: 40)),
                           try pixel(in: samplePhoto, at: CGPoint(x: 320, y: 80)))
        }
    }

    func testFlipCardSizeAdaptsToAvailableArea() {
        XCTAssertEqual(AlbumFlipLayout.cardSize(in: CGSize(width: 320, height: 430)), CGSize(width: 272, height: 394))
        XCTAssertEqual(AlbumFlipLayout.cardSize(in: CGSize(width: 393, height: 600)), CGSize(width: 345, height: 564))
        XCTAssertEqual(AlbumFlipLayout.cardSize(in: CGSize(width: 1024, height: 900)), CGSize(width: 520, height: 864))
        XCTAssertEqual(AlbumFlipLayout.cardSize(in: .zero), .zero)
    }

    func testRoundBreakCardRendersInBothThemesAndWithoutNetwork() async throws {
        for scheme in [ColorScheme.light, .dark] {
            for isOnline in [true, false] {
                let cardSize = AlbumFlipLayout.cardSize(in: CGSize(width: 320, height: 430))
                let view = AlbumFlipRoundBreakCard(size: cardSize, isPhotoSelectionEnabled: isOnline, onChooseAnotherPhoto: {})
                    .frame(width: 320, height: 568, alignment: .top)
                    .background(AppSurfaceColor.page)
                    .ignoresSafeArea()
                    .environment(\.colorScheme, scheme)
                    .environment(\.dynamicTypeSize, isOnline ? .large : .accessibility3)
                let size = CGSize(width: 320, height: 568)
                let image = try await renderInWindow(view, size: size)
                XCTAssertEqual(image.size, size)
                var stripeColors = Set<[UInt8]>()
                for x in 50...260 {
                    stripeColors.insert(try pixel(in: image, at: CGPoint(x: CGFloat(x), y: 20)))
                }
                XCTAssertGreaterThan(stripeColors.count, 1, "The interlude card should have a visible diagonal hatch, not a flat background")
                XCTAssertEqual(
                    try pixel(in: image, at: CGPoint(x: 160, y: 410)),
                    try pixel(in: image, at: CGPoint(x: 1, y: 140)),
                    "The interlude must stay inside the same fixed card area, even with large text"
                )
                let attachment = XCTAttachment(image: image)
                attachment.name = "AlbumFlip-RoundBreak-\(scheme)-\(isOnline ? "online" : "offline")"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }

    func testPhotoRoundViewStopsSpeechOnInterludeAndRestartsItOnTheNextRound() async throws {
        let model = AppModel()
        model.memories = [makeMemory()]
        model.isNetworkAvailable = false
        model.albumFlipHistorySync = nil
        model.speech.ownerProvider = { "round-test-\(self.suite!)" }
        // Keep playback pending locally; this integration test must never call a cloud service.
        model.speech.sessionProvider = {
            try await Task.sleep(for: .seconds(60))
            throw CancellationError()
        }
        defer { model.speech.stop(); model.speech.cancelAlbumSpeechPrefetch() }
        var narrated: [String] = []
        let observation = model.speech.$activeText.compactMap { $0 }.sink { narrated.append($0) }
        defer { observation.cancel() }
        let store = AlbumFlipHistoryStore(defaults: defaults, ownerID: "guest")
        let deck = AlbumFlipDeck(items: AlbumFlipItem.makeItems(from: model.memories), store: store,
                                 mode: .photoRounds, randomIndex: { _ in 0 })
        let firstText = try XCTUnwrap(deck.currentItem?.sentence.english)
        let view = AlbumFlipView(deck: deck, ownerID: "guest")
            .environmentObject(model)
            .environment(\.scenePhase, .active)
        let image = try await renderInWindow(view, size: CGSize(width: 393, height: 852)) {
            XCTAssertEqual(narrated, [firstText])
            for _ in 0..<6 { deck.advance(.familiar, cardID: try XCTUnwrap(deck.currentPageID)) }
            try await Task.sleep(for: .milliseconds(400))
            XCTAssertTrue(deck.isShowingRoundBreak)
            XCTAssertNil(model.speech.activeText)
            XCTAssertNil(model.speech.loadingText)
            XCTAssertEqual(narrated.count, 1)
            let nextText = try XCTUnwrap(deck.cards.first?.item.sentence.english)
            deck.advance(.again, cardID: try XCTUnwrap(deck.currentPageID))
            try await Task.sleep(for: .milliseconds(450))
            XCTAssertEqual(narrated, [firstText, nextText])
            XCTAssertEqual(deck.viewedCount, 6)
            XCTAssertEqual(store.read().pending.count, 6)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "AlbumFlip-NextRound"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testRoundBreakCardDoesNotShowTheNextPhotoThroughItsBackground() async throws {
        let size = CGSize(width: 280, height: 430)
        for scheme in [ColorScheme.light, .dark] {
            var pixels: [[UInt8]] = []
            for background in [Color.red, .blue] {
                let view = AlbumFlipRoundBreakCard(size: size, isPhotoSelectionEnabled: true, onChooseAnotherPhoto: {})
                    .background(background)
                    .environment(\.colorScheme, scheme)
                    .ignoresSafeArea()
                let image = try await renderInWindow(view, size: size)
                pixels.append(try pixel(in: image, at: CGPoint(x: 140, y: 25)))
            }
            XCTAssertEqual(pixels[0], pixels[1], "Only the outgoing swipe should reveal the card underneath")
        }
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
        _ content: Content, size: CGSize, safeAreaInsets: UIEdgeInsets = .zero,
        settleDuration: Duration = .milliseconds(450), beforeSnapshot: (() async throws -> Void)? = nil
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
        try await Task.sleep(for: settleDuration)
        try await beforeSnapshot?()
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

@MainActor
private final class PhotoRevealTestState: ObservableObject {
    @Published var image: UIImage?
    @Published var isFront: Bool

    init(image: UIImage?, isFront: Bool) {
        self.image = image
        self.isFront = isFront
    }
}

private struct PhotoRevealTestView: View {
    @ObservedObject var state: PhotoRevealTestState

    var body: some View {
        ZStack {
            Color.white
            if let image = state.image {
                AlbumFlipPhotoImage(image: image, isFront: state.isFront, reduceMotion: false)
            }
        }
    }
}
