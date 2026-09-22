import Foundation

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
        favoriteSentenceIDs: Set<UUID>
    ) async throws -> StudyOverviewSnapshot {
        let dueCount = try await fetch { try await service.fetchSentenceStudyDueCount(session: session) }
        let todayCount = try await fetch { try await service.fetchSentenceStudyTodayCount(session: session) }
        let reviewableTodayCount = try await fetch { try await service.fetchSentenceStudyReviewableTodayCount(session: session) }
        let sentenceCount = try await fetch { try await service.fetchMemorySentencesCount(session: session) }
        let masteredCount = try await fetch { try await service.fetchMasteredSentenceCount(session: session) }
        let favoriteCounts: [UUID: Int]?
        if favoriteSentenceIDs.isEmpty {
            favoriteCounts = [:]
        } else {
            favoriteCounts = try await fetch {
                try await service.fetchSentenceStudyCounts(session: session, sentenceIDs: Array(favoriteSentenceIDs))
            }
        }
        let scenes = try await fetch { try await service.fetchUserStudySceneSummaries(session: session) }
        return StudyOverviewSnapshot(
            dueCount: dueCount,
            todayCount: todayCount,
            reviewableTodayCount: reviewableTodayCount,
            sentenceCount: sentenceCount,
            masteredCount: masteredCount,
            favoriteCounts: favoriteCounts,
            scenes: scenes
        )
    }

    private static func fetch<Value>(_ operation: () async throws -> Value) async throws -> Value? {
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
