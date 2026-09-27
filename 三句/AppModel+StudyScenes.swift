import Foundation

extension AppModel {
    // MARK: - Themes and detail cache

    func refreshUserStudySceneSummaries() async {
        let refreshID = UUID()
        studySceneSummariesRefreshID = refreshID
        guard !isRestoringAuthenticatedSession else { return }
        guard isSignedIn else {
            userStudySceneSummaries = []
            return
        }

        let requestedUserID = supabaseSession?.userID
        do {
            let session = try await ensureValidSession()
            guard !session.isAnonymous, session.userID == requestedUserID,
                  isSessionStillCurrent(session) else { return }

            let scenes = try await supabaseService.fetchUserStudySceneSummaries(session: session)
            guard !Task.isCancelled, isSignedIn, isSessionStillCurrent(session),
                  studySceneSummariesRefreshID == refreshID else { return }
            userStudySceneSummaries = scenes
        } catch {
            return
        }
    }

    func cachedUserStudySceneDetailSentences(for sceneID: UUID) -> [SentenceStudyQueueItem]? {
        userStudySceneDetailSentenceCache[sceneID]
    }

    func invalidateUserStudySceneDetailSentenceCache(for sceneID: UUID? = nil) {
        if let sceneID {
            userStudySceneDetailSentenceCache.removeValue(forKey: sceneID)
        } else {
            userStudySceneDetailSentenceCache.removeAll()
        }
    }

    func createUserStudyScene(
        named name: String,
        learningTopicID: String? = nil
    ) async throws -> UserStudySceneSummary {
        guard isSignedIn else {
            isShowingSignInSheet = true
            throw SentenceStudyTopicLoadingError.signInRequired
        }

        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard StudySceneCreationPolicy.canCreate(currentCount: userStudySceneSummaries.count)
            || userStudySceneSummaries.contains(where: { $0.name == normalizedName }) else {
            throw SentenceStudyTopicLoadingError.limitReached
        }

        guard isNetworkAvailable else {
            throw SentenceStudyTopicLoadingError.networkUnavailable
        }

        let session = try await ensureValidSession()
        let scene = try await supabaseService.createUserStudyScene(
            session: session,
            name: name,
            learningTopicID: learningTopicID
        )
        if let existingIndex = userStudySceneSummaries.firstIndex(where: { $0.id == scene.id }) {
            userStudySceneSummaries[existingIndex] = scene
        } else {
            userStudySceneSummaries.insert(scene, at: 0)
        }
        invalidateUserStudySceneDetailSentenceCache(for: scene.id)
        return scene
    }

    func deleteUserStudyScene(_ scene: UserStudySceneSummary) async throws {
        guard isSignedIn else {
            isShowingSignInSheet = true
            throw SentenceStudyTopicLoadingError.signInRequired
        }

        guard isNetworkAvailable else {
            throw SentenceStudyTopicLoadingError.networkUnavailable
        }

        let session = try await ensureValidSession()
        guard !session.isAnonymous else {
            throw SentenceStudyTopicLoadingError.signInRequired
        }

        try await supabaseService.deleteUserStudyScene(session: session, sceneID: scene.id)
        userStudySceneSummaries.removeAll { $0.id == scene.id }
        invalidateUserStudySceneDetailSentenceCache(for: scene.id)
        await refreshSentenceStudyDueCount()
    }

    // MARK: - Study queues and details

    func loadUserStudySceneSession(
        for scene: UserStudySceneSummary
    ) async throws -> SentenceStudyTopicSession? {
        guard isNetworkAvailable else {
            throw SentenceStudyTopicLoadingError.networkUnavailable
        }

        let session = try await ensureValidSession()
        guard !session.isAnonymous else {
            throw SentenceStudyTopicLoadingError.signInRequired
        }

        let queue = try await supabaseService.fetchUserStudySceneQueue(
            session: session,
            sceneID: scene.id,
            limit: 1000
        ).shuffled()
        if !queue.isEmpty {
            await refreshSentenceStudyDueCount()
            return SentenceStudyTopicSession(topic: scene.studyTopic, queue: queue, startsInReviewMode: false)
        }

        let reviewQueue = try await supabaseService.fetchUserStudySceneTodayReviewQueue(
            session: session,
            sceneID: scene.id,
            limit: 1000
        ).shuffled()
        await refreshSentenceStudyDueCount()
        guard !reviewQueue.isEmpty else { return nil }
        return SentenceStudyTopicSession(topic: scene.studyTopic, queue: reviewQueue, startsInReviewMode: true)
    }

    func refreshUserStudySceneDetailSentences(
        for scene: UserStudySceneSummary,
        ifCurrent: () -> Bool = { true }
    ) async throws -> [SentenceStudyQueueItem] {
        guard isNetworkAvailable else {
            throw SentenceStudyTopicLoadingError.networkUnavailable
        }

        let session = try await ensureValidSession()
        guard !session.isAnonymous else {
            throw SentenceStudyTopicLoadingError.signInRequired
        }

        let sentences = try await supabaseService.fetchUserStudySceneDetailSentences(
            session: session,
            sceneID: scene.id,
            limit: 1000
        )
        guard isSignedIn, supabaseSession?.userID == session.userID,
              !Task.isCancelled, ifCurrent() else { throw CancellationError() }
        userStudySceneDetailSentenceCache[scene.id] = sentences
        return sentences
    }

    func reviewUserStudyScene(_ scene: UserStudySceneSummary) async throws -> SupabaseStudySceneReviewStatus {
        guard isNetworkAvailable else {
            throw SentenceStudyTopicLoadingError.networkUnavailable
        }
        let session = try await ensureValidSession()
        guard !session.isAnonymous else {
            throw SentenceStudyTopicLoadingError.signInRequired
        }
        let status = try await supabaseService.reviewUserStudyScene(session: session, sceneID: scene.id)
        guard supabaseSession?.userID == session.userID else { throw CancellationError() }
        return status
    }

}
