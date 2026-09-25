import Combine
import Foundation

struct AlbumFlipItem: Identifiable, Equatable {
    let memoryID: UUID
    let sentence: SentenceRecord

    var id: String { "\(memoryID.uuidString):\(sentence.id.uuidString)" }

    static func makeItems(from memories: [MemoryEntry]) -> [AlbumFlipItem] {
        var seen = Set<String>()
        return memories.flatMap { memory in
            memory.sentences.compactMap { sentence in
                let item = AlbumFlipItem(memoryID: memory.id, sentence: sentence)
                guard !sentence.english.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      seen.insert(item.id).inserted else { return nil }
                return item
            }
        }
    }
}

nonisolated enum AlbumFlipFeedback: String, Codable {
    case again
    case familiar
}

struct AlbumFlipCard: Identifiable {
    // Each appearance needs its own identity, including a one-sentence album.
    let id = UUID()
    let item: AlbumFlipItem
}

@MainActor
final class AlbumFlipDeck: ObservableObject {
    static let lookaheadCount = 5
    @Published private(set) var cards: [AlbumFlipCard] = []
    @Published private(set) var viewedCount = 0
    private(set) var progress: [String: AlbumFlipProgress]
    var feedback: [String: AlbumFlipFeedback] { progress.mapValues(\.lastFeedback) }
    var onFeedback: (() -> Void)?
    private let items: [AlbumFlipItem]
    private let store: AlbumFlipHistoryStore
    private let randomIndex: (Int) -> Int
    private let now: () -> Date
    private var recentItemIDs: [String] = []
    private var recentMemoryIDs: [UUID] = []
    private var retryAfter: [String: Int] = [:]
    private var drawCount = 0
    private let recentMemoryLimit: Int

    var visibleCards: [AlbumFlipCard] { Array(cards.prefix(2)) }
    var upcomingSpeechTexts: [String] {
        cards.dropFirst().prefix(Self.lookaheadCount).map { $0.item.sentence.english }
    }

    init(
        items: [AlbumFlipItem],
        store: AlbumFlipHistoryStore,
        now: @escaping () -> Date = Date.init,
        randomIndex: @escaping (Int) -> Int = { Int.random(in: 0..<$0) }
    ) {
        self.items = items
        self.store = store
        self.randomIndex = randomIndex
        self.now = now
        let validIDs = Set(items.map(\.id))
        progress = store.read().records.filter { validIDs.contains($0.key) }
        recentMemoryLimit = min(2, max(0, Set(items.map(\.memoryID)).count - 1))
        for _ in 0...Self.lookaheadCount { appendCard() }
    }

    func advance(_ result: AlbumFlipFeedback, cardID: UUID) {
        guard let current = cards.first, current.id == cardID else { return }
        let previous = store.read().records[current.item.id]?.lastFeedbackAt ?? .distantPast
        let date = max(now(), previous.addingTimeInterval(0.001))
        let event = AlbumFlipEvent(id: UUID(), memoryID: current.item.memoryID, sentenceID: current.item.sentence.id,
                                  feedback: result, occurredAt: date, timeZoneID: TimeZone.current.identifier)
        store.record(event)
        reloadHistory()
        onFeedback?()
        if result == .again {
            // Due positions refer to actual viewing, not the size of the lookahead buffer.
            retryAfter[current.item.id] = viewedCount + 4
        } else {
            retryAfter[current.item.id] = nil
        }
        viewedCount += 1
        cards.removeFirst()
        appendCard()
    }

    func reloadHistory() {
        let validIDs = Set(items.map(\.id))
        progress = store.read().records.filter { validIDs.contains($0.key) }
        // Keep the current card and the five prefetched cards stable.
    }

    private func appendCard() {
        guard !items.isEmpty else { return }
        let queued = Set(cards.map { $0.item.id })
        var candidates = items.filter { !queued.contains($0.id) }
        if candidates.isEmpty { candidates = items }

        let otherPhotos = candidates.filter { !recentMemoryIDs.contains($0.memoryID) }
        if !otherPhotos.isEmpty { candidates = otherPhotos }

        // Revisit the exact sentence, not another sentence from the same photo.
        let due = candidates.filter { retryAfter[$0.id].map { $0 <= drawCount } ?? false }
        let selected: AlbumFlipItem
        if let retry = due.min(by: { retryAfter[$0.id, default: 0] < retryAfter[$1.id, default: 0] }) {
            selected = retry
        } else {
            let notCoolingDown = candidates.filter { retryAfter[$0.id] == nil }
            if !notCoolingDown.isEmpty { candidates = notCoolingDown }
            let notRecent = candidates.filter { !recentItemIDs.contains($0.id) }
            if !notRecent.isEmpty { candidates = notRecent }
            let weighted = candidates.flatMap { item in
                Array(repeating: item, count: progress[item.id]?.selectionWeight(at: now(), timeZone: .current) ?? 12)
            }
            selected = weighted[randomIndex(weighted.count)]
        }

        if retryAfter[selected.id].map({ $0 <= drawCount }) == true {
            retryAfter[selected.id] = nil
        }
        recentItemIDs.append(selected.id)
        recentItemIDs = Array(recentItemIDs.suffix(min(6, max(0, items.count - 1))))
        recentMemoryIDs.append(selected.memoryID)
        recentMemoryIDs = Array(recentMemoryIDs.suffix(recentMemoryLimit))
        drawCount += 1
        cards.append(AlbumFlipCard(item: selected))
    }
}

enum AlbumFlipSwipe {
    static func feedback(x: CGFloat, y: CGFloat, predictedX: CGFloat, width: CGFloat) -> AlbumFlipFeedback? {
        guard width > 0, abs(x) > abs(y) * 1.15 else { return nil }
        let crossedDistance = abs(x) >= width * 0.25
        let flicked = abs(x) >= 24 && abs(predictedX) >= width * 0.5 && x * predictedX > 0
        guard crossedDistance || flicked else { return nil }
        return x < 0 ? .again : .familiar
    }
}
