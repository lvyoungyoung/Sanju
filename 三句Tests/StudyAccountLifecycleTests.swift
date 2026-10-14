import Foundation
import XCTest
@testable import 三句

@MainActor
final class StudyAccountLifecycleTests: XCTestCase {
    private func model() async throws -> (AppModel, StudySessionStore, SupabaseSession) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StudyLifecycleOfflineProtocol.self]
        let service = SupabaseService(session: URLSession(configuration: configuration),
            baseURL: URL(string: "https://study.invalid")!, publishableKey: "test")
        let model = AppModel(supabaseService: service)
        await model.ensureRemoteSessionRestoreCompleted()
        model.generationPreferenceSync = nil
        model.learningPreferenceSync = nil
        model.speechPreferenceSync = nil
        model.albumFlipHistorySync = nil
        model.isNetworkAvailable = false
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let activations = try StudyActivationStore(fileURL: directory.appendingPathComponent("activations.json"))
        model.studyActivationStore = activations
        let session = SupabaseSession(accessToken: "test", refreshToken: "test", userID: UUID().uuidString,
            expiresAt: .distantFuture, isAnonymous: false)
        model.supabaseSession = session
        addTeardownBlock { @MainActor in
            model.completeLocalSignOutTransaction()
            try? FileManager.default.removeItem(at: directory)
        }
        return (model, try activations.sessionStore(), session)
    }

    private func enqueue(_ store: StudySessionStore, owner: String) throws -> StudySessionState {
        let state = try store.prepare(ownerID: owner, language: .english, mode: "due", revision: UUID())
        let item = SentenceStudyQueueItem(sentenceID: UUID(), memoryID: UUID(),
            english: "The coffee is warm.", chinese: "Coffee translation", imagePath: "", createdAt: .now,
            learningStep: 0, masteredReviewCount: 0, correctCount: 0, wrongCount: 0,
            lastResult: nil, nextReviewAt: nil)
        try store.confirm(state, queue: [item])
        _ = try store.enqueue(state, sentenceID: item.id)
        return state
    }

    func testConfirmedDeletionPurgesOnlyDeletedOwnersStudyData() async throws {
        let (model, store, session) = try await model()
        let active = try enqueue(store, owner: session.userID)
        _ = try enqueue(store, owner: "other-owner")
        model.activeStudySession = active
        model.beginPendingDeleteAccountLocalClear(session: session)
        model.markPendingDeleteAccountRemoteDeletionConfirmed(for: session.userID)
        model.completeRemoteConfirmedPendingDeleteAccountLocalClearIfNeeded()
        XCTAssertTrue(store.receipts(ownerID: session.userID).isEmpty)
        XCTAssertNil(store.confirmedQueue(for: active))
        XCTAssertNil(model.activeStudySession)
        XCTAssertTrue(store.hasPendingEvents(ownerID: "other-owner"))
        XCTAssertNil(model.defaults.data(forKey: AppStorageKey.pendingLocalAccountTransition))
    }

    func testLogoutRetainsOwnerOutboxButPendingEventsGuardOrdinarySignOut() async throws {
        let (model, store, session) = try await model()
        _ = try enqueue(store, owner: "other-owner")
        XCTAssertFalse(model.hasPendingStudyEventsForSignOut)
        _ = try enqueue(store, owner: session.userID)
        XCTAssertTrue(model.hasPendingStudyEventsForSignOut)
        XCTAssertTrue(model.shouldPreventSignOutForCloudChanges)
        model.signOut()
        XCTAssertEqual(model.supabaseSession?.userID, session.userID)
        model.completeLocalSignOutTransaction()
        XCTAssertTrue(store.hasPendingEvents(ownerID: session.userID))
        XCTAssertTrue(store.hasPendingEvents(ownerID: "other-owner"))
    }

    func testUnconfirmedDeleteDoesNotPurgeStudyOutbox() async throws {
        let (model, store, session) = try await model()
        _ = try enqueue(store, owner: session.userID)
        model.beginPendingDeleteAccountLocalClear(session: session)
        model.completeRemoteConfirmedPendingDeleteAccountLocalClearIfNeeded()
        XCTAssertTrue(store.hasPendingEvents(ownerID: session.userID))
        model.completePendingDeleteAccountLocalClearIfNeeded()
        XCTAssertTrue(store.hasPendingEvents(ownerID: session.userID))
    }

    func testUnfavoritedProgressMigratesWithoutIncludingOtherOwnersSentences() async throws {
        let (model, _, _) = try await model()
        let sentence = SentenceRecord(targetText: "The coffee is warm.", translationText: "Coffee translation",
            isFavorite: false)
        model.memories = [MemoryEntry(imageData: Data(), sentences: [sentence])]
        let owned = LocalSentenceStudyProgress(sentenceID: sentence.id, correctCount: 3)
        let unrelated = LocalSentenceStudyProgress(sentenceID: UUID(), correctCount: 5)
        model.localSentenceStudyProgress = [
            SentenceStudyProgressKey(sentenceID: owned.sentenceID, studyTopic: .favorites): owned,
            SentenceStudyProgressKey(sentenceID: unrelated.sentenceID, studyTopic: .favorites): unrelated
        ]
        let progress = model.localSentenceStudyProgressToMerge()
        XCTAssertEqual(progress, [owned])
        let payload = SupabaseLocalSentenceStudyProgressMergeItem.guestImport(progressRecords: progress, activations: [])
        XCTAssertEqual(payload.count, 1)
        XCTAssertEqual(payload.first?.correctCount, 3)
        XCTAssertEqual(payload.first?.sentenceID, sentence.id.uuidString.lowercased())
    }

    func testBlockedReceiptsRemainStoredWithoutPermanentlyPreventingLogout() async throws {
        let (model, store, session) = try await model()
        _ = try enqueue(store, owner: session.userID)
        try await store.replay(ownerID: session.userID, revision: UUID(), isCurrent: { true }) { _, _ in
            throw SupabaseServiceError.apiError("study_sentence_unavailable")
        }
        XCTAssertEqual(store.receipts(ownerID: session.userID).first?.delivery, .blocked)
        XCTAssertFalse(model.hasPendingStudyEventsForSignOut)
        model.completeLocalSignOutTransaction()
        XCTAssertEqual(store.receipts(ownerID: session.userID).first?.delivery, .blocked)
    }
}

private nonisolated final class StudyLifecycleOfflineProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}
