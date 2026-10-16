import Foundation
import XCTest
@testable import 三句

@MainActor
final class DialogueContentTests: XCTestCase {
    func testTwelveTurnsBecomeSixCardsWithoutCrossingPhotosOrTabs() {
        let first = memory(), second = memory()
        let items = AlbumFlipItem.makeItems(from: [first, second])
        XCTAssertEqual(items.count, 12)
        for item in items {
            XCTAssertEqual(item.sentences.count, 2)
            XCTAssertEqual(item.sentences.compactMap(\.dialogue?.turn), [0, 1])
            XCTAssertEqual(item.sentence.dialogue?.index, item.reply?.dialogue?.index)
            XCTAssertEqual(item.sentence.presentationGroup, item.reply?.presentationGroup)
            let source = item.memoryID == first.id ? first : second
            XCTAssertTrue(item.sentences.allSatisfy { source.sentences.contains($0) })
        }
    }

    func testRoundHasThreeScenePairsThenThreeDescriptionPairsAndBreak() throws {
        let original = memory()
        let deck = AlbumFlipDeck(items: AlbumFlipItem.makeItems(from: [original]), mode: .photoRounds, randomIndex: { _ in 0 })
        var visited = Set<UUID>()
        for index in 0..<6 {
            let item = try XCTUnwrap(deck.currentItem)
            XCTAssertEqual(item.sentence.presentationGroup, index < 3 ? .whatIDSay : .whatISee)
            visited.formUnion(item.sentences.map(\.id))
            deck.navigate(.next, cardID: try XCTUnwrap(deck.currentPageID))
        }
        XCTAssertEqual(visited, Set(original.sentences.map(\.id)))
        XCTAssertTrue(deck.isShowingRoundBreak)
        deck.navigate(.previous, cardID: try XCTUnwrap(deck.currentPageID))
        XCTAssertEqual(deck.currentItem?.sentences.count, 2)
    }

    func testLocalAndWireRoundTripPreservePairIdentityAndSeparateFavorites() throws {
        var original = memory()
        original.sentences[1].isFavorite = true
        let local = try JSONDecoder().decode(MemoryEntry.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(local, original)
        let dto = SupabaseContentMemory(memory: local, imagePath: "owner/photo.jpg")
        try dto.validate()
        let records = try CloudSyncManager().makeRemoteMemories(from: [dto.record()])
        XCTAssertEqual(records.first?.sentences, original.sentences)
        XCTAssertTrue(MemoryIdentity.isContentComplete(try XCTUnwrap(records.first)))
        XCTAssertEqual(records.first?.sentences.filter(\.isFavorite).map(\.id), [original.sentences[1].id])
        let restored = try dto.memory(imageData: original.imageData, isAnonymous: true)
        XCTAssertEqual(restored.sentences, original.sentences)
        XCTAssertFalse(restored.syncedToAccount)
        XCTAssertNil(restored.remoteImagePath)
    }

    func testMalformedPairsCannotBeImportedOrConsideredComplete() throws {
        let original = memory()
        var missing = original
        missing.sentences.removeLast()
        var duplicates = original
        let first = original.sentences[0]
        duplicates.sentences[1] = SentenceRecord(targetText: first.targetText, translationText: first.translationText,
            presentationGroup: first.presentationGroup, dialogue: first.dialogue)
        var incomplete = original
        incomplete.sentences[1] = SentenceRecord(targetText: "A standalone sentence.", translationText: "A translation.")
        for invalid in [missing, duplicates, incomplete] {
            XCTAssertFalse(MemoryIdentity.isContentComplete(invalid))
            XCTAssertThrowsError(try SupabaseContentMemory(memory: invalid, imagePath: "").validate())
        }
    }

    func testLegacySentencesRemainIndependentAndDoNotReceiveInventedReplies() throws {
        let original = MemoryEntry(imageData: Data(), sentences: (0..<6).map { i in
            SentenceRecord(english: "Original sentence \(i).", chinese: "Original translation.")
        })
        try SupabaseContentMemory(memory: original, imagePath: "").validate()
        let items = AlbumFlipItem.makeItems(from: [original])
        XCTAssertEqual(items.count, 6)
        XCTAssertTrue(items.allSatisfy { $0.reply == nil })
        XCTAssertTrue(MemoryIdentity.isContentComplete(original))
    }

    func testPairOrderComesFromTurnNotArrayPosition() {
        var original = memory()
        original.sentences.reverse()
        let items = AlbumFlipItem.makeItems(from: [original])
        XCTAssertEqual(items.count, 6)
        XCTAssertTrue(items.allSatisfy { $0.sentence.dialogue?.turn == 0 && $0.reply?.dialogue?.turn == 1 })
    }

    func testCardFavoriteSavesBothTurnsWhileSingleTurnCanBeManagedSeparately() throws {
        let model = AppModel()
        model.networkStatusMonitor.cancel()
        model.isNetworkAvailable = false
        model.memories = [memory()]
        defer { model.speech.stop() }
        let item = try XCTUnwrap(AlbumFlipItem.makeItems(from: model.memories).first)
        XCTAssertTrue(model.toggleAlbumFlipSentenceFavorite(item, ownerID: model.albumFlipOwnerID))
        XCTAssertEqual(Set(model.memories[0].sentences.filter(\.isFavorite).map(\.id)), Set(item.sentences.map(\.id)))
        model.toggleFavorite(sentenceID: item.reply!.id)
        XCTAssertEqual(model.memories[0].sentences.filter(\.isFavorite).map(\.id), [item.sentence.id])
        XCTAssertTrue(model.toggleAlbumFlipSentenceFavorite(item, ownerID: model.albumFlipOwnerID))
        XCTAssertEqual(model.memories[0].sentences.filter(\.isFavorite).count, 2)
        XCTAssertTrue(model.toggleAlbumFlipSentenceFavorite(item, ownerID: model.albumFlipOwnerID))
        XCTAssertTrue(model.memories[0].sentences.allSatisfy { !$0.isFavorite })
    }

    func testNewGenerationUsesDialogueFormatAndOldSnapshotStillValidates() throws {
        let spec = GenerationSpec(selection: .legacyEnglish(explanationLanguage: .simplifiedChinese), level: .beginner)
        XCTAssertEqual(spec.generationFormat, "dialogue_tabs_v1")
        try spec.validate()
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(spec)) as? [String: Any])
        json["generationFormat"] = "dual_tabs_v1"
        let old = try JSONDecoder().decode(GenerationSpec.self, from: JSONSerialization.data(withJSONObject: json))
        try old.validate()
        XCTAssertEqual(old.generationFormat, "dual_tabs_v1")
    }

    private func memory() -> MemoryEntry {
        MemoryEntry(imageData: Data([1, 2, 3]), sentences: (0..<12).map { i in
            SentenceRecord(targetText: i % 2 == 0 ? "Shall we sit by the window for a while?" : "Yes, the afternoon light is really lovely over there.",
                translationText: i % 2 == 0 ? "We could sit by the window." : "The light is lovely.",
                presentationGroup: i < 6 ? .whatISee : .whatIDSay,
                dialogue: SentenceDialogue(index: (i % 6) / 2, turn: i % 2))
        })
    }
}
