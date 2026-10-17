import Combine
import Foundation

struct AlbumFlipItem: Identifiable, Equatable {
    let memoryID: UUID
    let memoryCreatedAt: Date
    let sentence: SentenceRecord
    var context: MemoryContentContext = .legacyEnglish
    var reply: SentenceRecord? = nil
    var continuation: SentenceRecord? = nil

    var sentences: [SentenceRecord] { [sentence] + (reply.map { [$0] } ?? []) + (continuation.map { [$0] } ?? []) }
    var scenarioTitle: String? { sentence.dialogue?.title }

    var id: String { "\(memoryID.uuidString):\(sentence.id.uuidString)" }

    static func makeItems(from memories: [MemoryEntry]) -> [AlbumFlipItem] {
        var seen = Set<String>()
        return memories.flatMap { memory in
            memory.sentences.dialogueGroups.compactMap { group in
                let item = AlbumFlipItem(memoryID: memory.id, memoryCreatedAt: memory.createdAt,
                                         sentence: group.sentences[0], context: memory.context,
                                         reply: group.sentences.count >= 2 ? group.sentences[1] : nil,
                                         continuation: group.sentences.count == 3 ? group.sentences[2] : nil)
                guard item.sentences.allSatisfy({ !$0.targetText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
                      seen.insert(item.id).inserted else { return nil }
                return item
            }
        }
    }

    func selectionWeight(at now: Date) -> Int {
        let baseWeight = 12
        let age = max(0, now.timeIntervalSince(memoryCreatedAt))
        // The freshness bonus halves every 30 days; old memories keep their base chance.
        let freshnessMultiplier = 1 + 3 * pow(0.5, age / (30 * 86_400))
        return max(1, Int((Double(baseWeight) * freshnessMultiplier).rounded()))
    }
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

enum AlbumFlipDirection {
    case next
    case previous
}

@MainActor
final class AlbumFlipDeck: ObservableObject {
    // Avoid the implicit MainActor deinit back-deployment bug on iOS 26.2 and older.
    nonisolated deinit {}

    static let lookaheadCount = 5
    @Published private(set) var pages: [AlbumFlipPage] = []
    @Published private(set) var position = 0
    private let items: [AlbumFlipItem]
    private let mode: AlbumFlipMode
    private var remainingRoundItems: [AlbumFlipItem]
    private let randomIndex: (Int) -> Int
    private let now: () -> Date
    private var recentItemIDs: [String] = []
    private var recentMemoryIDs: [UUID] = []
    private let recentMemoryLimit: Int

    var currentPageID: UUID? { currentPage?.id }
    var currentItem: AlbumFlipItem? { currentPage?.item }
    var currentPage: AlbumFlipPage? { pages.indices.contains(position) ? pages[position] : nil }
    var canGoBack: Bool { position > 0 }
    var isShowingRoundBreak: Bool {
        guard case .roundBreak = currentPage else { return false }
        return true
    }
    var viewedCount: Int { pages.prefix(position).compactMap(\.item).count }
    var cards: [AlbumFlipCard] {
        pages.dropFirst(position + (isShowingRoundBreak ? 1 : 0))
            .prefix(Self.lookaheadCount + 1).prefix(while: { $0.item != nil })
            .compactMap { if case .sentence(let card) = $0 { card } else { nil } }
    }
    var visibleCards: [AlbumFlipCard] { Array(cards.prefix(2)) }
    var visiblePages: [AlbumFlipPage] { displayPages(toward: .next) }

    // Keep both neighbors mounted so reversing a drag never swaps the preview.
    var browsingPages: [AlbumFlipPage] {
        guard !pages.isEmpty else { return [] }
        return Array(pages[max(0, position - 1)...min(pages.count - 1, position + 1)])
    }

    func relativePosition(of pageID: UUID) -> Int {
        (pages.firstIndex(where: { $0.id == pageID }) ?? position) - position
    }

    func displayPages(toward direction: AlbumFlipDirection) -> [AlbumFlipPage] {
        guard let currentPage else { return [] }
        let neighbor = position + (direction == .next ? 1 : -1)
        return [currentPage] + (pages.indices.contains(neighbor) ? [pages[neighbor]] : [])
    }

    var upcomingSpeechTexts: [String] { upcomingSpeechItems.flatMap { $0.sentences.map(\.targetText) } }
    var upcomingSpeechItems: [AlbumFlipItem] {
        cards.dropFirst(isShowingRoundBreak ? 0 : 1).prefix(Self.lookaheadCount).map(\.item)
    }

    init(
        items: [AlbumFlipItem],
        mode: AlbumFlipMode = .continuous,
        now: @escaping () -> Date = Date.init,
        randomIndex: @escaping (Int) -> Int = { Int.random(in: 0..<$0) }
    ) {
        var seen = Set<String>()
        let sessionItems = items.filter { seen.insert($0.id).inserted }
        self.items = sessionItems
        self.mode = mode
        remainingRoundItems = sessionItems
        self.randomIndex = randomIndex
        self.now = now
        recentMemoryLimit = min(2, max(0, Set(sessionItems.map(\.memoryID)).count - 1))
        fillLookahead()
    }

    @discardableResult
    func navigate(_ direction: AlbumFlipDirection, cardID: UUID) -> Bool {
        guard currentPageID == cardID else { return false }
        switch direction {
        case .previous:
            guard canGoBack else { return false }
            position -= 1
        case .next:
            guard position + 1 < pages.count else { return false }
            position += 1
            fillLookahead()
        }
        return true
    }

    private func fillLookahead() {
        guard !items.isEmpty else { return }
        // Append only at the frontier. Going back never rerolls cards or their IDs.
        while pages.count - position < Self.lookaheadCount + 2 {
            appendPage()
        }
    }

    private func appendPage() {
        if mode == .photoRounds {
            if remainingRoundItems.isEmpty {
                pages.append(.roundBreak(UUID()))
                remainingRoundItems = items
                return
            }
            let lines = items.flatMap(\.sentences)
            let hasOrderedDialogues = Set(items.map(\.memoryID)).count == 1 &&
                (lines.isCompleteDialogueTrio || lines.isCompleteScenarioDialogues)
            if hasOrderedDialogues {
                let index = remainingRoundItems.indices.min {
                    remainingRoundItems[$0].sentence.dialogue!.index < remainingRoundItems[$1].sentence.dialogue!.index
                }!
                pages.append(.sentence(AlbumFlipCard(item: remainingRoundItems.remove(at: index))))
                return
            }
            let sceneIndices = remainingRoundItems.indices.filter {
                remainingRoundItems[$0].sentence.presentationGroup == .whatIDSay
            }
            let candidates = sceneIndices.isEmpty ? Array(remainingRoundItems.indices) : sceneIndices
            let index = candidates[randomIndex(candidates.count)]
            pages.append(.sentence(AlbumFlipCard(item: remainingRoundItems.remove(at: index))))
            return
        }

        // Photo separation takes priority over sentence cooldown in unbalanced albums.
        var candidates = items
        let otherPhotos = candidates.filter { !recentMemoryIDs.contains($0.memoryID) }
        if !otherPhotos.isEmpty {
            candidates = otherPhotos
        } else if let last = recentMemoryIDs.last {
            let notLastPhoto = candidates.filter { $0.memoryID != last }
            if !notLastPhoto.isEmpty { candidates = notLastPhoto }
        }
        let notRecent = candidates.filter { !recentItemIDs.contains($0.id) }
        if !notRecent.isEmpty { candidates = notRecent }
        let date = now()
        let weights = candidates.map { $0.selectionWeight(at: date) }
        var ticket = randomIndex(weights.reduce(0, +))
        var index = 0
        while index < weights.count - 1, ticket >= weights[index] {
            ticket -= weights[index]
            index += 1
        }
        let selected = candidates[index]
        recentItemIDs.append(selected.id)
        recentItemIDs = Array(recentItemIDs.suffix(min(6, max(0, items.count - 1))))
        recentMemoryIDs.append(selected.memoryID)
        recentMemoryIDs = Array(recentMemoryIDs.suffix(recentMemoryLimit))
        pages.append(.sentence(AlbumFlipCard(item: selected)))
    }
}

enum AlbumFlipSwipe {
    static func direction(x: CGFloat, y: CGFloat, predictedX: CGFloat, width: CGFloat) -> AlbumFlipDirection? {
        guard width > 0, abs(x) > abs(y) * 1.15 else { return nil }
        let crossedDistance = abs(x) >= width * 0.25
        let flicked = abs(x) >= 24 && abs(predictedX) >= width * 0.5 && x * predictedX > 0
        guard crossedDistance || flicked else { return nil }
        return x < 0 ? .next : .previous
    }
}
