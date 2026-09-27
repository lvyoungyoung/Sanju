import Foundation

extension AppModel {
    func loadStudySceneMatchSettings(sceneID: UUID) async throws -> StudySceneMatchSettings {
        let session = try await studyMatchSettingsSession()
        var result = try await supabaseService.fetchStudySceneMatchSettings(session: session, sceneID: sceneID)
        if result.needsPreparation == true {
            guard isSignedIn, supabaseSession?.userID == session.userID, !Task.isCancelled else { throw CancellationError() }
            try await supabaseService.prepareStudySceneMatching(session: session, sceneID: sceneID)
            result = try await supabaseService.fetchStudySceneMatchSettings(session: session, sceneID: sceneID)
        }
        guard isSignedIn, supabaseSession?.userID == session.userID, !Task.isCancelled else {
            throw CancellationError()
        }
        return result
    }

    func saveStudySceneMatchSettings(sceneID: UUID, threshold: Double) async throws -> StudySceneMatchSettings {
        let session = try await studyMatchSettingsSession()
        let result = try await supabaseService.updateStudySceneMatchSettings(
            session: session, sceneID: sceneID, threshold: threshold
        )
        guard isSignedIn, supabaseSession?.userID == session.userID, !Task.isCancelled else {
            throw CancellationError()
        }
        invalidateUserStudySceneDetailSentenceCache(for: sceneID)
        return result
    }

    private func studyMatchSettingsSession() async throws -> SupabaseSession {
        guard isSignedIn else { throw SentenceStudyTopicLoadingError.signInRequired }
        guard isNetworkAvailable else { throw SentenceStudyTopicLoadingError.networkUnavailable }
        let userID = supabaseSession?.userID
        let session = try await ensureValidSession()
        guard !session.isAnonymous, isSignedIn, session.userID == userID else { throw CancellationError() }
        return session
    }
}
