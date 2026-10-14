import Foundation

/// Confirmed queues and an outbox share one atomic file, so advancing a question cannot lose its event.
@MainActor
final class StudySessionStore {
    enum StoreError: Error { case unsupportedVersion, invalidSession, missingSentence }
    enum Delivery: String, Codable { case pending, acknowledged, blocked }

    struct Receipt: Codable {
        let sentenceID: UUID
        let event: StudySessionState.Event
        var progress: SentenceStudyProgress
        var delivery: Delivery = .pending
    }

    struct SavedSession: Codable {
        let ownerID: String
        let id: UUID
        let language: LearningLanguage
        let timeZoneID: String
        let seed: UInt64
        let mode: String
        let directSentenceID: UUID?
        let createdAt: Date
        var queue: [MultilingualStudyQueueRecord]?
        var completedIDs: Set<UUID> = []
        var receipts: [Receipt] = []
        var drafts: [UUID: [UUID: UUID]] = [:]

        func state(revision: UUID) throws -> StudySessionState {
            guard let zone = TimeZone(identifier: timeZoneID) else { throw StoreError.invalidSession }
            let state = StudySessionState(language: language, accountRevision: revision, mode: mode,
                directSentenceID: directSentenceID, id: id, timeZone: zone, seed: seed)
            state.ownerID = ownerID
            state.queue = queue?.map(\.item) ?? []
            state.sentenceIDs = Set(state.queue.map(\.id))
            state.events = Dictionary(uniqueKeysWithValues: receipts.map { ($0.sentenceID, $0.event) })
            return state
        }
    }

    private struct FileSnapshot: Codable {
        var schemaVersion = 1
        var sessions: [SavedSession] = []
    }

    private let fileURL: URL
    private var snapshot: FileSnapshot
    private var replayingOwners: Set<String> = []

    init(fileURL: URL) throws {
        self.fileURL = fileURL
        if FileManager.default.fileExists(atPath: fileURL.path) {
            snapshot = try JSONDecoder().decode(FileSnapshot.self, from: Data(contentsOf: fileURL))
            guard snapshot.schemaVersion == 1 else { throw StoreError.unsupportedVersion }
            guard Set(snapshot.sessions.map { "\($0.ownerID)|\($0.id)" }).count == snapshot.sessions.count,
                  snapshot.sessions.allSatisfy({ saved in
                      !saved.ownerID.isEmpty && TimeZone(identifier: saved.timeZoneID) != nil &&
                      Set((saved.queue ?? []).map(\.sentenceID)).count == (saved.queue ?? []).count &&
                      Set(saved.receipts.map(\.sentenceID)).count == saved.receipts.count &&
                      Set(saved.receipts.map { $0.event.id }).count == saved.receipts.count
                  }) else { throw StoreError.invalidSession }
        } else {
            snapshot = FileSnapshot()
        }
    }

    func prepare(ownerID: String, language: LearningLanguage, mode: String, directSentenceID: UUID? = nil,
                 revision: UUID, now: Date = .now, maximumAge: TimeInterval = 89 * 86_400) throws -> StudySessionState {
        guard !ownerID.isEmpty else { throw StoreError.invalidSession }
        if let saved = snapshot.sessions.last(where: { saved in
            saved.ownerID == ownerID && saved.language == language && saved.mode == mode &&
            saved.directSentenceID == directSentenceID && now.timeIntervalSince(saved.createdAt) < maximumAge &&
            Self.isCurrentReviewDay(saved, now: now) &&
            (saved.queue == nil || saved.queue!.contains { !saved.completedIDs.contains($0.sentenceID) })
        }) {
            return try saved.state(revision: revision)
        }
        let state = StudySessionState(language: language, accountRevision: revision,
            mode: mode, directSentenceID: directSentenceID)
        state.ownerID = ownerID
        var next = snapshot
        next.sessions.append(SavedSession(ownerID: ownerID, id: state.id, language: language,
            timeZoneID: state.timeZoneID, seed: state.seed, mode: mode,
            directSentenceID: directSentenceID, createdAt: now))
        try save(next)
        return state
    }

    func confirmedQueue(for state: StudySessionState) -> [SentenceStudyQueueItem]? {
        guard let saved = saved(state), let queue = saved.queue else { return nil }
        return queue.filter { !saved.completedIDs.contains($0.sentenceID) }.map(\.item)
    }

    func confirm(_ state: StudySessionState, queue: [SentenceStudyQueueItem]) throws {
        guard let index = index(state), Set(queue.map(\.id)).count == queue.count,
              queue.allSatisfy({ $0.context.targetLanguage == state.language }) else { throw StoreError.invalidSession }
        for item in queue {
            try item.context.validate()
            guard SentenceStudyQuestion(item: item, seed: state.seed).isValid else { throw StoreError.invalidSession }
        }
        let original = Dictionary(uniqueKeysWithValues: (snapshot.sessions[index].queue ?? []).map { ($0.sentenceID, $0) })
        let frozen = try queue.map { item -> MultilingualStudyQueueRecord in
            guard let saved = original[item.id] else { return MultilingualStudyQueueRecord(item: item) }
            guard saved.memoryID == item.memoryID, saved.item.context == item.context,
                  saved.targetText.utf8.elementsEqual(item.targetText.utf8) else { throw StoreError.invalidSession }
            return saved
        }
        var next = snapshot
        next.sessions[index].queue = frozen
        try save(next)
        state.queue = frozen.map(\.item)
        state.sentenceIDs = Set(queue.map(\.id))
    }

    func enqueue(_ state: StudySessionState, sentenceID: UUID) throws -> SentenceStudyProgress {
        guard let index = index(state), let record = snapshot.sessions[index].queue?.first(where: {
            $0.sentenceID == sentenceID
        }) else { throw StoreError.missingSentence }
        if let receipt = snapshot.sessions[index].receipts.first(where: { $0.sentenceID == sentenceID }) {
            return receipt.progress
        }
        let event = state.event(for: sentenceID)
        let calendar = StudyCalendar.calendar(timeZone: TimeZone(identifier: state.timeZoneID)!)
        let prior = snapshot.sessions.filter { $0.ownerID == state.ownerID }.flatMap(\.receipts)
            .filter { $0.sentenceID == sentenceID && $0.delivery != .blocked }
            .max { $0.event.occurredAt < $1.event.occurredAt }
        let sameDay = prior.map { calendar.isDate($0.event.occurredAt, inSameDayAs: event.occurredAt) } ?? false
        let previousStep = max(prior?.progress.learningStep ?? 0, record.learningStep)
        let step = min(5, previousStep + (sameDay ? 0 : 1))
        let reviews = max(prior?.progress.masteredReviewCount ?? 0, record.masteredReviewCount) +
            (!sameDay && previousStep >= 5 ? 1 : 0)
        let days = reviews > 0 ? (reviews == 1 ? 30 : 60) : [1, 2, 4, 7, 14][max(0, step - 1)]
        let progress = SentenceStudyProgress(id: event.id, sentenceID: sentenceID,
            learningStep: step, masteredReviewCount: reviews,
            correctCount: max(record.correctCount, prior?.progress.correctCount ?? 0) + (sameDay ? 0 : 1),
            wrongCount: max(record.wrongCount, prior?.progress.wrongCount ?? 0), lastResult: .correct,
            lastStudiedAt: event.occurredAt,
            nextReviewAt: sameDay ? max(record.nextReviewAt ?? .distantPast, prior!.progress.nextReviewAt) :
                (calendar.date(byAdding: .day, value: days,
                    to: calendar.startOfDay(for: event.occurredAt)) ?? event.occurredAt))
        var next = snapshot
        next.sessions[index].receipts.append(Receipt(sentenceID: sentenceID, event: event, progress: progress))
        next.sessions[index].completedIDs.insert(sentenceID)
        next.sessions[index].drafts.removeValue(forKey: sentenceID)
        try save(next)
        return progress
    }

    func draft(_ state: StudySessionState, sentenceID: UUID) -> [UUID: UUID] {
        saved(state)?.drafts[sentenceID] ?? [:]
    }

    func saveDraft(_ state: StudySessionState, sentenceID: UUID, answers: [UUID: UUID]) throws {
        guard let index = index(state), state.sentenceIDs.contains(sentenceID) else { throw StoreError.missingSentence }
        var next = snapshot
        next.sessions[index].drafts[sentenceID] = answers
        try save(next)
    }

    func finishReviewQuestion(_ state: StudySessionState, sentenceID: UUID) throws {
        guard let index = index(state), state.mode == "today" else { return }
        var next = snapshot
        next.sessions[index].completedIDs.insert(sentenceID)
        next.sessions[index].drafts.removeValue(forKey: sentenceID)
        try save(next)
    }

    func receipts(ownerID: String) -> [Receipt] {
        snapshot.sessions.filter { $0.ownerID == ownerID }.flatMap(\.receipts)
    }

    func completeGuestQuestion(_ state: StudySessionState, progress: SentenceStudyProgress) throws {
        guard let index = index(state), snapshot.sessions[index].queue?.contains(where: {
            $0.sentenceID == progress.sentenceID
        }) == true else { throw StoreError.missingSentence }
        var next = snapshot
        if !next.sessions[index].receipts.contains(where: { $0.sentenceID == progress.sentenceID }) {
            next.sessions[index].receipts.append(Receipt(sentenceID: progress.sentenceID,
                event: state.event(for: progress.sentenceID), progress: progress, delivery: .acknowledged))
        }
        next.sessions[index].completedIDs.insert(progress.sentenceID)
        next.sessions[index].drafts.removeValue(forKey: progress.sentenceID)
        try save(next)
    }

    func knownCounts(ownerID: String, language: LearningLanguage) -> [UUID: Int] {
        var counts: [UUID: Int] = [:]
        for saved in snapshot.sessions where saved.ownerID == ownerID && saved.language == language {
            for item in saved.queue ?? [] {
                counts[item.sentenceID] = max(counts[item.sentenceID] ?? 0, item.correctCount)
            }
            for receipt in saved.receipts where receipt.delivery != .blocked {
                counts[receipt.sentenceID] = max(counts[receipt.sentenceID] ?? 0, receipt.progress.correctCount)
            }
        }
        return counts
    }

    func cachedQueue(ownerID: String, language: LearningLanguage, mode: String,
                     now: Date = .now) -> [SentenceStudyQueueItem] {
        var seen = Set<UUID>()
        return snapshot.sessions.filter { $0.ownerID == ownerID && $0.language == language &&
            $0.mode == mode && $0.directSentenceID == nil &&
            now.timeIntervalSince($0.createdAt) < 89 * 86_400 && Self.isCurrentReviewDay($0, now: now) }.flatMap { saved in
                (saved.queue ?? []).filter { !saved.completedIDs.contains($0.sentenceID) }.map(\.item)
            }.filter { seen.insert($0.id).inserted }
    }

    func offlineReview(ownerID: String, language: LearningLanguage, revision: UUID,
                       now: Date = .now) throws -> StudySessionState? {
        let calendar = StudyCalendar.calendar()
        let sessions = snapshot.sessions.filter { $0.ownerID == ownerID && $0.language == language }
        let ids = Set(sessions.flatMap(\.receipts).filter {
            $0.delivery != .blocked && calendar.isDate($0.event.occurredAt, inSameDayAs: now)
        }.map(\.sentenceID))
        guard let source = sessions.last(where: { ($0.queue ?? []).contains { ids.contains($0.sentenceID) } }) else { return nil }
        let state = try source.state(revision: revision)
        var seen = Set<UUID>()
        state.queue = sessions.flatMap { $0.queue ?? [] }
            .filter { ids.contains($0.sentenceID) && seen.insert($0.sentenceID).inserted }.map(\.item)
        state.sentenceIDs = Set(state.queue.map(\.id))
        return state
    }

    func replay(ownerID: String, revision: UUID, isCurrent: () -> Bool,
                send: (StudySessionState, UUID) async throws -> SentenceStudyProgress) async throws {
        guard replayingOwners.insert(ownerID).inserted else { return }
        defer { replayingOwners.remove(ownerID) }
        let pending = snapshot.sessions.filter { $0.ownerID == ownerID }.flatMap { saved in
            saved.receipts.filter { $0.delivery == .pending }.map { (saved, $0) }
        }.sorted { $0.1.event.occurredAt < $1.1.event.occurredAt }
        for (saved, receipt) in pending {
            guard isCurrent(), !Task.isCancelled else { throw CancellationError() }
            let state = try saved.state(revision: revision)
            do {
                let progress = try await send(state, receipt.sentenceID)
                guard isCurrent(), !Task.isCancelled else { throw CancellationError() }
                guard progress.sentenceID == receipt.sentenceID else { throw StoreError.invalidSession }
                try updateReceipt(ownerID: ownerID, sessionID: saved.id, eventID: receipt.event.id,
                    delivery: .acknowledged, progress: progress)
            } catch {
                guard isCurrent(), !Task.isCancelled else { throw CancellationError() }
                if Self.isPermanent(error) {
                    try updateReceipt(ownerID: ownerID, sessionID: saved.id, eventID: receipt.event.id,
                        delivery: .blocked, progress: nil)
                    continue
                }
                throw error
            }
        }
    }

    func removeMemories(ownerID: String, memoryIDs: Set<UUID>) throws {
        guard !memoryIDs.isEmpty else { return }
        var next = snapshot
        for index in next.sessions.indices where next.sessions[index].ownerID == ownerID {
            let ids = Set((next.sessions[index].queue ?? []).filter { memoryIDs.contains($0.memoryID) }.map(\.sentenceID))
            next.sessions[index].queue?.removeAll { memoryIDs.contains($0.memoryID) }
            next.sessions[index].receipts.removeAll { ids.contains($0.sentenceID) }
            next.sessions[index].drafts = next.sessions[index].drafts.filter { !ids.contains($0.key) }
        }
        try save(next)
    }

    func removeOwner(_ ownerID: String) throws {
        var next = snapshot
        next.sessions.removeAll { $0.ownerID == ownerID }
        try save(next)
    }

    private func saved(_ state: StudySessionState) -> SavedSession? { index(state).map { snapshot.sessions[$0] } }
    private static func isCurrentReviewDay(_ saved: SavedSession, now: Date) -> Bool {
        guard saved.mode == "today", let zone = TimeZone(identifier: saved.timeZoneID) else { return true }
        return StudyCalendar.calendar(timeZone: zone).isDate(saved.createdAt, inSameDayAs: now)
    }
    private func index(_ state: StudySessionState) -> Int? {
        snapshot.sessions.firstIndex { $0.id == state.id && $0.ownerID == state.ownerID }
    }
    private func updateReceipt(ownerID: String, sessionID: UUID, eventID: UUID,
                               delivery: Delivery, progress: SentenceStudyProgress?) throws {
        guard let index = snapshot.sessions.firstIndex(where: { $0.ownerID == ownerID && $0.id == sessionID }),
              let eventIndex = snapshot.sessions[index].receipts.firstIndex(where: { $0.event.id == eventID }) else { return }
        var next = snapshot
        next.sessions[index].receipts[eventIndex].delivery = delivery
        if let progress { next.sessions[index].receipts[eventIndex].progress = progress }
        try save(next)
    }
    private static func isPermanent(_ error: Error) -> Bool {
        guard case SupabaseServiceError.apiError(let message) = error else { return false }
        return ["study_session_sentence_unavailable", "study_sentence_unavailable", "study_event_conflict",
                "invalid_study_event_time", "invalid_study_event"].contains { message.contains($0) }
    }
    private func save(_ next: FileSnapshot) throws {
        let data = try JSONEncoder().encode(next)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
        snapshot = next
    }
}
