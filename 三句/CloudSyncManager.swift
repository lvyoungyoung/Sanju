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
}
