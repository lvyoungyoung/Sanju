import Foundation

@MainActor
protocol MultilingualSentenceExplanationServicing {
    func sentenceExplanation(session: SupabaseSession, request: SentenceExplanationRequestV3) async throws -> SentenceExplanation?
}

extension SupabaseServicing {
    func sentenceExplanation(session: SupabaseSession, request: SentenceExplanationRequestV3) async throws -> SentenceExplanation? {
        guard let service = self as? any MultilingualSentenceExplanationServicing else {
            throw URLError(.unsupportedURL)
        }
        return try await service.sentenceExplanation(session: session, request: request)
    }
}

extension SupabaseService: MultilingualSentenceExplanationServicing {
    func sentenceExplanation(session: SupabaseSession, request input: SentenceExplanationRequestV3) async throws -> SentenceExplanation? {
        guard input.isValid else { throw SentenceExplanationError.unsupportedLanguage }
        var request = try makeRequest(path: "/functions/v1/explain-sentence-v2", method: "POST",
                                      bearerToken: session.accessToken, body: input)
        request.timeoutInterval = 75
        let response: SentenceExplanationResponse = try await perform(request)
        if let explanation = response.explanation, !input.accepts(explanation) {
            throw URLError(.cannotParseResponse)
        }
        return response.explanation
    }
}
