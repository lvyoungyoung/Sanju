import Foundation

extension SupabaseLocalSentenceStudyProgressMergeItem {
    static func guestImport(progressRecords: [LocalSentenceStudyProgress], activations: [StudyActivationStore.Activation],
                            timeZone: TimeZone = .current) -> [Self] {
        var firstActivations: [UUID: Date] = [:]
        for activation in activations {
            // Legacy progress already existed before the activation ledger; it must not use today's quota.
            let date = activation.isLegacy ? Date(timeIntervalSince1970: 0) : activation.firstActivatedAt
            firstActivations[activation.sentenceID] = min(firstActivations[activation.sentenceID] ?? date, date)
        }
        var progressBySentence: [UUID: LocalSentenceStudyProgress] = [:]
        for progress in progressRecords where progress.studyTopic.usesFavoriteQueue {
            progressBySentence[progress.sentenceID] = progress
        }
        let sentenceIDs = Set(progressBySentence.keys).union(firstActivations.keys).sorted { $0.uuidString < $1.uuidString }
        return sentenceIDs.map { sentenceID in
            let progress = progressBySentence[sentenceID]
            let first = firstActivations[sentenceID] ?? progress?.lastStudiedAt ?? Date(timeIntervalSince1970: 0)
            return Self(sentenceID: sentenceID.uuidString.lowercased(), studyScope: "favorites",
                learningStep: progress?.learningStep ?? 0, masteredReviewCount: progress?.masteredReviewCount ?? 0,
                correctCount: progress?.correctCount ?? 0, wrongCount: progress?.wrongCount ?? 0,
                lastResult: progress?.lastResult?.rawValue, lastStudiedAt: progress?.lastStudiedAt,
                lastStudiedOn: StudyCalendar.dayString(from: progress?.lastStudiedAt ?? progress?.lastStudiedDay, timeZone: timeZone),
                nextReviewOn: StudyCalendar.dayString(from: progress?.nextReviewDay ?? first, timeZone: timeZone) ?? "1970-01-01",
                firstActivatedAt: first)
        }
    }
}

extension SupabaseService {
    func mergeLocalSentenceStudyProgress(session: SupabaseSession, progressRecords: [LocalSentenceStudyProgress],
        activations: [StudyActivationStore.Activation]) async throws -> Set<SentenceStudyProgressKey> {
        let items = SupabaseLocalSentenceStudyProgressMergeItem.guestImport(progressRecords: progressRecords, activations: activations)
        var accepted = Set<SentenceStudyProgressKey>()
        for start in stride(from: 0, to: items.count, by: 1000) {
            try Task.checkCancellation()
            let chunk = Array(items[start..<min(start + 1000, items.count)])
            let records: [SupabaseMergedSentenceStudyProgressRecord] = try await contentRPC(session: session,
                name: "merge_local_sentence_study_progress_v2", payload: SupabaseLocalSentenceStudyProgressMergeRequest(items: chunk))
            let requested = Set(chunk.map(\.sentenceID))
            for record in records {
                guard let sentenceID = UUID(uuidString: record.sentenceID), record.studyScope == "favorites",
                      requested.contains(sentenceID.uuidString.lowercased()) else {
                    throw SupabaseServiceError.invalidResponse
                }
                accepted.insert(SentenceStudyProgressKey(sentenceID: sentenceID, studyTopic: .favorites))
            }
        }
        return accepted
    }
}
