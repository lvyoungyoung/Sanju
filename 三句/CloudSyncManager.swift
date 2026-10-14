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
    let localStudyProgressCount: Int

    var totalCount: Int {
        queuedGuestMemoriesCount
            + queuedMemoryDeletionsCount
            + queuedFavoriteChangesCount
            + localStudyProgressCount
    }

    func debugDescription(sessionID: String, localMemoryCount: Int, remoteMemoryCount: Int) -> String {
        """
        session=\(sessionID) local=\(localMemoryCount) remote=\(remoteMemoryCount) \
        queuedGuestMemories=\(queuedGuestMemoriesCount) deletions=\(queuedMemoryDeletionsCount) \
        queuedFavoriteChanges=\(queuedFavoriteChangesCount) \
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
    func makeRemoteMemories(
        from records: [SupabaseMemoryRecord],
        cachedMemories: [MemoryEntry] = []
    ) throws -> [MemoryEntry] {
        let cachedByID = cachedMemories.memoryDictionaryByID()
        var memoryIDs = Set<UUID>()
        return try records.map { record in
            guard let memoryID = UUID(uuidString: record.id), memoryIDs.insert(memoryID).inserted else {
                throw SupabaseServiceError.invalidResponse
            }
            try record.context.validate()
            guard record.sentences.map(\.sortOrder).sorted() == Array(0..<record.sentences.count) else {
                throw SupabaseServiceError.invalidResponse
            }
            let sentences = record.sentences
                .sorted { $0.sortOrder < $1.sortOrder }
            let mappedSentences = try sentences.map { sentence -> SentenceRecord in
                guard let sentenceID = UUID(uuidString: sentence.id) else {
                    throw SupabaseServiceError.invalidResponse
                }
                let group: SentencePresentationGroup
                if let rawGroup = sentence.presentationGroup {
                    guard let knownGroup = SentencePresentationGroup(rawValue: rawGroup) else {
                        throw SupabaseServiceError.invalidResponse
                    }
                    group = knownGroup
                } else {
                    group = .whatISee
                }
                return SentenceRecord(
                    id: sentenceID,
                    targetText: sentence.targetText,
                    translationText: sentence.translationText,
                    contentVersion: sentence.contentVersion,
                    learningMaterial: sentence.learningMaterial,
                    learningTopicIDs: sentence.learningTopicIDs ?? [],
                    presentationGroup: group,
                    isFavorite: sentence.isFavorite
                )
            }

            let cached = cachedByID[memoryID]
            let memory = MemoryEntry(
                id: memoryID,
                createdAt: record.createdAt,
                imageData: cached?.remoteImagePath == record.imagePath ? cached?.imageData ?? Data() : Data(),
                remoteImagePath: record.imagePath,
                syncedToAccount: true,
                tags: record.tags ?? [],
                sentences: mappedSentences,
                context: record.context
            )
            try SupabaseContentMemory(memory: memory, imagePath: record.imagePath).validate()
            return memory
        }
    }

    func legacyRecoveryCandidateIndex(
        for pending: PendingGeneratedMemoryImage,
        in memories: [MemoryEntry]
    ) -> Int? {
        // Snapshot jobs are recovered only by their immutable request ID, never by timing guesses.
        guard pending.snapshot == nil, !pending.imageData.isEmpty else { return nil }
        let previousIDs = Set(pending.previousMemoryIDs)
        return memories.firstIndex {
            !previousIDs.contains($0.id) && $0.context.isLegacyCompatible &&
                $0.createdAt >= pending.startedAt.addingTimeInterval(-120) &&
                $0.remoteImagePath != nil && $0.imageData.isEmpty && MemoryIdentity.isContentComplete($0)
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
        // A cached difference is not an edit; only explicit outbox entries may be uploaded.
        return CloudSyncPlan(
            queuedGuestMemoriesCount: queuedGuestMemories.count,
            queuedMemoryDeletionsCount: queuedMemoryDeletions.count,
            queuedFavoriteChangesCount: queuedFavoriteChanges.count,
            localStudyProgressCount: queuedLocalStudyProgress.count
        )
    }

    func reconcileLocalMemories(
        localMemories: [MemoryEntry],
        remoteMemories: [MemoryEntry],
        sessionUserID: String
    ) -> CloudSyncReconciliationResult {
        var reconciledMemories = localMemories.deduplicatedByMemoryID()
        let remoteMemories = remoteMemories.deduplicatedByMemoryID()
        var didChange = reconciledMemories.count != localMemories.count

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
        MemoryIdentity.matches(lhs, rhs)
    }

    private func isMemoryContentComplete(_ memory: MemoryEntry) -> Bool {
        MemoryIdentity.isContentComplete(memory)
    }
}
