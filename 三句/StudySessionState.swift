import Foundation

@MainActor
final class StudySessionState {
    struct Event: Codable {
        let id: UUID
        let occurredAt: Date
    }

    let id: UUID
    let language: LearningLanguage
    let accountRevision: UUID
    let timeZoneID: String
    let seed: UInt64
    let mode: String
    let directSentenceID: UUID?
    var sentenceIDs: Set<UUID> = []
    var ownerID: String?
    var queue: [SentenceStudyQueueItem] = []
    var events: [UUID: Event] = [:]

    init(language: LearningLanguage, accountRevision: UUID, mode: String = "due",
         directSentenceID: UUID? = nil, id: UUID = UUID(), timeZone: TimeZone = .current,
         seed: UInt64 = UInt64.random(in: 0...UInt64.max)) {
        self.id = id
        self.language = language
        self.accountRevision = accountRevision
        self.timeZoneID = timeZone.identifier
        self.seed = seed
        self.mode = mode
        self.directSentenceID = directSentenceID
    }

    // A lost response must retry the exact same event, including its original timestamp.
    func event(for sentenceID: UUID) -> Event {
        if let event = events[sentenceID] { return event }
        let event = Event(id: UUID(), occurredAt: Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970)))
        events[sentenceID] = event
        return event
    }
}
