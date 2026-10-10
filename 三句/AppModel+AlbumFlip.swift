import Foundation

extension AppModel {
    @discardableResult
    func toggleAlbumFlipSentenceFavorite(_ item: AlbumFlipItem, ownerID: String) -> Bool {
        guard albumFlipOwnerID == ownerID,
              let sentence = memory(withID: item.memoryID)?.sentences.first(where: { $0.id == item.sentence.id }) else {
            return false
        }
        // Deck items are snapshots; always toggle the live sentence, not the snapshot.
        toggleFavorite(sentenceID: sentence.id)
        return true
    }

    func configureAlbumFlipHistorySync() {
        albumFlipHistorySync = AlbumFlipHistorySync(
            defaults: defaults,
            canUpload: { [weak self] owner, event in
                guard let self, supabaseSession?.userID == owner else { return false }
                return memories.contains { memory in
                    memory.id == event.memoryID && memory.syncedToAccount &&
                        memory.sentences.contains { $0.id == event.sentenceID }
                }
            },
            fetch: { [weak self] owner in
                guard let self else { throw CancellationError() }
                let session = try await albumFlipSession(for: owner)
                return try await supabaseService.fetchAlbumFlipProgress(session: session)
            },
            upload: { [weak self] owner, events in
                guard let self else { throw CancellationError() }
                let session = try await albumFlipSession(for: owner)
                return try await supabaseService.syncAlbumFlipFeedback(session: session, events: events)
            }
        )
        albumFlipHistorySync?.onChange = { [weak self] in self?.albumFlipHistoryRevision += 1 }
    }

    func transferGuestAlbumFeedback(from original: MemoryEntry, to migrated: MemoryEntry, owner: String) {
        guard !Task.isCancelled, supabaseSession?.userID == owner, hasAuthenticatedSession else { return }
        let guest = AlbumFlipHistoryStore(defaults: defaults, ownerID: "guest")
        let account = AlbumFlipHistoryStore(defaults: defaults, ownerID: owner)
        guest.transferGuestMemory(original, to: migrated, destination: account)
    }

    private func albumFlipSession(for owner: String) async throws -> SupabaseSession {
        guard isNetworkAvailable, let current = supabaseSession,
              !current.isAnonymous, current.userID == owner else { throw CancellationError() }
        let session = try await ensureFreshSessionIfNeeded(current)
        try Task.checkCancellation()
        guard supabaseSession?.userID == owner, session.userID == owner, !session.isAnonymous else {
            throw CancellationError()
        }
        return session
    }
}
