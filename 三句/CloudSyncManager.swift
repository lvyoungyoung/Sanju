//
//  CloudSyncManager.swift
//  三句
//
//  Created by Codex.
//

import Foundation

struct CloudSyncPlan: Equatable {
    let queuedGuestMemoriesCount: Int
    let queuedMemoryDeletionsCount: Int
    let queuedFavoriteChangesCount: Int
    let favoriteDifferenceCount: Int
    let localStudyProgressCount: Int

    var totalCount: Int {
        queuedGuestMemoriesCount
            + queuedMemoryDeletionsCount
            + queuedFavoriteChangesCount
            + favoriteDifferenceCount
            + localStudyProgressCount
    }

    func debugDescription(sessionID: String, localMemoryCount: Int, remoteMemoryCount: Int) -> String {
        """
        session=\(sessionID) local=\(localMemoryCount) remote=\(remoteMemoryCount) \
        queuedGuestMemories=\(queuedGuestMemoriesCount) deletions=\(queuedMemoryDeletionsCount) \
        queuedFavoriteChanges=\(queuedFavoriteChangesCount) favoriteDiffs=\(favoriteDifferenceCount) \
        localStudyProgress=\(localStudyProgressCount)
        """
    }
}

struct CloudSyncReconciliationResult {
    let memories: [MemoryEntry]
    let didChange: Bool

    var recordedMemoriesCount: Int {
        memories.count
    }

    var favoriteSentencesCount: Int {
        memories.reduce(into: 0) { partialResult, memory in
            partialResult += memory.sentences.filter(\.isFavorite).count
        }
    }
}

struct CloudSyncManager {
    func makeRemoteMemories(from records: [SupabaseMemoryRecord]) -> [MemoryEntry] {
        records.compactMap { record -> MemoryEntry? in
            guard let memoryID = UUID(uuidString: record.id) else { return nil }
            let sentences = record.sentences
                .sorted { $0.sortOrder < $1.sortOrder }
                .compactMap { sentence -> SentenceRecord? in
                    guard let sentenceID = UUID(uuidString: sentence.id) else { return nil }
                    return SentenceRecord(
                        id: sentenceID,
                        english: sentence.english,
                        chinese: sentence.chinese,
                        isFavorite: sentence.isFavorite
                    )
                }

            guard sentences.count == 3 else { return nil }

            return MemoryEntry(
                id: memoryID,
                createdAt: record.createdAt,
                imageData: Data(),
                remoteImagePath: record.imagePath,
                syncedToAccount: true,
                sentences: sentences
            )
        }
    }

    func makePlan(
        localMemories: [MemoryEntry],
        remoteMemories: [MemoryEntry],
        queuedGuestMemories: [MemoryEntry],
        queuedMemoryDeletions: [PendingMemoryDeletion],
        queuedFavoriteChanges: [PendingFavoriteChange],
        queuedLocalStudyProgress: [LocalSentenceStudyProgress]
    ) -> CloudSyncPlan {
        let queuedFavoriteSentenceIDs = Set(queuedFavoriteChanges.map(\.sentenceID))
        let remoteMemoryByID = Dictionary(uniqueKeysWithValues: remoteMemories.map { ($0.id, $0) })
        let favoriteDifferenceCount = localMemories.reduce(into: 0) { partialResult, localMemory in
            guard localMemory.syncedToAccount, let remoteMemory = remoteMemoryByID[localMemory.id] else { return }
            let remoteSentenceByID = Dictionary(uniqueKeysWithValues: remoteMemory.sentences.map { ($0.id, $0) })
            partialResult += localMemory.sentences.filter { localSentence in
                !queuedFavoriteSentenceIDs.contains(localSentence.id)
                    && remoteSentenceByID[localSentence.id]?.isFavorite != localSentence.isFavorite
            }.count
        }

        return CloudSyncPlan(
            queuedGuestMemoriesCount: queuedGuestMemories.count,
            queuedMemoryDeletionsCount: queuedMemoryDeletions.count,
            queuedFavoriteChangesCount: queuedFavoriteChanges.count,
            favoriteDifferenceCount: favoriteDifferenceCount,
            localStudyProgressCount: queuedLocalStudyProgress.count
        )
    }

    func reconcileLocalMemories(
        localMemories: [MemoryEntry],
        remoteMemories: [MemoryEntry],
        sessionUserID: String
    ) -> CloudSyncReconciliationResult {
        var reconciledMemories = localMemories
        var didChange = false

        for index in reconciledMemories.indices {
            guard isMemoryContentComplete(reconciledMemories[index]),
                  !reconciledMemories[index].syncedToAccount else {
                continue
            }
            guard remoteMemories.contains(where: { matchesMemoryIdentity($0, reconciledMemories[index]) }) else {
                continue
            }
            reconciledMemories[index].syncedToAccount = true
            didChange = true
        }

        let originalCount = reconciledMemories.count
        reconciledMemories.removeAll { localMemory in
            guard isMemoryContentComplete(localMemory) else { return false }
            guard remoteMemories.contains(where: { matchesMemoryIdentity($0, localMemory) }) else { return false }

            if !localMemory.syncedToAccount {
                return true
            }

            guard let remoteImagePath = localMemory.remoteImagePath else { return false }
            return !remoteImagePath.hasPrefix("\(sessionUserID)/")
        }
        didChange = didChange || reconciledMemories.count != originalCount

        return CloudSyncReconciliationResult(
            memories: reconciledMemories,
            didChange: didChange
        )
    }

    private func matchesMemoryIdentity(_ lhs: MemoryEntry, _ rhs: MemoryEntry) -> Bool {
        if lhs.id == rhs.id {
            return true
        }

        let lhsContent = lhs.sentences.map { normalizedSentenceIdentity(for: $0) }
        let rhsContent = rhs.sentences.map { normalizedSentenceIdentity(for: $0) }
        return lhsContent == rhsContent
    }

    private func normalizedSentenceIdentity(for sentence: SentenceRecord) -> String {
        "\(normalizeSentenceComponent(sentence.english))\u{001F}\(normalizeSentenceComponent(sentence.chinese))"
    }

    private func normalizeSentenceComponent(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func isMemoryContentComplete(_ memory: MemoryEntry) -> Bool {
        guard memory.sentences.count == 3 else { return false }

        return memory.sentences.allSatisfy {
            !$0.english.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !$0.chinese.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}
