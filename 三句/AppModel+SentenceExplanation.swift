import Foundation

extension AppModel {
    func sentenceExplanation(sentence: SentenceRecord, context: MemoryContentContext,
                             language: SupportLanguage, generate: Bool) async throws -> SentenceExplanation? {
        try Task.checkCancellation()
        let revision = accountRequests.revision
        let input = SentenceExplanationRequestV3(
            sentenceID: sentence.id, targetText: sentence.targetText, translationText: sentence.translationText,
            targetLanguage: context.targetLanguage, translationLanguage: context.translationLanguage,
            teachingLocale: context.teachingLocale, contentVersion: sentence.contentVersion,
            contentSchemaVersion: context.schemaVersion, explanationLanguage: language,
            exampleTranslationLanguage: learningSelection.mode == .legacyEnglish && context.isLegacyCompatible && language == .english
                ? .simplifiedChinese : language,
            generate: generate
        )
        guard input.supportsExplanation else { throw SentenceExplanationError.unsupportedLanguage }
        guard input.isValid else { throw URLError(.cannotParseResponse) }
        let environment = Bundle.main.supabasePersistenceNamespace ?? "unconfigured"
        func cached(owner: String) async -> SentenceExplanation? {
            if let saved = await SentenceExplanationCache.shared.load(key: input.cacheKey(owner: owner, environment: environment)),
               input.accepts(saved) { return saved }
            if let legacy = input.legacyRequest,
               let saved = await SentenceExplanationCache.shared.load(key: legacy.cacheKey(owner: owner)) {
                return input.adaptingLegacy(saved)
            }
            return nil
        }
        if let owner = supabaseSession?.userID, let saved = await cached(owner: owner) {
            try accountRequests.check(revision)
            return saved
        }
        guard isNetworkAvailable else { throw URLError(.notConnectedToInternet) }
        await ensureRemoteSessionRestoreCompleted()
        try accountRequests.check(revision)
        let session = try await ensureValidSession()
        try accountRequests.check(revision)
        if let saved = await cached(owner: session.userID) {
            try accountRequests.check(revision)
            return saved
        }
        let result = try await supabaseService.sentenceExplanation(session: session, request: input)
        try accountRequests.check(revision)
        guard supabaseSession?.userID == session.userID else { throw CancellationError() }
        if let result {
            guard input.accepts(result) else { throw URLError(.cannotParseResponse) }
            await SentenceExplanationCache.shared.save(result, key: input.cacheKey(owner: session.userID, environment: environment))
            try accountRequests.check(revision)
        }
        return result
    }

    func sentenceExplanation(sentence: SentenceRecord, language: String, generate: Bool) async throws -> SentenceExplanation? {
        let revision = accountRequests.revision
        let input = SentenceExplanationRequest(
            sentenceID: sentence.id, english: sentence.english, chinese: sentence.chinese,
            language: language, generate: generate
        )
        if let owner = supabaseSession?.userID,
           let saved = await SentenceExplanationCache.shared.load(key: input.cacheKey(owner: owner)) {
            try accountRequests.check(revision)
            if saved.version == SentenceExplanation.formatVersion { return saved }
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
            guard result.version == SentenceExplanation.formatVersion else { throw URLError(.cannotParseResponse) }
            await SentenceExplanationCache.shared.save(result, key: input.cacheKey(owner: session.userID))
            try accountRequests.check(revision)
        }
        return result
    }
}
