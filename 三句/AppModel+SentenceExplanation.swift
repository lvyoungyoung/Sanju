import Foundation

extension AppModel {
    func sentenceExplanation(sentence: SentenceRecord, language: String, generate: Bool) async throws -> SentenceExplanation? {
        let revision = accountRequests.revision
        let input = SentenceExplanationRequest(
            sentenceID: sentence.id, english: sentence.english, chinese: sentence.chinese,
            language: language, generate: generate
        )
        if let owner = supabaseSession?.userID,
           let saved = await SentenceExplanationCache.shared.load(key: input.cacheKey(owner: owner)) {
            try accountRequests.check(revision)
            return saved
        }
        guard isNetworkAvailable else { throw URLError(.notConnectedToInternet) }
        await ensureRemoteSessionRestoreCompleted()
        try accountRequests.check(revision)
        let session = try await ensureValidSession()
        try accountRequests.check(revision)
        let result = try await supabaseService.sentenceExplanation(session: session, request: input)
        try accountRequests.check(revision)
        guard supabaseSession?.userID == session.userID else { throw CancellationError() }
        if let result {
            await SentenceExplanationCache.shared.save(result, key: input.cacheKey(owner: session.userID))
            try accountRequests.check(revision)
        }
        return result
    }
}
