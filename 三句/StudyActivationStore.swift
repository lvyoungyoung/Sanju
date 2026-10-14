import Foundation

/// Guest-only durable ledger. Signed-in clients must obtain new activations from the server.
@MainActor
final class StudyActivationStore {
    static let dailyLimit = 30

    struct Activation: Codable, Equatable {
        let ownerID: String
        let sentenceID: UUID
        let firstActivatedAt: Date
        let isLegacy: Bool
    }

    struct Session: Codable, Equatable {
        let ownerID: String
        let id: UUID
        let language: String
        let scope: String
        let timeZoneID: String
        let requestedIDs: [UUID]
        let sentenceIDs: [UUID]
        let startedAt: Date
        let seed: UInt64
    }

    private struct Snapshot: Codable {
        var schemaVersion = 1
        var activations: [Activation] = []
        var sessions: [Session] = []
    }

    enum StoreError: Error { case unsupportedVersion, sessionConflict, invalidOwner, invalidImport }

    private let fileURL: URL
    private var snapshot: Snapshot
    private var onlineSessions: StudySessionStore?

    func sessionStore() throws -> StudySessionStore {
        if let onlineSessions { return onlineSessions }
        let store = try StudySessionStore(fileURL: fileURL.deletingLastPathComponent()
            .appendingPathComponent("online-study-sessions-v1.json"))
        onlineSessions = store
        return store
    }

    init(fileURL: URL) throws {
        self.fileURL = fileURL
        if FileManager.default.fileExists(atPath: fileURL.path) {
            snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: fileURL))
            guard snapshot.schemaVersion == 1 else { throw StoreError.unsupportedVersion }
        } else {
            snapshot = Snapshot()
        }
    }

    func remainingNew(ownerID: String, at date: Date = .now, timeZone: TimeZone = .current) -> Int {
        let day = StudyCalendar.calendar(timeZone: timeZone).dateInterval(of: .day, for: date)!
        let used = snapshot.activations.filter {
            $0.ownerID == ownerID && !$0.isLegacy && $0.firstActivatedAt >= day.start && $0.firstActivatedAt < day.end
        }.count
        return max(0, Self.dailyLimit - used)
    }

    func isActivated(ownerID: String, sentenceID: UUID) -> Bool {
        snapshot.activations.contains { $0.ownerID == ownerID && $0.sentenceID == sentenceID }
    }

    func activations(ownerID: String) -> [Activation] {
        snapshot.activations.filter { $0.ownerID == ownerID }
    }

    func session(ownerID: String, sessionID: UUID) -> Session? {
        snapshot.sessions.first { $0.ownerID == ownerID && $0.id == sessionID }
    }

    func beginSession(ownerID: String, sessionID: UUID, language: LearningLanguage,
                      scope: String = "favorites", candidateIDs: [UUID], seed: UInt64,
                      at date: Date = .now, timeZone: TimeZone = .current) throws -> Session {
        guard !ownerID.isEmpty else { throw StoreError.invalidOwner }
        if let session = snapshot.sessions.first(where: { $0.ownerID == ownerID && $0.id == sessionID }) {
            guard session.language == language.rawValue, session.scope == scope,
                  session.requestedIDs == candidateIDs, session.seed == seed,
                  session.timeZoneID == timeZone.identifier else { throw StoreError.sessionConflict }
            return session
        }
        var next = snapshot
        var remaining = remainingNew(ownerID: ownerID, at: date, timeZone: timeZone)
        var claimed: [UUID] = []
        var seen = Set<UUID>()
        for id in candidateIDs where seen.insert(id).inserted {
            if !isActivated(ownerID: ownerID, sentenceID: id) {
                guard remaining > 0 else { continue }
                remaining -= 1
                next.activations.append(Activation(ownerID: ownerID, sentenceID: id,
                                                   firstActivatedAt: date, isLegacy: false))
            }
            claimed.append(id)
        }
        let session = Session(ownerID: ownerID, id: sessionID, language: language.rawValue,
                              scope: scope, timeZoneID: timeZone.identifier, requestedIDs: candidateIDs,
                              sentenceIDs: claimed, startedAt: date, seed: seed)
        next.sessions.append(session)
        try save(next)
        return session
    }

    /// Import preserves real activations even if merged devices exceed today's allowance.
    func merge(ownerID: String, activations: [Activation], at now: Date = .now) throws {
        guard !ownerID.isEmpty else { throw StoreError.invalidOwner }
        var next = snapshot
        for item in activations {
            guard item.firstActivatedAt <= now else { throw StoreError.invalidImport }
            let imported = Activation(ownerID: ownerID, sentenceID: item.sentenceID,
                                      firstActivatedAt: item.firstActivatedAt, isLegacy: item.isLegacy)
            if let index = next.activations.firstIndex(where: { $0.ownerID == ownerID && $0.sentenceID == item.sentenceID }) {
                let current = next.activations[index]
                if item.isLegacy || (!current.isLegacy && item.firstActivatedAt < current.firstActivatedAt) {
                    next.activations[index] = imported
                }
            } else {
                next.activations.append(imported)
            }
        }
        try save(next)
    }

    func importLegacyProgress(ownerID: String, sentenceIDs: [UUID]) throws {
        try merge(ownerID: ownerID, activations: sentenceIDs.filter {
            !isActivated(ownerID: ownerID, sentenceID: $0)
        }.map {
            Activation(ownerID: ownerID, sentenceID: $0, firstActivatedAt: .distantPast, isLegacy: true)
        })
    }

    /// Call only for explicit account/guest data deletion, never when a memory is removed.
    func removeOwner(_ ownerID: String) throws {
        var next = snapshot
        next.activations.removeAll { $0.ownerID == ownerID }
        next.sessions.removeAll { $0.ownerID == ownerID }
        try save(next)
    }

    private func save(_ next: Snapshot) throws {
        let data = try JSONEncoder().encode(next)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
        snapshot = next
    }
}
