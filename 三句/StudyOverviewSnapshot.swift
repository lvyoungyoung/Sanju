import Foundation

@MainActor
protocol StudyOverviewFetching {
    func fetchSentenceStudyDueCount(session: SupabaseSession) async throws -> Int
    func fetchSentenceStudyTodayCount(session: SupabaseSession) async throws -> Int
    func fetchSentenceStudyReviewableTodayCount(session: SupabaseSession) async throws -> Int
    func fetchMemorySentencesCount(session: SupabaseSession) async throws -> Int
    func fetchMasteredSentenceCount(session: SupabaseSession) async throws -> Int
    func fetchSentenceStudyCounts(session: SupabaseSession, sentenceIDs: [UUID]) async throws -> [UUID: Int]
    func fetchUserStudySceneSummaries(session: SupabaseSession) async throws -> [UserStudySceneSummary]
}

// A missing result means "keep the current value", not zero or an empty list.
struct StudyOverviewSnapshot {
    let dueCount: Int?
    let todayCount: Int?
    let reviewableTodayCount: Int?
    let sentenceCount: Int?
    let masteredCount: Int?
    let favoriteCounts: [UUID: Int]?
    let scenes: [UserStudySceneSummary]?

    static func load(
        from service: StudyOverviewFetching,
        session: SupabaseSession,
        favoriteSentenceIDs: Set<UUID>,
        onScenesLoaded: (([UserStudySceneSummary]?) -> Void)? = nil,
        onContentLoaded: (([UserStudySceneSummary]?, Int?) -> Void)? = nil
    ) async throws -> StudyOverviewSnapshot {
        async let dueCount = fetch { try await service.fetchSentenceStudyDueCount(session: session) }
        async let todayCount = fetch { try await service.fetchSentenceStudyTodayCount(session: session) }
        async let reviewableTodayCount = fetch { try await service.fetchSentenceStudyReviewableTodayCount(session: session) }
        async let sentenceCount = fetch { try await service.fetchMemorySentencesCount(session: session) }
        async let masteredCount = fetch { try await service.fetchMasteredSentenceCount(session: session) }
        async let favoriteCounts = fetch {
            favoriteSentenceIDs.isEmpty ? [:] : try await service.fetchSentenceStudyCounts(session: session, sentenceIDs: Array(favoriteSentenceIDs))
        }
        async let scenes = fetch { try await service.fetchUserStudySceneSummaries(session: session) }
        let loadedScenes = try await scenes
        try Task.checkCancellation()
        onScenesLoaded?(loadedScenes)
        let content = try await (loadedScenes, sentenceCount)
        try Task.checkCancellation()
        onContentLoaded?(content.0, content.1)
        return try await StudyOverviewSnapshot(
            dueCount: dueCount,
            todayCount: todayCount,
            reviewableTodayCount: reviewableTodayCount,
            sentenceCount: sentenceCount,
            masteredCount: masteredCount,
            favoriteCounts: favoriteCounts,
            scenes: scenes
        )
    }

    private static func fetch<Value: Sendable>(_ operation: @MainActor @Sendable () async throws -> Value) async throws -> Value? {
        try Task.checkCancellation()
        do {
            let value = try await operation()
            try Task.checkCancellation()
            return value
        } catch {
            try Task.checkCancellation()
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                throw error
            }
            return nil
        }
    }
}
