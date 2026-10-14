import XCTest
@testable import 三句

@MainActor
final class MultilingualStudyIntegrationTests: XCTestCase {
    func testGuestRelaunchRestoresFrozenQueueDraftAndCompletedProgress() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("activations.json")
        let memory = MemoryEntry(imageData: Data(), sentences: [
            SentenceRecord(english: "The coffee is warm.", chinese: "咖啡是热的。", isFavorite: true),
            SentenceRecord(english: "The cup is on the table.", chinese: "杯子在桌上。", isFavorite: true)
        ])
        let first = AppModel()
        first.studyActivationStore = try StudyActivationStore(fileURL: file)
        first.memories = [memory]
        first.localSentenceStudyProgress = [:]
        first.studyLanguage = .english
        first.isNetworkAvailable = false
        await first.startSentenceStudy()
        let state = try XCTUnwrap(first.activeStudySession)
        XCTAssertEqual(first.sentenceStudyQueue.count, 2)
        let completed = first.sentenceStudyQueue[0]
        let unfinished = first.sentenceStudyQueue[1]
        _ = try await first.recordSentenceStudyCompletion(sentenceID: completed.id)
        let question = SentenceStudyQuestion(item: unfinished, seed: state.seed)
        let word = try XCTUnwrap(question.wordBank.first)
        try first.persistStudyDraft(sentenceID: unfinished.id, answers: [word.blankID: word.id])
        let remaining = try XCTUnwrap(first.studyActivationStore).remainingNew(ownerID: AppStorageKey.guestMemoriesUserID)

        let relaunched = AppModel()
        relaunched.studyActivationStore = try StudyActivationStore(fileURL: file)
        relaunched.memories = [memory]
        relaunched.localSentenceStudyProgress = [:]
        relaunched.studyLanguage = .english
        relaunched.isNetworkAvailable = false
        await relaunched.startSentenceStudy()
        let restored = try XCTUnwrap(relaunched.activeStudySession)
        XCTAssertEqual(restored.id, state.id)
        XCTAssertEqual(restored.seed, state.seed)
        XCTAssertEqual(restored.timeZoneID, state.timeZoneID)
        XCTAssertEqual(relaunched.sentenceStudyQueue.map(\.id), [unfinished.id])
        XCTAssertEqual(relaunched.restoreStudyDraft(sentenceID: unfinished.id), [word.blankID: word.id])
        XCTAssertEqual(SentenceStudyQuestion(item: relaunched.sentenceStudyQueue[0], seed: restored.seed).wordBank,
            question.wordBank)
        XCTAssertEqual(relaunched.favoriteSentenceStudyCounts[completed.id], 1)
        XCTAssertEqual(try XCTUnwrap(relaunched.studyActivationStore).remainingNew(ownerID: AppStorageKey.guestMemoriesUserID), remaining)
        XCTAssertFalse(try relaunched.onlineStudyStore().hasPendingEvents(ownerID: AppStorageKey.guestMemoriesUserID))
    }

    func testGuestDirectStudyRestoresDraftAfterRelaunch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("activations.json")
        let memory = MemoryEntry(imageData: Data(), sentences: [
            SentenceRecord(english: "The cup is on the table.", chinese: "杯子在桌上。")
        ])
        let first = AppModel()
        first.studyActivationStore = try StudyActivationStore(fileURL: file)
        first.memories = [memory]
        first.localSentenceStudyProgress = [:]
        first.isNetworkAvailable = false
        let candidate = await first.prepareSentenceForDirectStudy(sentenceID: memory.sentences[0].id)
        let item = try XCTUnwrap(candidate)
        let state = try XCTUnwrap(first.activeStudySession)
        let word = try XCTUnwrap(SentenceStudyQuestion(item: item, seed: state.seed).wordBank.first)
        try first.persistStudyDraft(sentenceID: item.id, answers: [word.blankID: word.id])
        let relaunched = AppModel()
        relaunched.studyActivationStore = try StudyActivationStore(fileURL: file)
        relaunched.memories = [memory]
        relaunched.localSentenceStudyProgress = [:]
        relaunched.isNetworkAvailable = false
        _ = await relaunched.prepareSentenceForDirectStudy(sentenceID: item.id)
        XCTAssertEqual(relaunched.activeStudySession?.id, state.id)
        XCTAssertEqual(relaunched.activeStudySession?.seed, state.seed)
        XCTAssertEqual(relaunched.restoreStudyDraft(sentenceID: item.id), [word.blankID: word.id])
    }

    func testFavoriteFilterUsesMemoryLanguageNotTranslationLanguage() {
        let memories = LearningLanguage.allCases.map { language in
            MemoryEntry(imageData: Data(), sentences: [
                SentenceRecord(english: "Saved", chinese: "Translation", isFavorite: true),
                SentenceRecord(english: "Not saved", chinese: "Translation")
            ], context: MemoryContentContext(targetLanguage: language,
                translationLanguage: .simplifiedChinese, teachingLocale: language.teachingLocale))
        }
        for language in LearningLanguage.allCases {
            let expected = memories.first { $0.context.targetLanguage == language }!.sentences[0].id
            let items = FavoriteSentenceListItem.makeItems(memories: memories,
                studyCounts: [expected: 4], language: language)
            XCTAssertEqual(items.map(\.id), [expected])
            XCTAssertEqual(items.map(\.studyCount), [4])
        }
    }

    func testQuestionUsesFrozenQueueContextAndFailsClosedWithoutJapaneseMaterial() throws {
        let item = queueItem(language: .japanese, text: "湖で泳いでいます。", material: nil)
        let question = SentenceStudyQuestion(item: item)
        XCTAssertFalse(question.isValid)
        XCTAssertTrue(question.wordBank.isEmpty)

        let segments: [SentenceLearningMaterial.Segment] = [
            .init(id: "lake", surface: "湖", reading: "みずうみ", kind: .word, canBlank: true),
            .init(id: "particle", surface: "で", kind: .particle, canBlank: true),
            .init(id: "verb", surface: "泳いでいます", reading: "およいでいます", kind: .phrase, canBlank: true),
            .init(id: "end", surface: "。", kind: .punctuation, canBlank: false)
        ]
        let text = segments.map(\.surface).joined()
        let valid = queueItem(language: .japanese, text: text,
            material: SentenceLearningMaterial(textDigest: SentenceLearningMaterial.digest(text), segments: segments))
        let first = SentenceStudyQuestion(item: valid, seed: 42)
        let restored = SentenceStudyQuestion(item: valid, seed: 42)
        XCTAssertTrue(first.isValid)
        XCTAssertEqual(first.tokens.map(\.displayText).joined(), text)
        XCTAssertEqual(first.wordBank, restored.wordBank)
        XCTAssertTrue(first.tokens.filter(\.isBlank).allSatisfy { $0.visibleReading() == nil })
    }

    func testSessionFreezesLanguageZoneAndEventIdentity() {
        let revision = UUID()
        let state = StudySessionState(language: .french, accountRevision: revision,
            timeZone: TimeZone(identifier: "Europe/Paris")!, seed: 42)
        let sentenceID = UUID()
        let first = state.event(for: sentenceID)
        let retry = state.event(for: sentenceID)
        XCTAssertEqual(state.language, .french)
        XCTAssertEqual(state.timeZoneID, "Europe/Paris")
        XCTAssertEqual(state.accountRevision, revision)
        XCTAssertEqual(state.seed, 42)
        XCTAssertEqual(first.id, retry.id)
        XCTAssertEqual(first.occurredAt, retry.occurredAt)
        XCTAssertNotEqual(state.event(for: UUID()).id, first.id)
    }

    func testRemoteQueueRejectsMixedLanguagesAndInvalidTeachingLocale() throws {
        let json = """
        {"session_id":"00000000-0000-0000-0000-000000000001","remaining_new":29,"items":[{
          "sentence_id":"00000000-0000-0000-0000-000000000002",
          "memory_id":"00000000-0000-0000-0000-000000000003",
          "target_text":"A cup sits here.","translation_text":"杯子在这里。",
          "target_language":"en","translation_language":"zh-Hans","teaching_locale":"en-US",
          "memory_created_at":"2026-10-14T10:00:00Z","image_path":null,
          "learning_step":0,"mastered_review_count":0,"correct_count":0,"wrong_count":0
        }]}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let response = try decoder.decode(MultilingualStudySessionResponse.self, from: Data(json.utf8))
        XCTAssertEqual(try response.queue(language: .english).first?.targetText, "A cup sits here.")
        XCTAssertThrowsError(try response.queue(language: .japanese))
        let invalid = try decoder.decode(MultilingualStudySessionResponse.self,
            from: Data(json.replacingOccurrences(of: "en-US", with: "fr-FR").utf8))
        XCTAssertThrowsError(try invalid.queue(language: .english))
    }

    private func queueItem(language: LearningLanguage, text: String,
                           material: SentenceLearningMaterial?) -> SentenceStudyQueueItem {
        SentenceStudyQueueItem(sentenceID: UUID(), memoryID: UUID(), english: text, chinese: "翻译",
            imagePath: "", createdAt: .now, learningStep: 0, masteredReviewCount: 0,
            correctCount: 0, wrongCount: 0, lastResult: nil, nextReviewAt: nil,
            context: MemoryContentContext(targetLanguage: language, translationLanguage: .simplifiedChinese,
                teachingLocale: language.teachingLocale), learningMaterial: material)
    }
}
