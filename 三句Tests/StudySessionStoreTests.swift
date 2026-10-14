import XCTest
@testable import 三句

@MainActor
final class StudySessionStoreTests: XCTestCase {
    func testGuestUnfinishedQueueDoesNotUseOnlineReceiptExpiry() throws {
        let store = try StudySessionStore(fileURL: file())
        let original = try store.prepare(ownerID: "guest", language: .english, mode: "due",
            revision: UUID(), now: .now.addingTimeInterval(-100 * 86_400), maximumAge: .infinity)
        try store.confirm(original, queue: [item()])
        let restored = try store.prepare(ownerID: "guest", language: .english, mode: "due",
            revision: UUID(), maximumAge: .infinity)
        XCTAssertEqual(restored.id, original.id)
        XCTAssertEqual(restored.seed, original.seed)
    }

    func testGuestCompletionRestoresQueueAndNeverCreatesPendingOnlineEvents() throws {
        let url = file()
        let store = try StudySessionStore(fileURL: url)
        let state = try store.prepare(ownerID: "guest", language: .english, mode: "due", revision: UUID())
        let first = item(), second = item()
        try store.confirm(state, queue: [first, second])
        let question = SentenceStudyQuestion(item: second, seed: state.seed)
        let word = try XCTUnwrap(question.wordBank.first)
        try store.saveDraft(state, sentenceID: second.id, answers: [word.blankID: word.id])
        let progress = SentenceStudyProgress(id: UUID(), sentenceID: first.id, learningStep: 1,
            masteredReviewCount: 0, correctCount: 1, wrongCount: 0, lastResult: .correct,
            lastStudiedAt: .now, nextReviewAt: .now.addingTimeInterval(86_400))
        try store.completeGuestQuestion(state, progress: progress)
        let reopened = try StudySessionStore(fileURL: url)
        let restored = try reopened.prepare(ownerID: "guest", language: .english, mode: "due", revision: UUID())
        XCTAssertEqual(restored.id, state.id)
        XCTAssertEqual(restored.seed, state.seed)
        XCTAssertEqual(reopened.confirmedQueue(for: restored)?.map(\.id), [second.id])
        XCTAssertEqual(reopened.draft(restored, sentenceID: second.id), [word.blankID: word.id])
        XCTAssertEqual(reopened.receipts(ownerID: "guest").first?.progress.correctCount, 1)
        XCTAssertFalse(reopened.hasPendingEvents(ownerID: "guest"))
    }

    func testPendingEventGuardIsOwnerScopedAndExcludesRetainedBlockedReceipts() async throws {
        let store = try StudySessionStore(fileURL: file())
        let state = try store.prepare(ownerID: "alice", language: .english, mode: "due", revision: UUID())
        let sentence = item()
        try store.confirm(state, queue: [sentence])
        XCTAssertFalse(store.hasPendingEvents(ownerID: "alice"))
        _ = try store.enqueue(state, sentenceID: sentence.id)
        XCTAssertTrue(store.hasPendingEvents(ownerID: "alice"))
        XCTAssertFalse(store.hasPendingEvents(ownerID: "bob"))
        try await store.replay(ownerID: "alice", revision: UUID(), isCurrent: { true }) { _, _ in
            throw SupabaseServiceError.apiError("study_sentence_unavailable")
        }
        XCTAssertFalse(store.hasPendingEvents(ownerID: "alice"))
    }

    private func file() -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("sessions.json")
    }

    private func item(_ language: LearningLanguage = .english) -> SentenceStudyQueueItem {
        let text = language == .english ? "The coffee is warm." : "El café está caliente."
        return SentenceStudyQueueItem(sentenceID: UUID(), memoryID: UUID(), english: text, chinese: "翻译",
            imagePath: "", createdAt: .now, learningStep: 0, masteredReviewCount: 0,
            correctCount: 0, wrongCount: 0, lastResult: nil, nextReviewAt: nil,
            context: MemoryContentContext(targetLanguage: language, translationLanguage: .simplifiedChinese,
                teachingLocale: language.teachingLocale),
            learningMaterial: language == .english ? nil : .legacyEnglish(targetText: text))
    }

    func testPendingBeginSurvivesRestartWithoutBecomingAnOfflineClaim() throws {
        let url = file()
        let store = try StudySessionStore(fileURL: url)
        let state = try store.prepare(ownerID: "alice", language: .spanish, mode: "due", revision: UUID())
        XCTAssertNil(store.confirmedQueue(for: state))
        let reopened = try StudySessionStore(fileURL: url)
        let revision = UUID()
        let restored = try reopened.prepare(ownerID: "alice", language: .spanish, mode: "due", revision: revision)
        XCTAssertEqual(restored.id, state.id)
        XCTAssertEqual(restored.seed, state.seed)
        XCTAssertEqual(restored.timeZoneID, state.timeZoneID)
        XCTAssertEqual(restored.language, .spanish)
        XCTAssertEqual(restored.accountRevision, revision)
        XCTAssertNil(reopened.confirmedQueue(for: restored))
        let other = try reopened.prepare(ownerID: "bob", language: .spanish, mode: "due", revision: UUID())
        XCTAssertNotEqual(other.id, state.id)
    }

    func testYesterdayReviewCannotBeRestoredAsTodaysQueue() throws {
        let store = try StudySessionStore(fileURL: file())
        let now = Date.now
        let yesterday = now.addingTimeInterval(-86_400)
        let state = try store.prepare(ownerID: "alice", language: .english, mode: "today",
            revision: UUID(), now: yesterday)
        try store.confirm(state, queue: [item()])
        XCTAssertTrue(store.cachedQueue(ownerID: "alice", language: .english, mode: "today", now: now).isEmpty)
        let restored = try store.prepare(ownerID: "alice", language: .english, mode: "today",
            revision: UUID(), now: now)
        XCTAssertNotEqual(restored.id, state.id)
        XCTAssertNil(store.confirmedQueue(for: restored))
    }

    func testReconfirmationPreservesOriginalQuestionMaterialAndSeed() throws {
        let store = try StudySessionStore(fileURL: file())
        let state = try store.prepare(ownerID: "alice", language: .english, mode: "due", revision: UUID())
        let original = item()
        try store.confirm(state, queue: [original])
        let first = SentenceStudyQuestion(item: original, seed: state.seed)
        let changed = SentenceStudyQueueItem(sentenceID: original.id, memoryID: original.memoryID,
            english: original.targetText, chinese: "A changed translation", imagePath: "", createdAt: .now,
            learningStep: 1, masteredReviewCount: 0, correctCount: 1, wrongCount: 0,
            lastResult: .correct, nextReviewAt: .now,
            learningMaterial: .legacyEnglish(targetText: original.targetText))
        try store.confirm(state, queue: [changed])
        let restored = try XCTUnwrap(store.confirmedQueue(for: state)?.first)
        XCTAssertEqual(restored.translationText, original.translationText)
        XCTAssertNil(restored.learningMaterial)
        XCTAssertEqual(SentenceStudyQuestion(item: restored, seed: state.seed).wordBank, first.wordBank)
    }

    func testConfirmedQueueDraftsAndCompletionRestoreWithOriginalSeed() throws {
        let url = file()
        let store = try StudySessionStore(fileURL: url)
        let state = try store.prepare(ownerID: "alice", language: .english, mode: "due", revision: UUID())
        let first = item(), second = item()
        try store.confirm(state, queue: [first, second])
        let question = SentenceStudyQuestion(item: second, seed: state.seed)
        let word = try XCTUnwrap(question.wordBank.first)
        try store.saveDraft(state, sentenceID: second.id, answers: [word.blankID: word.id])
        let progress = try store.enqueue(state, sentenceID: first.id)
        XCTAssertEqual(progress.correctCount, 1)
        XCTAssertEqual(try store.enqueue(state, sentenceID: first.id).id, progress.id)

        let reopened = try StudySessionStore(fileURL: url)
        let restored = try reopened.prepare(ownerID: "alice", language: .english, mode: "due", revision: UUID())
        XCTAssertEqual(restored.id, state.id)
        XCTAssertEqual(reopened.confirmedQueue(for: restored)?.map(\.id), [second.id])
        XCTAssertEqual(reopened.draft(restored, sentenceID: second.id), [word.blankID: word.id])
        XCTAssertEqual(SentenceStudyQuestion(item: second, seed: restored.seed).wordBank, question.wordBank)
        XCTAssertEqual(reopened.receipts(ownerID: "alice").count, 1)
        XCTAssertEqual(reopened.receipts(ownerID: "alice").first?.delivery, .pending)
        XCTAssertTrue(reopened.receipts(ownerID: "bob").isEmpty)
    }

    func testLostServerResponseReplaysExactEventAfterRestartWithoutDoubleCounting() async throws {
        let url = file()
        let store = try StudySessionStore(fileURL: url)
        let state = try store.prepare(ownerID: "alice", language: .english, mode: "due", revision: UUID())
        let sentence = item()
        try store.confirm(state, queue: [sentence])
        let progress = try store.enqueue(state, sentenceID: sentence.id)
        let original = state.event(for: sentence.id)
        var serverReceipts = Set<UUID>()
        do {
            try await store.replay(ownerID: "alice", revision: UUID(), isCurrent: { true }) { state, id in
                serverReceipts.insert(state.event(for: id).id)
                throw URLError(.networkConnectionLost)
            }
            XCTFail("A lost response must leave the outbox pending")
        } catch is URLError {}
        let reopened = try StudySessionStore(fileURL: url)
        try await reopened.replay(ownerID: "alice", revision: UUID(), isCurrent: { true }) { replay, id in
            XCTAssertEqual(replay.id, state.id)
            XCTAssertEqual(replay.timeZoneID, state.timeZoneID)
            XCTAssertEqual(replay.event(for: id).id, original.id)
            XCTAssertEqual(replay.event(for: id).occurredAt, original.occurredAt)
            serverReceipts.insert(replay.event(for: id).id)
            return progress
        }
        XCTAssertEqual(serverReceipts.count, 1)
        XCTAssertEqual(try StudySessionStore(fileURL: url).receipts(ownerID: "alice").first?.delivery, .acknowledged)
        try await reopened.replay(ownerID: "alice", revision: UUID(), isCurrent: { true }) { _, _ in
            XCTFail("Acknowledged events must not be sent again")
            return progress
        }
    }

    func testAccountChangeDuringReplayNeverAcknowledgesAnotherOwnersEvent() async throws {
        let store = try StudySessionStore(fileURL: file())
        let state = try store.prepare(ownerID: "alice", language: .english, mode: "due", revision: UUID())
        let sentence = item()
        try store.confirm(state, queue: [sentence])
        let progress = try store.enqueue(state, sentenceID: sentence.id)
        var current = true
        do {
            try await store.replay(ownerID: "alice", revision: UUID(), isCurrent: { current }) { _, _ in
                current = false
                return progress
            }
            XCTFail("Account switch must cancel publication")
        } catch is CancellationError {}
        XCTAssertEqual(store.receipts(ownerID: "alice").first?.delivery, .pending)
        try await store.replay(ownerID: "bob", revision: UUID(), isCurrent: { true }) { _, _ in
            XCTFail("No cross-account event may be sent")
            return progress
        }
    }

    func testPermanentRejectionIsRetainedAndDoesNotStarveLaterEvents() async throws {
        let store = try StudySessionStore(fileURL: file())
        let state = try store.prepare(ownerID: "alice", language: .english, mode: "due", revision: UUID())
        let first = item(), second = item()
        try store.confirm(state, queue: [first, second])
        _ = try store.enqueue(state, sentenceID: first.id)
        let progress = try store.enqueue(state, sentenceID: second.id)
        try await store.replay(ownerID: "alice", revision: UUID(), isCurrent: { true }) { _, id in
            if id == first.id { throw SupabaseServiceError.apiError("study_sentence_unavailable") }
            return progress
        }
        XCTAssertEqual(store.receipts(ownerID: "alice").map(\.delivery), [.blocked, .acknowledged])
    }

    func testMemoryAndAccountDeletionDoNotResurrectCachedContent() throws {
        let store = try StudySessionStore(fileURL: file())
        let state = try store.prepare(ownerID: "alice", language: .english, mode: "due", revision: UUID())
        let sentence = item()
        try store.confirm(state, queue: [sentence])
        _ = try store.enqueue(state, sentenceID: sentence.id)
        try store.removeMemories(ownerID: "alice", memoryIDs: [sentence.memoryID])
        XCTAssertTrue(store.receipts(ownerID: "alice").isEmpty)
        XCTAssertTrue(store.confirmedQueue(for: state)!.isEmpty)
        XCTAssertThrowsError(try store.enqueue(state, sentenceID: sentence.id))
        try store.removeOwner("alice")
        XCTAssertNil(store.confirmedQueue(for: state))
    }

    func testDiskFailureCannotAdvanceQuestionOrLosePendingProgress() throws {
        let url = file()
        let store = try StudySessionStore(fileURL: url)
        let state = try store.prepare(ownerID: "alice", language: .english, mode: "due", revision: UUID())
        let sentence = item()
        try store.confirm(state, queue: [sentence])
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        XCTAssertThrowsError(try store.enqueue(state, sentenceID: sentence.id))
        XCTAssertTrue(store.receipts(ownerID: "alice").isEmpty)
        XCTAssertEqual(store.confirmedQueue(for: state)?.map(\.id), [sentence.id])
    }

    func testOfflineSameDayReviewOnlyContainsAlreadyConfirmedSameLanguageSentences() throws {
        let store = try StudySessionStore(fileURL: file())
        let state = try store.prepare(ownerID: "alice", language: .spanish, mode: "due", revision: UUID())
        let sentence = item(.spanish)
        try store.confirm(state, queue: [sentence])
        _ = try store.enqueue(state, sentenceID: sentence.id)
        XCTAssertEqual(try store.offlineReview(ownerID: "alice", language: .spanish, revision: UUID())?.queue.map(\.id), [sentence.id])
        XCTAssertNil(try store.offlineReview(ownerID: "alice", language: .english, revision: UUID()))
        XCTAssertNil(try store.offlineReview(ownerID: "bob", language: .spanish, revision: UUID()))
    }

    func testCorruptSnapshotIsNotOverwritten() throws {
        let url = file()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = Data("not a session snapshot".utf8)
        try bytes.write(to: url)
        XCTAssertThrowsError(try StudySessionStore(fileURL: url))
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    func testWrongSentenceAcknowledgementLeavesOriginalReceiptPending() async throws {
        let store = try StudySessionStore(fileURL: file())
        let state = try store.prepare(ownerID: "alice", language: .english, mode: "due", revision: UUID())
        let sentence = item()
        try store.confirm(state, queue: [sentence])
        _ = try store.enqueue(state, sentenceID: sentence.id)
        do {
            try await store.replay(ownerID: "alice", revision: UUID(), isCurrent: { true }) { _, _ in
                SentenceStudyProgress(id: UUID(), sentenceID: UUID(), learningStep: 1, masteredReviewCount: 0,
                    correctCount: 1, wrongCount: 0, lastResult: .correct, lastStudiedAt: .now, nextReviewAt: .now)
            }
            XCTFail("An unrelated server receipt must never acknowledge local progress")
        } catch {}
        XCTAssertEqual(store.receipts(ownerID: "alice").first?.delivery, .pending)
    }
}
