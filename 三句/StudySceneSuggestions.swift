import Combine
import Foundation

struct StudySceneTopicRecord: Decodable {
    let learningTopicIDs: [String]?

    enum CodingKeys: String, CodingKey {
        case learningTopicIDs = "learning_topic_ids"
    }
}

enum StudySceneTopicReader {
    static func load(
        pageSize: Int = 100,
        fetchPage: (Range<Int>) async throws -> [StudySceneTopicRecord]
    ) async throws -> Set<String> {
        precondition(pageSize > 0)
        let knownIDs = Set(LearningTopic.all.map(\.id))
        var topicIDs = Set<String>()
        var offset = 0
        while true {
            try Task.checkCancellation()
            let page = try await fetchPage(offset..<(offset + pageSize))
            try Task.checkCancellation()
            topicIDs.formUnion(page.flatMap { $0.learningTopicIDs ?? [] })
            topicIDs.formIntersection(knownIDs)
            if page.count < pageSize || topicIDs == knownIDs { return topicIDs }
            offset += pageSize
        }
    }
}

@MainActor
final class StudySceneSuggestions: ObservableObject {
    @Published private(set) var displayedTopics: [LearningTopic] = []
    @Published private(set) var loadState: ContentLoadState = .idle

    private var accountRevision: UUID?
    private var requestID = UUID()
    private var localTopicIDs = Set<String>()
    private var remoteTopicIDs = Set<String>()

    // No actor-bound cleanup is needed when SwiftUI releases this cache synchronously.
    nonisolated deinit {}

    private var availableTopics: [LearningTopic] {
        let topicIDs = localTopicIDs.union(remoteTopicIDs)
        return LearningTopic.all.filter { topicIDs.contains($0.id) }
    }

    func prepare(accountRevision: UUID, localTopicIDs: Set<String>) {
        if self.accountRevision != accountRevision {
            cancelLoading()
            self.accountRevision = accountRevision
            remoteTopicIDs = []
            displayedTopics = []
            loadState = .idle
        }
        self.localTopicIDs = localTopicIDs
        updateDisplayedTopics()
    }

    func refresh(
        accountRevision: UUID,
        localTopicIDs: Set<String>,
        load: () async throws -> Set<String>
    ) async {
        guard !Task.isCancelled else { return }
        prepare(accountRevision: accountRevision, localTopicIDs: localTopicIDs)
        let id = UUID()
        requestID = id
        loadState = .loading
        do {
            let topicIDs = try await load()
            try Task.checkCancellation()
            guard requestID == id, self.accountRevision == accountRevision else { return }
            remoteTopicIDs = topicIDs
            updateDisplayedTopics()
            loadState = .loaded
        } catch {
            guard requestID == id, self.accountRevision == accountRevision else { return }
            let wasCancelled = Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled
            loadState = wasCancelled ? .idle : .failed
        }
    }

    func cancelLoading() {
        requestID = UUID()
        if loadState == .loading { loadState = .idle }
    }

    func shuffle() {
        let available = availableTopics
        var next = Array(available.shuffled().prefix(3))
        if available.count > 3, Set(next) == Set(displayedTopics),
           let replacement = available.first(where: { !displayedTopics.contains($0) }) {
            next = Array(displayedTopics.dropLast()) + [replacement]
        }
        displayedTopics = next
    }

    private func updateDisplayedTopics() {
        let available = availableTopics
        // Keep visible tags stable while the cloud request or local sync finishes.
        var next = displayedTopics.filter { available.contains($0) }
        let remaining = available.filter { !next.contains($0) }.shuffled()
        next.append(contentsOf: remaining.prefix(max(0, 3 - next.count)))
        displayedTopics = next
    }
}
