import Foundation
import Combine

extension AppModel {
    var studyAccountOwnerID: String? {
        if isSignedIn { return supabaseSession?.userID }
        // An expired token must not turn a previously signed-in offline session into guest progress.
        guard !isNetworkAvailable, !isRestoringAuthenticatedSession, profile != nil,
              let session = loadStoredSession(), !session.isAnonymous,
              persistedMemoryCacheUserID == session.userID else { return nil }
        return session.userID
    }

    func onlineStudyStore() throws -> StudySessionStore { try studyStorage().sessionStore() }

    func prepareOnlineStudyQueue(language: LearningLanguage, mode: String,
                                 directSentenceID: UUID? = nil) async throws -> [SentenceStudyQueueItem] {
        guard let owner = studyAccountOwnerID else { throw CancellationError() }
        let revision = accountRequests.revision
        let store = try onlineStudyStore()
        try store.removeMemories(ownerID: owner, memoryIDs: memorySyncState.deletedMemoryIDs)
        if !isNetworkAvailable, mode == "today", directSentenceID == nil,
           let review = try store.offlineReview(ownerID: owner, language: language, revision: revision) {
            activeStudySession = review
            return availableStudyItems(review.queue)
        }
        let state = try store.prepare(ownerID: owner, language: language, mode: mode,
            directSentenceID: directSentenceID, revision: revision)
        activeStudySession = state
        let cached = store.confirmedQueue(for: state)
        if !isNetworkAvailable {
            guard let cached else {
                if directSentenceID == nil { return [] }
                throw SentenceStudyTopicLoadingError.networkUnavailable
            }
            return availableStudyItems(cached)
        }
        do {
            let session = try await ensureValidSession()
            guard session.userID == owner, !session.isAnonymous, accountRequests.revision == revision else {
                throw CancellationError()
            }
            let queue = try await supabaseService.beginMultilingualStudySession(session: session, state: state)
            guard isSessionStillCurrent(session), accountRequests.revision == revision,
                  activeStudySession === state else { throw CancellationError() }
            try store.confirm(state, queue: queue)
            return availableStudyItems(store.confirmedQueue(for: state) ?? [])
        } catch {
            guard accountRequests.revision == revision, supabaseSession?.userID == owner else { throw CancellationError() }
            if let cached, let error = error as? URLError,
               [.notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotConnectToHost,
                .cannotFindHost, .dnsLookupFailed].contains(error.code) {
                return availableStudyItems(cached)
            }
            throw error
        }
    }

    func availableStudyItems(_ queue: [SentenceStudyQueueItem]) -> [SentenceStudyQueueItem] {
        queue.filter { item in
            guard !memorySyncState.deletedMemoryIDs.contains(item.memoryID),
                  let memory = memories.first(where: { $0.id == item.memoryID }),
                  memory.context == item.context,
                  let sentence = memory.sentences.first(where: { $0.id == item.id }) else { return false }
            return sentence.targetText.utf8.elementsEqual(item.targetText.utf8) &&
                SentenceStudyQuestion(item: item).isValid
        }
    }

    func replayPendingStudyEvents() async {
        guard isSignedIn, isNetworkAvailable, let owner = supabaseSession?.userID else { return }
        let revision = accountRequests.revision
        do {
            let store = try onlineStudyStore()
            try store.removeMemories(ownerID: owner, memoryIDs: memorySyncState.deletedMemoryIDs)
            let session = try await ensureValidSession()
            guard session.userID == owner, !session.isAnonymous, accountRequests.revision == revision else { return }
            try await store.replay(ownerID: owner, revision: revision, isCurrent: {
                self.isSignedIn && self.supabaseSession?.userID == owner && self.accountRequests.revision == revision
            }, send: { state, sentenceID in
                try await self.supabaseService.recordMultilingualStudyEvent(session: session, state: state,
                    sentenceID: sentenceID)
            })
            guard accountRequests.revision == revision else { return }
            objectWillChange.send()
        } catch {
            // The atomic outbox remains authoritative until a server receipt is saved.
            guard accountRequests.revision == revision else { return }
            objectWillChange.send()
        }
    }

    var studySyncStatusText: String? {
        guard let owner = studyAccountOwnerID,
              let receipts = try? onlineStudyStore().receipts(ownerID: owner) else { return nil }
        if receipts.contains(where: { $0.delivery == .blocked }) {
            return L10n.string("study.sync.blocked", "部分学习记录未被服务器接受，已保留在本机。请重新打开相关句子学习。")
        }
        if receipts.contains(where: { $0.delivery == .pending }) {
            return L10n.string("study.sync.pending", "学习进度已保存在本机，联网后自动同步。")
        }
        return nil
    }

    func overlayPendingStudyProgress(updatesOverview: Bool = true) {
        guard let owner = studyAccountOwnerID, let store = try? onlineStudyStore() else { return }
        let ids = Set(memories.filter { $0.context.targetLanguage == studyLanguage }
            .flatMap { $0.sentences.filter(\.isFavorite).map(\.id) })
        var overlay: [UUID: StudySessionStore.Receipt] = [:]
        for receipt in store.receipts(ownerID: owner) where receipt.delivery == .pending && ids.contains(receipt.sentenceID) {
            if receipt.progress.correctCount > (overlay[receipt.sentenceID]?.progress.correctCount ?? 0) {
                overlay[receipt.sentenceID] = receipt
            }
        }
        for (id, receipt) in overlay {
            guard receipt.progress.correctCount > (favoriteSentenceStudyCounts[id] ?? 0) else { continue }
            favoriteSentenceStudyCounts[id] = receipt.progress.correctCount
            if updatesOverview, StudyCalendar.calendar().isDateInToday(receipt.event.occurredAt) {
                sentenceStudyDueCount = max(0, sentenceStudyDueCount - 1)
                sentenceStudyTodayCount += 1
                sentenceStudyReviewableTodayCount += 1
            }
        }
    }

    func restoreStudyDraft(sentenceID: UUID) -> [UUID: UUID] {
        let owner = studyAccountOwnerID ?? AppStorageKey.guestMemoriesUserID
        guard let state = activeStudySession,
              state.accountRevision == accountRequests.revision,
              state.ownerID == owner else { return [:] }
        return (try? onlineStudyStore().draft(state, sentenceID: sentenceID)) ?? [:]
    }

    func persistStudyDraft(sentenceID: UUID, answers: [UUID: UUID]) throws {
        let owner = studyAccountOwnerID ?? AppStorageKey.guestMemoriesUserID
        guard let state = activeStudySession, state.accountRevision == accountRequests.revision,
              state.ownerID == owner else { throw CancellationError() }
        try onlineStudyStore().saveDraft(state, sentenceID: sentenceID, answers: answers)
    }

    func markStudyQuestionAdvanced(sentenceID: UUID, isReview: Bool) {
        let owner = studyAccountOwnerID ?? AppStorageKey.guestMemoriesUserID
        guard isReview, let state = activeStudySession,
              state.accountRevision == accountRequests.revision,
              state.ownerID == owner else { return }
        do { try onlineStudyStore().finishReviewQuestion(state, sentenceID: sentenceID) }
        catch { sentenceStudyErrorMessage = L10n.string("study.error.load_failed", "暂时无法加载学习内容，请稍后再试。") }
    }

    func refreshCachedOnlineStudyOverview() throws {
        guard let owner = studyAccountOwnerID else { return }
        let store = try onlineStudyStore()
        try store.removeMemories(ownerID: owner, memoryIDs: memorySyncState.deletedMemoryIDs)
        let favorites = Set(memories.filter { $0.context.targetLanguage == studyLanguage }
            .flatMap { $0.sentences.filter(\.isFavorite).map(\.id) })
        let knownCounts = store.knownCounts(ownerID: owner, language: studyLanguage)
        favoriteSentenceStudyCounts = knownCounts.filter { favorites.contains($0.key) }
        memorySentenceCount = memories.filter { $0.context.targetLanguage == studyLanguage }
            .reduce(0) { $0 + $1.sentences.count }
        masteredSentenceCount = knownCounts.values.filter { $0 >= 5 }.count
        let receipts = store.receipts(ownerID: owner).filter { favorites.contains($0.sentenceID) && $0.delivery != .blocked }
        let today = StudyCalendar.calendar()
        let completed = Set(receipts.filter { today.isDateInToday($0.event.occurredAt) }.map(\.sentenceID))
        let queue = availableStudyItems(store.cachedQueue(ownerID: owner, language: studyLanguage, mode: "due"))
            .filter { favorites.contains($0.id) && !completed.contains($0.id) }
        sentenceStudyDueCount = queue.count
        sentenceStudyTodayCount = completed.count
        let review = try store.offlineReview(ownerID: owner, language: studyLanguage, revision: accountRequests.revision)
        let reviewItems = (review?.queue ?? []) + store.cachedQueue(ownerID: owner, language: studyLanguage, mode: "today")
        sentenceStudyReviewableTodayCount = Set(availableStudyItems(reviewItems)
            .filter { favorites.contains($0.id) }.map(\.id)).count
        for receipt in receipts {
            favoriteSentenceStudyCounts[receipt.sentenceID] = max(favoriteSentenceStudyCounts[receipt.sentenceID] ?? 0,
                receipt.progress.correctCount)
        }
        sentenceStudyTopicSummaries = [.favorites: makeFavoriteStudyTopicSummary()]
        studyOverviewLoadState = .loaded
    }

    /// Account deletion calls this explicitly; ordinary sign-out retains the owner's isolated outbox.
    func discardStudyData(ownerID: String) throws {
        try onlineStudyStore().removeOwner(ownerID)
        try studyStorage().removeOwner(ownerID)
        if activeStudySession?.ownerID == ownerID { activeStudySession = nil }
    }
}
