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
        XCTAssertEqual(spec.generationFormat, "scenario_dialogue_v1")
        try spec.validate()
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(spec)) as? [String: Any])
        json["generationFormat"] = "dual_tabs_v1"
        let old = try JSONDecoder().decode(GenerationSpec.self, from: JSONSerialization.data(withJSONObject: json))
        try old.validate()
        XCTAssertEqual(old.generationFormat, "dual_tabs_v1")
        json["generationFormat"] = "dialogue_tabs_v1"
        try JSONDecoder().decode(GenerationSpec.self, from: JSONSerialization.data(withJSONObject: json)).validate()
        json["generationFormat"] = "dialogue_trio_v1"
        try JSONDecoder().decode(GenerationSpec.self, from: JSONSerialization.data(withJSONObject: json)).validate()
    }

    func testTrioRoundUsesPairOrderWithEitherMiddleStyleAndPreservesHistory() throws {
        for middle in SentencePresentationGroup.allCases {
            var original = trio(middle: middle)
            original.sentences.reverse()
            let items = AlbumFlipItem.makeItems(from: [original])
            XCTAssertEqual(items.map { $0.sentence.dialogue?.index }, [0, 1, 2])
            let deck = AlbumFlipDeck(items: items.reversed(), mode: .photoRounds, randomIndex: { $0 - 1 })
            var visited: [UUID] = []
            for index in 0..<3 {
                let item = try XCTUnwrap(deck.currentItem)
                XCTAssertEqual(item.sentence.dialogue?.index, index)
                XCTAssertEqual(item.sentences.compactMap(\.dialogue?.turn), [0, 1])
                visited.append(try XCTUnwrap(deck.currentPageID))
                XCTAssertTrue(deck.navigate(.next, cardID: try XCTUnwrap(deck.currentPageID)))
            }
            XCTAssertTrue(deck.isShowingRoundBreak)
            XCTAssertTrue(deck.navigate(.previous, cardID: try XCTUnwrap(deck.currentPageID)))
            XCTAssertEqual(deck.currentPageID, visited.last)
            XCTAssertTrue(deck.navigate(.next, cardID: try XCTUnwrap(deck.currentPageID)))
            XCTAssertTrue(deck.isShowingRoundBreak)
            XCTAssertTrue(deck.navigate(.next, cardID: try XCTUnwrap(deck.currentPageID)))
            XCTAssertEqual(deck.currentItem?.sentence.dialogue?.index, 0)
        }
    }

    func testTrioLocalCloudAndGuestRoundTrips() throws {
        for middle in SentencePresentationGroup.allCases {
            var original = trio(middle: middle)
            original.sentences[1].isFavorite = true
            let local = try JSONDecoder().decode(MemoryEntry.self, from: JSONEncoder().encode(original))
            XCTAssertTrue(MemoryIdentity.isContentComplete(local))
            let dto = SupabaseContentMemory(memory: local, imagePath: "owner/photo.jpg")
            try dto.validate()
            let restored = try dto.memory(imageData: local.imageData, isAnonymous: true)
            XCTAssertEqual(restored.sentences, original.sentences)
            let remote = try CloudSyncManager().makeRemoteMemories(from: [dto.record()])
            XCTAssertEqual(remote.first?.sentences, original.sentences)
        }
    }

    func testTrioRejectsMissingDuplicateAndCrossGroupTurns() throws {
        let original = trio(middle: .whatISee)
        var missing = original
        missing.sentences.removeLast()
        var duplicate = original
        duplicate.sentences[1] = original.sentences[0]
        var wrongGroup = original
        wrongGroup.sentences[1] = SentenceRecord(targetText: original.sentences[1].targetText,
            translationText: original.sentences[1].translationText, presentationGroup: .whatIDSay,
            dialogue: original.sentences[1].dialogue)
        var wrongIndex = original
        let sentence = original.sentences[4]
        wrongIndex.sentences[4] = SentenceRecord(targetText: sentence.targetText, translationText: sentence.translationText,
            presentationGroup: sentence.presentationGroup, dialogue: SentenceDialogue(index: 1, turn: 0))
        for invalid in [missing, duplicate, wrongGroup, wrongIndex] {
            XCTAssertFalse(MemoryIdentity.isContentComplete(invalid))
            XCTAssertThrowsError(try SupabaseContentMemory(memory: invalid, imagePath: "").validate())
        }
    }

    func testScenarioLocalCloudAndGuestRoundTripsPreserveTitlesAndThirdTurnFavorite() throws {
        for count in [2, 3] {
            var original = scenarios(count: count)
            original.sentences[2].isFavorite = true
            let local = try JSONDecoder().decode(MemoryEntry.self, from: JSONEncoder().encode(original))
            XCTAssertEqual(local, original)
            XCTAssertTrue(local.sentences.isCompleteScenarioDialogues)
            XCTAssertTrue(MemoryIdentity.isContentComplete(local))
            XCTAssertFalse(local.sentences.isCompleteDialogueTrio)
            let dto = SupabaseContentMemory(memory: local, imagePath: "owner/photo.jpg")
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .custom { decoder in
                let value = try decoder.singleValueContainer().decode(String.self)
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                return try XCTUnwrap(formatter.date(from: value))
            }
            let wire = try decoder.decode(SupabaseContentMemory.self, from: JSONEncoder().encode(dto))
            try wire.validate()
            let remote = try CloudSyncManager().makeRemoteMemories(from: [wire.record()])
            let guest = try wire.memory(imageData: local.imageData, isAnonymous: true)
            XCTAssertEqual(remote.first?.sentences, original.sentences)
            XCTAssertEqual(guest.sentences, original.sentences)
            XCTAssertEqual(guest.sentences.filter(\.isFavorite).map(\.id), [original.sentences[2].id])
            XCTAssertFalse(guest.syncedToAccount)
            XCTAssertNil(guest.remoteImagePath)

            let payload: [String: Any] = ["status": "completed", "remainingCredits": 2,
                "memory": try JSONSerialization.jsonObject(with: JSONEncoder().encode(dto))]
            let response = try decoder.decode(SupabaseContentGenerationResponse.self,
                from: JSONSerialization.data(withJSONObject: payload))
            XCTAssertEqual(try response.result(imageData: local.imageData, isAnonymous: true)?.memory.sentences,
                           original.sentences)
        }
    }

    func testScenarioTitlesUseUnicodeCodePointsAndRejectInvalidTitles() throws {
        for title in ["喝点什么", String(repeating: "😀", count: 24)] {
            let dialogue = SentenceDialogue(index: 0, turn: 2, title: title)
            XCTAssertTrue(dialogue.isValid)
            XCTAssertEqual(try JSONDecoder().decode(SentenceDialogue.self, from: JSONEncoder().encode(dialogue)), dialogue)
        }
        for title in ["", " ", " 前空格", "后空格 ", "中\n间", "中\u{0085}间",
                      String(repeating: "字", count: 25), String(repeating: "e\u{0301}", count: 13)] {
            XCTAssertFalse(SentenceDialogue(index: 0, turn: 0, title: title).isValid, title)
        }
        XCTAssertFalse(SentenceDialogue(index: 0, turn: 2).isValid)
        XCTAssertFalse(SentenceDialogue(index: 3, turn: 0, title: "点餐").isValid)
        XCTAssertFalse(SentenceDialogue(index: 0, turn: 3, title: "点餐").isValid)
        XCTAssertEqual((0..<3).map { SentenceDialogue(index: 0, turn: $0, title: "点餐").speaker }, ["A", "B", "A"])
        let legacy = try JSONDecoder().decode(SentenceDialogue.self, from: Data(#"{"index":0,"turn":1}"#.utf8))
        XCTAssertNil(legacy.title)
        XCTAssertTrue(legacy.isValid)
        XCTAssertThrowsError(try JSONDecoder().decode(SentenceDialogue.self,
            from: Data(#"{"index":0,"turn":1,"title":null}"#.utf8)))
    }

    func testScenarioRejectsMalformedShapesAcrossLocalWireAndRecovery() throws {
        let original = scenarios(count: 2)
        var invalids: [MemoryEntry] = []
        var missing = original
        missing.sentences.removeLast()
        invalids.append(missing)
        invalids.append(scenarios(count: 1))
        invalids.append(scenarios(count: 4))
        var duplicateID = original
        duplicateID.sentences[1] = original.sentences[0]
        invalids.append(duplicateID)
        for dialogue in [SentenceDialogue(index: 0, turn: 0, title: "喝点什么"),
                         SentenceDialogue(index: 2, turn: 1, title: "喝点什么"),
                         SentenceDialogue(index: 0, turn: 1, title: "不同标题"),
                         SentenceDialogue(index: 0, turn: 1),
                         SentenceDialogue(index: 0, turn: 1, title: "")] {
            var invalid = original
            invalid.sentences[1] = replacing(original.sentences[1], dialogue: dialogue)
            invalids.append(invalid)
        }
        var mixed = original
        mixed.sentences[1] = replacing(original.sentences[1], dialogue: nil)
        invalids.append(mixed)
        var wrongGroup = original
        wrongGroup.sentences[1] = replacing(original.sentences[1], dialogue: original.sentences[1].dialogue, group: .whatISee)
        invalids.append(wrongGroup)
        var duplicateTitle = original
        for i in 3..<6 {
            duplicateTitle.sentences[i] = replacing(original.sentences[i],
                dialogue: SentenceDialogue(index: 1, turn: i - 3, title: "喝点什么"))
        }
        invalids.append(duplicateTitle)
        for invalid in invalids {
            XCTAssertFalse(invalid.sentences.isCompleteScenarioDialogues)
            XCTAssertFalse(MemoryIdentity.isContentComplete(invalid))
            let dto = SupabaseContentMemory(memory: invalid, imagePath: "")
            XCTAssertThrowsError(try dto.validate())
            XCTAssertThrowsError(try dto.memory(imageData: Data(), isAnonymous: true))
            XCTAssertThrowsError(try JSONDecoder().decode(MemoryEntry.self, from: JSONEncoder().encode(invalid)))
            let response = SupabaseContentGenerationResponse(status: "completed", recovered: true,
                memory: dto, remainingCredits: 1, guestJobID: nil, clientRequestID: nil)
            XCTAssertThrowsError(try response.result(imageData: Data(), isAnonymous: true))
        }
        let nineSingles = MemoryEntry(imageData: Data(), sentences: (0..<9).map { i in
            SentenceRecord(english: "Standalone \(i)", chinese: "翻译")
        })
        XCTAssertFalse(nineSingles.sentences.isCompleteSentenceCollection)
    }

    func testScenarioGroupsAndPhotoRoundsPreserveThreeTurnsAndIndexOrder() throws {
        for count in [2, 3] {
            var original = scenarios(count: count)
            original.sentences.reverse()
            let groups = original.sentences.dialogueGroups
            XCTAssertEqual(groups.count, count)
            XCTAssertEqual(groups.map(\.scenarioTitle), Array(["喝点什么", "忙里偷闲", "拿错咖啡"].prefix(count)))
            let items = AlbumFlipItem.makeItems(from: [original])
            XCTAssertEqual(items.count, count)
            XCTAssertEqual(items.map(\.scenarioTitle), groups.map(\.scenarioTitle))
            for item in items {
                XCTAssertEqual(item.sentences.compactMap(\.dialogue?.turn), [0, 1, 2])
                XCTAssertEqual(item.sentences.compactMap(\.dialogue?.speaker), ["A", "B", "A"])
                XCTAssertNotNil(item.continuation)
            }
            let deck = AlbumFlipDeck(items: items.reversed(), mode: .photoRounds, randomIndex: { $0 - 1 })
            XCTAssertFalse(deck.navigate(.previous, cardID: try XCTUnwrap(deck.currentPageID)))
            for index in 0..<count {
                XCTAssertEqual(deck.currentItem?.sentence.dialogue?.index, index)
                XCTAssertEqual(deck.currentItem?.sentences.count, 3)
                XCTAssertTrue(deck.navigate(.next, cardID: try XCTUnwrap(deck.currentPageID)))
            }
            XCTAssertTrue(deck.isShowingRoundBreak)
            XCTAssertTrue(deck.navigate(.next, cardID: try XCTUnwrap(deck.currentPageID)))
            XCTAssertEqual(deck.currentItem?.sentence.dialogue?.index, 0)
        }
    }

    func testScenarioHistoryAndPreloadKeepAllThreeLinesInTheSameOrder() throws {
        let memories = [scenarios(count: 2), scenarios(count: 3), scenarios(count: 2)]
        let items = AlbumFlipItem.makeItems(from: memories)
        XCTAssertEqual(items.count, 7)
        let deck = AlbumFlipDeck(items: items, randomIndex: { _ in 0 })
        var ids: [UUID] = []
        var lines: [[UUID]] = []
        var preloads: [[UUID]] = []
        for _ in 0..<8 {
            ids.append(try XCTUnwrap(deck.currentPageID))
            lines.append(try XCTUnwrap(deck.currentItem).sentences.map(\.id))
            let upcoming = deck.upcomingSpeechItems.flatMap(\.sentences)
            preloads.append(upcoming.map(\.id))
            XCTAssertEqual(upcoming.count, AlbumFlipDeck.lookaheadCount * 3)
            XCTAssertEqual(deck.upcomingSpeechTexts, upcoming.map(\.targetText))
            let memoryID = deck.currentItem?.memoryID
            XCTAssertTrue(deck.navigate(.next, cardID: try XCTUnwrap(deck.currentPageID)))
            XCTAssertNotEqual(deck.currentItem?.memoryID, memoryID)
        }
        for index in (0..<8).reversed() {
            XCTAssertTrue(deck.navigate(.previous, cardID: try XCTUnwrap(deck.currentPageID)))
            XCTAssertEqual(deck.currentPageID, ids[index])
            XCTAssertEqual(deck.currentItem?.sentences.map(\.id), lines[index])
            XCTAssertEqual(deck.upcomingSpeechItems.flatMap(\.sentences).map(\.id), preloads[index])
        }
        for index in 1..<8 {
            XCTAssertTrue(deck.navigate(.next, cardID: try XCTUnwrap(deck.currentPageID)))
            XCTAssertEqual(deck.currentPageID, ids[index])
            XCTAssertEqual(deck.upcomingSpeechItems.flatMap(\.sentences).map(\.id), preloads[index])
        }
    }

    func testScenarioFavoriteIncludesThirdTurnAndCanToggleItIndependently() throws {
        let model = AppModel()
        model.networkStatusMonitor.cancel()
        model.isNetworkAvailable = false
        model.memories = [scenarios(count: 2)]
        defer { model.speech.stop() }
        let item = try XCTUnwrap(AlbumFlipItem.makeItems(from: model.memories).first)
        XCTAssertTrue(model.toggleAlbumFlipSentenceFavorite(item, ownerID: model.albumFlipOwnerID))
        XCTAssertEqual(Set(model.memories[0].sentences.filter(\.isFavorite).map(\.id)), Set(item.sentences.map(\.id)))
        model.toggleFavorite(sentenceID: try XCTUnwrap(item.continuation).id)
        XCTAssertEqual(model.memories[0].sentences.filter(\.isFavorite).count, 2)
        XCTAssertTrue(model.toggleAlbumFlipSentenceFavorite(item, ownerID: model.albumFlipOwnerID))
        XCTAssertEqual(model.memories[0].sentences.filter(\.isFavorite).count, 3)
        XCTAssertTrue(model.toggleAlbumFlipSentenceFavorite(item, ownerID: model.albumFlipOwnerID))
        XCTAssertTrue(model.memories[0].sentences.allSatisfy { !$0.isFavorite })
    }

    private func replacing(_ sentence: SentenceRecord, dialogue: SentenceDialogue?,
                           group: SentencePresentationGroup = .whatIDSay) -> SentenceRecord {
        SentenceRecord(id: sentence.id, targetText: sentence.targetText, translationText: sentence.translationText,
                       presentationGroup: group, dialogue: dialogue)
    }

    private func scenarios(count: Int) -> MemoryEntry {
        let titles = ["喝点什么", "忙里偷闲", "拿错咖啡", "第四组"]
        let lines = ["Would you like some coffee?", "Yes, a small cup would be lovely.", "I'll get one for you too."]
        return MemoryEntry(imageData: Data([1, 2, 3]), sentences: (0..<(count * 3)).map { i in
            SentenceRecord(targetText: lines[i % 3], translationText: "翻译 \(i)",
                           presentationGroup: .whatIDSay,
                           dialogue: SentenceDialogue(index: i / 3, turn: i % 3, title: titles[i / 3]))
        })
    }

    private func trio(middle: SentencePresentationGroup) -> MemoryEntry {
        MemoryEntry(imageData: Data([1, 2, 3]), sentences: (0..<6).map { index in
            SentenceRecord(targetText: index % 2 == 0 ? "Shall we sit by the window for a while?" : "Yes, the afternoon light is really lovely over there.",
                translationText: "A translated sentence.",
                presentationGroup: index < 2 ? .whatISee : (index < 4 ? middle : .whatIDSay),
                dialogue: SentenceDialogue(index: index / 2, turn: index % 2))
        })
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
