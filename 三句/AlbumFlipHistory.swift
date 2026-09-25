import Foundation

nonisolated struct AlbumFlipEvent: Codable, Equatable, Identifiable {
    let id: UUID
    let memoryID: UUID
    let sentenceID: UUID
    let feedback: AlbumFlipFeedback
    let occurredAt: Date
    let timeZoneID: String

    var itemID: String { "\(memoryID.uuidString):\(sentenceID.uuidString)" }

    static func precedes(_ lhs: Self, _ rhs: Self) -> Bool {
        if lhs.occurredAt != rhs.occurredAt { return lhs.occurredAt < rhs.occurredAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

nonisolated struct AlbumFlipProgress: Codable, Equatable {
    let memoryID: UUID
    let sentenceID: UUID
    var lastEventID: UUID
    var lastFeedback: AlbumFlipFeedback
    var lastFeedbackAt: Date
    var familiarityLevel: Int
    var lastFamiliarAt: Date?

    var itemID: String { "\(memoryID.uuidString):\(sentenceID.uuidString)" }

    enum CodingKeys: String, CodingKey {
        case memoryID = "memory_id", sentenceID = "sentence_id", lastEventID = "last_event_id"
        case lastFeedback = "last_feedback", lastFeedbackAt = "last_feedback_at"
        case familiarityLevel = "familiarity_level", lastFamiliarAt = "last_familiar_at"
    }

    static func applying(_ event: AlbumFlipEvent, to previous: Self?) -> Self {
        if let previous,
           previous.lastFeedbackAt > event.occurredAt ||
            (previous.lastFeedbackAt == event.occurredAt && previous.lastEventID.uuidString >= event.id.uuidString) {
            return previous
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: event.timeZoneID) ?? .gmt
        var level = previous?.familiarityLevel ?? 0
        var lastFamiliarAt = previous?.lastFamiliarAt
        if event.feedback == .again {
            level = 0
        } else {
            let newDay = lastFamiliarAt.map { !calendar.isDate($0, inSameDayAs: event.occurredAt) } ?? true
            // Repeated swipes on one local day cannot repeatedly advance familiarity.
            level = level == 0 ? 1 : min(4, level + (newDay ? 1 : 0))
            lastFamiliarAt = event.occurredAt
        }
        return Self(memoryID: event.memoryID, sentenceID: event.sentenceID, lastEventID: event.id,
                    lastFeedback: event.feedback, lastFeedbackAt: event.occurredAt,
                    familiarityLevel: level, lastFamiliarAt: lastFamiliarAt)
    }

    func selectionWeight(at now: Date, timeZone: TimeZone) -> Int {
        guard lastFeedback == .familiar else { return 24 }
        let level = min(4, max(1, familiarityLevel))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: lastFeedbackAt),
                                           to: calendar.startOfDay(for: now)).day ?? 0
        let revisitDays = [1, 3, 7, 14][level - 1]
        return days >= revisitDays ? 6 : [4, 2, 1, 1][level - 1]
    }
}

struct AlbumFlipHistory: Codable {
    var records: [String: AlbumFlipProgress] = [:]
    // Temporary delivery outbox, removed after acknowledgement; not a permanent swipe log.
    var pending: [AlbumFlipEvent] = []
}

struct AlbumFlipHistoryStore {
    let defaults: UserDefaults
    let ownerID: String
    var namespace: String = Bundle.main.supabaseURL ?? "local"

    private var key: String { "sanju.albumFlip.history.\(namespace).\(ownerID)" }
    private var legacyKey: String { "sanju.albumFlip.feedback.\(ownerID)" }

    func read() -> AlbumFlipHistory {
        if let data = defaults.data(forKey: key) {
            return PersistenceDiagnostics.decode(AlbumFlipHistory.self, from: data, using: JSONDecoder(),
                                                 operation: "Decode album flip history") ?? AlbumFlipHistory()
        }
        var history = AlbumFlipHistory()
        // Previous local builds retained only the latest direction. Import it once.
        if let data = defaults.data(forKey: legacyKey),
           let legacy = try? JSONDecoder().decode([String: AlbumFlipFeedback].self, from: data) {
            for (itemID, feedback) in legacy {
                let ids = itemID.split(separator: ":")
                guard ids.count == 2, let memory = UUID(uuidString: String(ids[0])),
                      let sentence = UUID(uuidString: String(ids[1])) else { continue }
                let event = AlbumFlipEvent(id: UUID(), memoryID: memory, sentenceID: sentence,
                                          feedback: feedback, occurredAt: Date(), timeZoneID: TimeZone.current.identifier)
                history.records[event.itemID] = .applying(event, to: nil)
                history.pending.append(event)
            }
            write(history)
            defaults.removeObject(forKey: legacyKey)
        }
        return history
    }

    func write(_ history: AlbumFlipHistory) {
        guard let data = PersistenceDiagnostics.encode(history, using: JSONEncoder(),
                                                       operation: "Encode album flip history") else { return }
        defaults.set(data, forKey: key)
    }

    @discardableResult
    func record(_ event: AlbumFlipEvent) -> AlbumFlipHistory {
        var history = read()
        history.records[event.itemID] = .applying(event, to: history.records[event.itemID])
        if !history.pending.contains(where: { $0.id == event.id }) { history.pending.append(event) }
        write(history)
        return history
    }

    func merge(_ remote: [AlbumFlipProgress], acknowledging events: [AlbumFlipEvent] = []) {
        var history = read()
        let delivered = Set(events.map(\.id))
        history.pending.removeAll { delivered.contains($0.id) }
        for record in remote {
            // The server is the baseline; replay only undelivered local actions over it.
            var merged = record
            for event in history.pending.filter({ $0.itemID == record.itemID }).sorted(by: AlbumFlipEvent.precedes) {
                merged = .applying(event, to: merged)
            }
            history.records[record.itemID] = merged
        }
        write(history)
    }

    func clear() {
        defaults.removeObject(forKey: key)
        defaults.removeObject(forKey: legacyKey)
    }

    func transferGuestMemory(_ original: MemoryEntry, to migrated: MemoryEntry, destination: Self) {
        var guest = read()
        var target = destination.read()
        for sentence in original.sentences {
            guard let remote = migrated.sentences.first(where: { $0.id == sentence.id }) ??
                migrated.sentences.first(where: { $0.english == sentence.english && $0.chinese == sentence.chinese }) else { continue }
            let oldID = "\(original.id.uuidString):\(sentence.id.uuidString)"
            let events = guest.pending.filter { $0.itemID == oldID }.map {
                AlbumFlipEvent(id: $0.id, memoryID: migrated.id, sentenceID: remote.id,
                               feedback: $0.feedback, occurredAt: $0.occurredAt, timeZoneID: $0.timeZoneID)
            }
            for event in events.sorted(by: AlbumFlipEvent.precedes) {
                target.records[event.itemID] = .applying(event, to: target.records[event.itemID])
                if !target.pending.contains(where: { $0.id == event.id }) { target.pending.append(event) }
            }
            guest.pending.removeAll { $0.itemID == oldID }
            guest.records[oldID] = nil
        }
        // Persist destination first so interruption cannot lose an unsent guest action.
        destination.write(target)
        write(guest)
    }
}
