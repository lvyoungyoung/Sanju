import Combine
import Foundation

struct AlbumFlipItem: Identifiable, Equatable {
    let memoryID: UUID
    let memoryCreatedAt: Date
    let sentence: SentenceRecord

    var id: String { "\(memoryID.uuidString):\(sentence.id.uuidString)" }

    static func makeItems(from memories: [MemoryEntry]) -> [AlbumFlipItem] {
        var seen = Set<String>()
        return memories.flatMap { memory in
            memory.sentences.compactMap { sentence in
                let item = AlbumFlipItem(memoryID: memory.id, memoryCreatedAt: memory.createdAt, sentence: sentence)
                guard !sentence.english.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      seen.insert(item.id).inserted else { return nil }
                return item
            }
        }
    }

    func selectionWeight(at now: Date, progress: AlbumFlipProgress?, timeZone: TimeZone = .current) -> Int {
        let familiarityWeight = progress?.selectionWeight(at: now, timeZone: timeZone) ?? 12
        let age = max(0, now.timeIntervalSince(memoryCreatedAt))
        // The freshness bonus halves every 30 days; old memories keep their base chance.
        let freshnessMultiplier = 1 + 3 * pow(0.5, age / (30 * 86_400))
        return max(1, Int((Double(familiarityWeight) * freshnessMultiplier).rounded()))
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

enum AlbumFlipPage: Identifiable {
    case sentence(AlbumFlipCard)
    case roundBreak(UUID)

    var id: UUID {
        switch self {
        case .sentence(let card): card.id
        case .roundBreak(let id): id
        }
    }

    var item: AlbumFlipItem? {
        guard case .sentence(let card) = self else { return nil }
        return card.item
    }
}

enum AlbumFlipMode {
    case continuous
    case photoRounds
}

@MainActor
final class AlbumFlipDeck: ObservableObject {
    // Avoid the implicit MainActor deinit back-deployment bug on iOS 26.2 and older.
    nonisolated deinit {}

    static let lookaheadCount = 5
    @Published private(set) var cards: [AlbumFlipCard] = []
    @Published private(set) var viewedCount = 0
    @Published private(set) var isShowingRoundBreak = false
    private(set) var progress: [String: AlbumFlipProgress]
    var feedback: [String: AlbumFlipFeedback] { progress.mapValues(\.lastFeedback) }
    var onFeedback: (() -> Void)?
    private let items: [AlbumFlipItem]
    private let mode: AlbumFlipMode
    private var remainingRoundItems: [AlbumFlipItem]
    private var roundBreakID = UUID()
    private let store: AlbumFlipHistoryStore
    private let randomIndex: (Int) -> Int
    private let now: () -> Date
    private var recentItemIDs: [String] = []
    private var recentMemoryIDs: [UUID] = []
    private var retryAfter: [String: Int] = [:]
    private var drawCount = 0
    private let recentMemoryLimit: Int

    var visibleCards: [AlbumFlipCard] { Array(cards.prefix(2)) }
    var currentPageID: UUID? { isShowingRoundBreak ? roundBreakID : cards.first?.id }
    var currentItem: AlbumFlipItem? { isShowingRoundBreak ? nil : cards.first?.item }
    var visiblePages: [AlbumFlipPage] {
        if isShowingRoundBreak {
            return [.roundBreak(roundBreakID)] + cards.prefix(1).map(AlbumFlipPage.sentence)
        }
        let pages = visibleCards.map(AlbumFlipPage.sentence)
        if mode == .photoRounds, cards.count == 1 {
            return pages + [.roundBreak(roundBreakID)]
        }
        return pages
    }
    var upcomingSpeechTexts: [String] {
        cards.dropFirst(isShowingRoundBreak ? 0 : 1).prefix(Self.lookaheadCount).map { $0.item.sentence.english }
    }

    init(
        items: [AlbumFlipItem],
        store: AlbumFlipHistoryStore,
        mode: AlbumFlipMode = .continuous,
        now: @escaping () -> Date = Date.init,
        randomIndex: @escaping (Int) -> Int = { Int.random(in: 0..<$0) }
    ) {
        var seen = Set<String>()
        let sessionItems = mode == .photoRounds ? items.filter { seen.insert($0.id).inserted } : items
        self.items = sessionItems
        self.mode = mode
        remainingRoundItems = mode == .photoRounds ? sessionItems : []
        self.store = store
        self.randomIndex = randomIndex
        self.now = now
        let validIDs = Set(sessionItems.map(\.id))
        progress = store.read().records.filter { validIDs.contains($0.key) }
        recentMemoryLimit = min(2, max(0, Set(sessionItems.map(\.memoryID)).count - 1))
        for _ in 0...Self.lookaheadCount { appendCard() }
    }

    func advance(_ result: AlbumFlipFeedback, cardID: UUID) {
        guard currentPageID == cardID else { return }
        if isShowingRoundBreak {
            // The interlude is navigation, not feedback about a sentence.
            isShowingRoundBreak = false
            roundBreakID = UUID()
            return
        }
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
        if mode == .photoRounds, cards.isEmpty {
            remainingRoundItems = items
            for _ in 0...Self.lookaheadCount { appendCard() }
            isShowingRoundBreak = true
        }
    }

    func reloadHistory() {
        let validIDs = Set(items.map(\.id))
        progress = store.read().records.filter { validIDs.contains($0.key) }
        // Keep the current card and the five prefetched cards stable.
    }

    private func appendCard() {
        if mode == .photoRounds {
            guard !remainingRoundItems.isEmpty else { return }
            // Finish the scene expressions before drawing the photo descriptions each round.
            let sceneIndices = remainingRoundItems.indices.filter {
                remainingRoundItems[$0].sentence.presentationGroup == .whatIDSay
            }
            let candidates = sceneIndices.isEmpty ? Array(remainingRoundItems.indices) : sceneIndices
            let index = candidates[randomIndex(candidates.count)]
            cards.append(AlbumFlipCard(item: remainingRoundItems.remove(at: index)))
            return
        }
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
            let date = now()
            let weights = candidates.map { item in
                item.selectionWeight(at: date, progress: progress[item.id])
            }
            var ticket = randomIndex(weights.reduce(0, +))
            var selectedIndex = 0
            while selectedIndex < weights.count - 1, ticket >= weights[selectedIndex] {
                ticket -= weights[selectedIndex]
                selectedIndex += 1
            }
            selected = candidates[selectedIndex]
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
