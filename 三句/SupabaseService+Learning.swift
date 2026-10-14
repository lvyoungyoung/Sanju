import Foundation

@MainActor
protocol StudyRPCTransport {
    func contentRPC<Response: Decodable, Payload: Encodable>(session: SupabaseSession, name: String,
                                                            payload: Payload) async throws -> Response
}

extension SupabaseService: StudyRPCTransport {}

struct MultilingualStudyOverview: Decodable {
    let dueCount: Int
    let studiedTodayCount: Int
    let remainingNew: Int

    enum CodingKeys: String, CodingKey {
        case dueCount = "due_count"
        case studiedTodayCount = "studied_today_count"
        case remainingNew = "remaining_new"
    }
}

struct MultilingualStudySessionResponse: Decodable {
    let sessionID: UUID
    let items: [MultilingualStudyQueueRecord]
    let remainingNew: Int

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id", items
        case remainingNew = "remaining_new"
    }

    func queue(language: LearningLanguage) throws -> [SentenceStudyQueueItem] {
        try items.map { record in
            guard record.targetLanguage == language else { throw URLError(.cannotParseResponse) }
            let item = record.item
            try item.context.validate()
            guard SentenceStudyQuestion(item: item).isValid else { throw URLError(.cannotParseResponse) }
            return item
        }
    }
}

struct MultilingualStudyQueueRecord: Codable {
    let sentenceID: UUID
    let memoryID: UUID
    let targetText: String
    let translationText: String
    let targetLanguage: LearningLanguage
    let translationLanguage: SupportLanguage
    let teachingLocale: TeachingLocale
    let learningMaterial: SentenceLearningMaterial?
    let imagePath: String?
    let createdAt: Date
    let learningStep: Int
    let masteredReviewCount: Int
    let correctCount: Int
    let wrongCount: Int
    let lastResult: SentenceStudyResult?
    let nextReviewAt: Date?

    init(item: SentenceStudyQueueItem) {
        sentenceID = item.id; memoryID = item.memoryID
        targetText = item.targetText; translationText = item.translationText
        targetLanguage = item.context.targetLanguage; translationLanguage = item.context.translationLanguage
        teachingLocale = item.context.teachingLocale; learningMaterial = item.learningMaterial
        imagePath = item.imagePath; createdAt = item.createdAt
        learningStep = item.learningStep; masteredReviewCount = item.masteredReviewCount
        correctCount = item.correctCount; wrongCount = item.wrongCount
        lastResult = item.lastResult; nextReviewAt = item.nextReviewAt
    }

    enum CodingKeys: String, CodingKey {
        case sentenceID = "sentence_id", memoryID = "memory_id"
        case targetText = "target_text", translationText = "translation_text"
        case targetLanguage = "target_language", translationLanguage = "translation_language"
        case teachingLocale = "teaching_locale", learningMaterial = "learning_material"
        case imagePath = "image_path", createdAt = "memory_created_at"
        case learningStep = "learning_step", masteredReviewCount = "mastered_review_count"
        case correctCount = "correct_count", wrongCount = "wrong_count"
        case lastResult = "last_result", nextReviewAt = "next_review_at"
    }

    var item: SentenceStudyQueueItem {
        SentenceStudyQueueItem(sentenceID: sentenceID, memoryID: memoryID,
            english: targetText, chinese: translationText, imagePath: imagePath ?? "", createdAt: createdAt,
            learningStep: learningStep, masteredReviewCount: masteredReviewCount, correctCount: correctCount,
            wrongCount: wrongCount, lastResult: lastResult, nextReviewAt: nextReviewAt,
            context: MemoryContentContext(targetLanguage: targetLanguage,
                translationLanguage: translationLanguage, teachingLocale: teachingLocale),
            learningMaterial: learningMaterial)
    }
}

extension SupabaseServicing {
    func fetchMultilingualStudyCounts(session: SupabaseSession, language: LearningLanguage,
                                     sentenceIDs: Set<UUID>) async throws -> [UUID: Int] {
        guard !sentenceIDs.isEmpty else { return [:] }
        let rows: [StudyProgressCountRow] = try await studyRPC(session: session,
            name: "get_sentence_study_progress_v2", payload: ["p_target_language": language.rawValue])
        return rows.reduce(into: [:]) { counts, row in
            guard row.study_scope == "favorites", sentenceIDs.contains(row.sentence_id) else { return }
            counts[row.sentence_id] = row.correct_count
        }
    }

    func fetchMultilingualStudyOverview(session: SupabaseSession, language: LearningLanguage,
                                       timeZoneID: String = TimeZone.current.identifier) async throws -> MultilingualStudyOverview {
        try await studyRPC(session: session, name: "get_study_overview_v2", payload: [
            "p_target_language": language.rawValue, "p_scope": "favorites", "p_time_zone": timeZoneID
        ])
    }

    func beginMultilingualStudySession(session: SupabaseSession, state: StudySessionState) async throws -> [SentenceStudyQueueItem] {
        let response: MultilingualStudySessionResponse
        if let sentenceID = state.directSentenceID {
            response = try await studyRPC(session: session, name: "begin_direct_study_session_v2", payload: [
                "p_session_id": state.id.uuidString, "p_sentence_id": sentenceID.uuidString,
                "p_time_zone": state.timeZoneID
            ])
        } else {
            response = try await studyRPC(session: session,
                name: "begin_study_session_v2", payload: BeginStudyRequest(p_session_id: state.id,
                    p_target_language: state.language.rawValue, p_mode: state.mode, p_time_zone: state.timeZoneID))
        }
        guard response.sessionID == state.id else { throw URLError(.cannotParseResponse) }
        return try response.queue(language: state.language)
    }

    func recordMultilingualStudyEvent(session: SupabaseSession, state: StudySessionState,
                                     sentenceID: UUID) async throws -> SentenceStudyProgress {
        let event = state.event(for: sentenceID)
        let row: SupabaseSentenceStudyProgressRecord = try await studyRPC(session: session,
            name: "record_study_event_v2", payload: StudyEventRequest(p_event_id: event.id,
                p_session_id: state.id, p_sentence_id: sentenceID,
                p_occurred_at: ISO8601DateFormatter().string(from: event.occurredAt), p_time_zone: state.timeZoneID))
        guard let id = UUID(uuidString: row.id), UUID(uuidString: row.sentenceID) == sentenceID else {
            throw URLError(.cannotParseResponse)
        }
        return SentenceStudyProgress(id: id, sentenceID: sentenceID, learningStep: row.learningStep,
            masteredReviewCount: row.masteredReviewCount, correctCount: row.correctCount,
            wrongCount: row.wrongCount, lastResult: row.lastResult.flatMap(SentenceStudyResult.init(rawValue:)),
            lastStudiedAt: row.lastStudiedAt, nextReviewAt: row.nextReviewAt)
    }

    private func studyRPC<Response: Decodable>(session: SupabaseSession, name: String,
                                               payload: some Encodable) async throws -> Response {
        guard let transport = self as? any StudyRPCTransport else { throw URLError(.unsupportedURL) }
        return try await transport.contentRPC(session: session, name: name, payload: payload)
    }
}

private struct BeginStudyRequest: Encodable {
    let p_session_id: UUID
    let p_target_language: String
    let p_scope = "favorites"
    let p_limit = 1000
    let p_mode: String
    let p_time_zone: String
}

private struct StudyEventRequest: Encodable {
    let p_event_id: UUID
    let p_session_id: UUID
    let p_sentence_id: UUID
    let p_was_correct = true
    let p_occurred_at: String
    let p_time_zone: String
}

private struct StudyProgressCountRow: Decodable {
    let sentence_id: UUID
    let study_scope: String
    let correct_count: Int
}
