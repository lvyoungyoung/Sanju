import Foundation

extension AppModel {
    var shouldPreventSignOutForCloudChanges: Bool {
        isSyncingPendingCloudChanges || (hasAuthenticatedSession && (
            !pendingGuestMemoryMigrationQueue.isEmpty || pendingGuestMemoryCount > 0
                || !pendingFavoriteChanges.isEmpty || !pendingMemoryDeletions.isEmpty
                || !pendingMemoryImageUploads.isEmpty || pendingGuestCreditMigration != nil
                || !localSentenceStudyProgressToMerge().isEmpty
        ))
    }
}

struct MemoryRefreshSnapshot {
    let memoryIDs: Set<UUID>
    let favoriteVersions: [UUID: UUID]
}

struct MemorySyncState {
    private(set) var favoriteVersions: [UUID: UUID] = [:]
    private(set) var deletedMemoryIDs: Set<UUID> = []

    mutating func favoriteDidChange(sentenceID: UUID) {
        favoriteVersions[sentenceID] = UUID()
    }

    mutating func memoryWasDeleted(memoryID: UUID) {
        deletedMemoryIDs.insert(memoryID)
    }

    func snapshot(memories: [MemoryEntry]) -> MemoryRefreshSnapshot {
        MemoryRefreshSnapshot(memoryIDs: Set(memories.map(\.id)), favoriteVersions: favoriteVersions)
    }

    func merge(
        remote: [MemoryEntry],
        current: [MemoryEntry],
        queuedGuests: [MemoryEntry],
        pendingFavorites: [PendingFavoriteChange],
        pendingDeletions: [PendingMemoryDeletion],
        snapshot: MemoryRefreshSnapshot
    ) -> [MemoryEntry] {
        let deletedIDs = deletedMemoryIDs.union(pendingDeletions.map(\.memoryID))
            .union(snapshot.memoryIDs.subtracting(current.map(\.id)))
        let favorites = Dictionary(pendingFavorites.map { ($0.sentenceID, $0.isFavorite) },
                                   uniquingKeysWith: { _, latest in latest })
        var localByID = current.memoryDictionaryByID()
        for memory in queuedGuests where localByID[memory.id] == nil {
            localByID[memory.id] = memory
        }

        var merged = remote.filter { !deletedIDs.contains($0.id) }.map { remoteMemory in
            guard let local = localByID[remoteMemory.id] else { return remoteMemory }
            let localSentences = local.sentences.sentenceDictionaryByID()
            var result = remoteMemory
            result.sentences = remoteMemory.sentences.map { sentence in
                var result = sentence
                if let pending = favorites[sentence.id] {
                    result.isFavorite = pending
                } else if !local.syncedToAccount || favoriteVersions[sentence.id] != snapshot.favoriteVersions[sentence.id] {
                    result.isFavorite = localSentences[sentence.id]?.isFavorite ?? sentence.isFavorite
                }
                return result
            }
            if result.imageData.isEmpty, local.remoteImagePath == result.remoteImagePath {
                result = MemoryEntry(id: result.id, createdAt: result.createdAt, imageData: local.imageData,
                                     remoteImagePath: result.remoteImagePath, syncedToAccount: result.syncedToAccount,
                                     tags: result.tags, sentences: result.sentences)
            }
            return result
        }
        let remoteIDs = Set(merged.map(\.id))
        // Keep imports and generations added after the fetch began, not stale account caches.
        merged.append(contentsOf: localByID.values.filter {
            !deletedIDs.contains($0.id) && !remoteIDs.contains($0.id)
                && (!$0.syncedToAccount || !snapshot.memoryIDs.contains($0.id))
        })
        return merged.deduplicatedByMemoryID().sorted { $0.createdAt > $1.createdAt }
    }
}

@MainActor
final class FavoriteChangeSync {
    private var pending: (id: UUID, revision: UUID, task: Task<Void, Never>)?

    func sync(
        revision: UUID,
        next: @escaping (Set<UUID>) -> PendingFavoriteChange?,
        upload: @escaping (PendingFavoriteChange) async throws -> Void,
        acknowledge: @escaping (PendingFavoriteChange) -> Void,
        failed: @escaping (Error) -> Void
    ) async {
        if let pending, pending.revision == revision {
            await pending.task.value
            return
        }
        cancel()
        let id = UUID()
        let task = Task { @MainActor [weak self] in
            defer { if self?.pending?.id == id { self?.pending = nil } }
            var attempted: Set<UUID> = []
            while !Task.isCancelled, let change = next(attempted) {
                attempted.insert(change.id)
                do {
                    try await upload(change)
                    guard !Task.isCancelled else { return }
                    acknowledge(change)
                } catch {
                    guard !Task.isCancelled else { return }
                    failed(error)
                }
            }
        }
        pending = (id, revision, task)
        await task.value
    }

    func cancel() {
        pending?.task.cancel()
        pending = nil
    }
}
