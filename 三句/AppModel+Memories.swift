import Foundation

extension AppModel {
    private var initialRemoteMemoryBatchSize: Int {
        20
    }

    private var remoteImageHydrationPersistBatchSize: Int {
        10
    }

    private var remoteImageHydrationUIBatchSize: Int {
        10
    }

    func clearLearningDraft() {
        draftLearningImageData = nil
        draftLearningItemIdentifier = nil
        draftGeneratedMemory = nil
        draftGeneratedMemoryID = nil
    }

    func pendingMemoryImageRequest(memoryID: UUID) -> MemoryImageLoadRequest? {
        guard isNetworkAvailable else { return nil }
        return MemoryImageLoadRequest(
            memory: memories.first(where: { $0.id == memoryID }),
            session: supabaseSession
        )
    }

    func ensureMemoryImageLoaded(memoryID: UUID) async {
        guard !Task.isCancelled,
              let request = pendingMemoryImageRequest(memoryID: memoryID),
              let session = try? await ensureValidSession(),
              isSessionStillCurrent(session),
              request == pendingMemoryImageRequest(memoryID: memoryID) else {
            return
        }

        do {
            let downloadedImageData = try await memoryImageLoader.load(request: request) { [supabaseService] in
                try await supabaseService.downloadMemoryImage(session: session, path: request.remoteImagePath)
            }

            guard !downloadedImageData.isEmpty,
                  let refreshedIndex = memories.firstIndex(where: { $0.id == memoryID }),
                  request == MemoryImageLoadRequest(memory: memories[refreshedIndex], session: supabaseSession) else {
                return
            }

            memories[refreshedIndex] = MemoryEntry(
                id: memories[refreshedIndex].id,
                createdAt: memories[refreshedIndex].createdAt,
                imageData: downloadedImageData,
                remoteImagePath: request.remoteImagePath,
                syncedToAccount: memories[refreshedIndex].syncedToAccount,
                tags: memories[refreshedIndex].tags,
                sentences: memories[refreshedIndex].sentences
            )
            persistMemories()
        } catch {
            return
        }
    }

    func toggleFavorite(sentenceID: UUID) {
        guard let location = locateSentence(sentenceID) else { return }
        setFavorite(sentenceID: sentenceID,
                    isFavorite: !memories[location.memoryIndex].sentences[location.sentenceIndex].isFavorite)
    }

    func deleteFavorite(sentenceID: UUID) {
        setFavorite(sentenceID: sentenceID, isFavorite: false)
    }

    private func setFavorite(sentenceID: UUID, isFavorite: Bool) {
        let revision = accountRequests.revision
        guard let location = locateSentence(sentenceID) else { return }
        guard memories[location.memoryIndex].sentences[location.sentenceIndex].isFavorite != isFavorite else { return }
        memories[location.memoryIndex].sentences[location.sentenceIndex].isFavorite = isFavorite
        favoriteSentencesCount = max(0, favoriteSentencesCount + (isFavorite ? 1 : -1))
        memorySyncState.favoriteDidChange(sentenceID: sentenceID)
        if hasAuthenticatedSession {
            queuePendingFavoriteChange(sentenceID: sentenceID, isFavorite: isFavorite)
        } else {
            upsertPendingGuestMemoryMigrationIfNeeded(memories[location.memoryIndex])
        }
        persistMemories()
        Task {
            guard (try? accountRequests.check(revision)) != nil else { return }
            await syncPendingFavoriteChangesIfNeeded()
            guard (try? accountRequests.check(revision)) != nil else { return }
            await refreshSentenceStudyDueCount()
        }
    }

    func deleteMemory(memoryID: UUID) {
        let revision = accountRequests.revision
        let deletedMemory = memories.first(where: { $0.id == memoryID })
        let imagePath = deletedMemory?.remoteImagePath
        let removedFavoriteCount = deletedMemory?.sentences.filter(\.isFavorite).count ?? 0
        memorySyncState.memoryWasDeleted(memoryID: memoryID)
        removePendingMemoryImageUpload(memoryID: memoryID)
        removePendingGuestMemoryMigration(memoryID: memoryID)
        let sentenceIDs = Set(deletedMemory?.sentences.map(\.id) ?? [])
        pendingFavoriteChanges.removeAll { sentenceIDs.contains($0.sentenceID) }
        persistPendingFavoriteChanges()
        memories.removeAll { $0.id == memoryID }
        invalidateUserStudySceneDetailSentenceCache()
        recordedMemoriesCount = memories.count
        favoriteSentencesCount = max(0, favoriteSentencesCount - removedFavoriteCount)
        if let deletedMemory, deletedMemory.syncedToAccount || isSignedIn {
            queuePendingMemoryDeletion(memoryID: memoryID, remoteImagePath: imagePath)
        }
        let deletion = pendingMemoryDeletions.first { $0.memoryID == memoryID }
        persistMemories()
        guard isSignedIn else {
            Task { await refreshSentenceStudyDueCount() }
            return
        }
        Task {
            guard (try? accountRequests.check(revision)) != nil else { return }
            let didSync = await syncDeleteMemory(memoryID: memoryID, imagePath: imagePath)
            guard (try? accountRequests.check(revision)) != nil else { return }
            if didSync {
                pendingMemoryDeletions.removeAll { $0.id == deletion?.id }
                persistPendingMemoryDeletions()
                await refreshSentenceStudyDueCount()
            } else {
                authErrorMessage = L10n.string("sync.delete_memory.failed", "删除回忆失败，会在下次同步时重试。")
            }
        }
    }

    func memory(withID id: UUID) -> MemoryEntry? {
        memories.first(where: { $0.id == id })
    }

    func refreshRemoteContent() async {
        guard !Task.isCancelled else { return }
        if let remoteContentRefreshTask {
            await remoteContentRefreshTask.value
            return
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if !Task.isCancelled { self.remoteContentRefreshTask = nil } }
            await self.performRemoteContentRefresh()
        }

        remoteContentRefreshTask = task
        await task.value
    }

    private func performRemoteContentRefresh() async {
        guard supabaseSession != nil || loadStoredSession() != nil else { return }
        memoryLoadState = .loading
        var requestRevision = accountRequests.revision
        defer {
            if !Task.isCancelled, accountRequests.revision == requestRevision,
               memories.isEmpty, memoryLoadState != .loaded {
                memoryLoadState = .failed
            }
        }
        let session: SupabaseSession
        if let currentSession = supabaseSession {
            guard let validSession = try? await ensureFreshSessionIfNeeded(currentSession) else { return }
            session = validSession
        } else if loadStoredSession() != nil {
            await ensureRemoteSessionRestoreCompleted()
            guard let restoredSession = supabaseSession else { return }
            guard let validSession = try? await ensureFreshSessionIfNeeded(restoredSession) else { return }
            session = validSession
        } else {
            return
        }
        requestRevision = accountRequests.revision

        if session.isAnonymous {
            refreshLocalSentenceStudyCounts()
            await syncMemoriesFromRemote(refreshCounts: true)
            return
        }

        let revision = accountRequests.revision
        if let migratedProfile = await retryPendingGuestCreditMigrationIfNeeded(for: session) {
            guard (try? accountRequests.check(revision)) != nil else { return }
            applyRemoteProfile(
                migratedProfile,
                fallbackAppleUserID: profile?.appleUserID ?? "",
                treatAsGuest: session.isAnonymous
            )
            persistProfile()
            persistCredits()
        } else if let remoteProfile = try? await supabaseService.fetchProfile(session: session) {
            guard (try? accountRequests.check(revision)) != nil else { return }
            applyRemoteProfile(
                remoteProfile,
                fallbackAppleUserID: profile?.appleUserID ?? "",
                treatAsGuest: session.isAnonymous
            )
            persistProfile()
            persistCredits()
        }

        guard (try? accountRequests.check(revision)) != nil else { return }
        await syncMemoriesFromRemote(refreshCounts: true)
        guard (try? accountRequests.check(revision)) != nil else { return }
        await syncPendingCloudChangesIfNeeded()
        guard (try? accountRequests.check(revision)) != nil else { return }
        await syncMemoriesFromRemote(refreshCounts: true)
        guard (try? accountRequests.check(revision)) != nil else { return }
        await refreshSentenceStudyDueCount()
    }

    func locateSentence(_ sentenceID: UUID) -> (memoryIndex: Int, sentenceIndex: Int)? {
        for memoryIndex in memories.indices {
            if let sentenceIndex = memories[memoryIndex].sentences.firstIndex(where: { $0.id == sentenceID }) {
                return (memoryIndex, sentenceIndex)
            }
        }
        return nil
    }

    func syncMemoriesFromRemote(refreshCounts: Bool, downloadsImages: Bool = true) async {
        guard !Task.isCancelled else { return }
        let revision = accountRequests.revision
        if let remoteMemoriesSyncTask {
            await remoteMemoriesSyncTask.value
            guard (try? accountRequests.check(revision)) != nil else { return }
            if !downloadsImages || !memories.contains(where: \.imageData.isEmpty) {
                return
            }
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if !Task.isCancelled { self.remoteMemoriesSyncTask = nil } }
            await self.performSyncMemoriesFromRemote(
                refreshCounts: refreshCounts,
                downloadsImages: downloadsImages
            )
        }

        remoteMemoriesSyncTask = task
        await task.value
    }

    private func performSyncMemoriesFromRemote(
        refreshCounts: Bool,
        downloadsImages: Bool = true
    ) async {
        memoryLoadState = .loading
        guard let session = try? await ensureValidSession() else {
            if !Task.isCancelled { memoryLoadState = .failed }
            return
        }
        let revision = accountRequests.revision

        if session.isAnonymous {
            let localMemories = memories
                .filter(isMemoryContentComplete)
                .deduplicatedByMemoryID()
                .sorted { $0.createdAt > $1.createdAt }
            memories = localMemories
            if refreshCounts {
                recordedMemoriesCount = localMemories.count
                favoriteSentencesCount = localMemories.reduce(into: 0) { partialResult, memory in
                    partialResult += memory.sentences.filter(\.isFavorite).count
                }
            }
            replacePendingGuestMemoryMigrationQueue(with: localMemories)
            refreshLocalFavoriteSentenceStudyCounts()
            persistMemories()
            memoryLoadState = .loaded
            return
        }

        isSyncingRemoteMemories = true
        defer {
            if isSessionStillCurrent(session) { albumFlipHistorySync?.uploadPending() }
        }
        defer {
            if accountRequests.revision == revision { isSyncingRemoteMemories = false }
        }

        let refreshSnapshot = memorySyncState.snapshot(memories: memories)
        do {
            let remoteRecords = try await supabaseService.fetchMemories(session: session)
            try accountRequests.check(revision)
            guard isSessionStillCurrent(session) else { return }
            let existingMemories = memories.memoryDictionaryByID()
            let remoteMemories = try remoteRecords.map { record -> MemoryEntry in
                let sentences = record.sentences
                    .sorted { $0.sortOrder < $1.sortOrder }
                    .compactMap { sentence -> SentenceRecord? in
                        guard let id = UUID(uuidString: sentence.id) else { return nil }
                        return SentenceRecord(
                            id: id,
                            english: sentence.english,
                            chinese: sentence.chinese,
                            learningTopicIDs: sentence.learningTopicIDs ?? [],
                            presentationGroup: SentencePresentationGroup(rawValue: sentence.presentationGroup ?? "") ?? .whatISee,
                            isFavorite: sentence.isFavorite
                        )
                    }

                guard let memoryID = UUID(uuidString: record.id) else {
                    throw SupabaseServiceError.invalidResponse
                }

                let cachedImageData: Data?
                if let existingMemory = existingMemories[memoryID],
                   existingMemory.remoteImagePath == record.imagePath {
                    cachedImageData = existingMemory.imageData
                } else {
                    cachedImageData = nil
                }

                return MemoryEntry(
                    id: memoryID,
                    createdAt: record.createdAt,
                    imageData: cachedImageData ?? Data(),
                    remoteImagePath: record.imagePath,
                    syncedToAccount: !session.isAnonymous,
                    tags: record.tags ?? [],
                    sentences: sentences
                )
            }
            .filter { isMemoryContentComplete($0) }

            var loadedMemories = remoteMemories
            await reconcilePendingGeneratedMemoryImage(with: &loadedMemories, session: session)
            try accountRequests.check(revision)
            guard isSessionStillCurrent(session) else { return }
            loadedMemories = memorySyncState.merge(
                remote: loadedMemories, current: memories,
                queuedGuests: pendingGuestMemoryMigrationQueue.filter(isMemoryContentComplete),
                pendingFavorites: pendingFavoriteChanges, pendingDeletions: pendingMemoryDeletions,
                snapshot: refreshSnapshot
            )
            memories = loadedMemories
            memoryLoadState = .loaded
            if refreshCounts {
                recordedMemoriesCount = loadedMemories.count
                favoriteSentencesCount = loadedMemories.reduce(into: 0) { partialResult, memory in
                    partialResult += memory.sentences.filter(\.isFavorite).count
                }
            }
            persistMemories()
            await MemoryWidgetSnapshotStore.refreshImmediately(with: loadedMemories)

            guard downloadsImages else {
                remoteMemoryImageHydrationTargetCount = 0
                guard isSessionStillCurrent(session) else { return }
                await refreshFavoriteSentenceStudyCounts()
                try accountRequests.check(revision)
                persistMemories()
                await MemoryWidgetSnapshotStore.refreshImmediately(with: loadedMemories)
                return
            }

            remoteMemoryImageHydrationTargetCount = min(initialRemoteMemoryBatchSize, loadedMemories.count)
            loadedMemories = await hydrateRemoteMemoryImages(
                session: session,
                sourceMemories: loadedMemories,
                through: remoteMemoryImageHydrationTargetCount
            )
            try accountRequests.check(revision)

            guard isSessionStillCurrent(session) else { return }
            memories = loadedMemories
            if session.isAnonymous {
                replacePendingGuestMemoryMigrationQueue(with: loadedMemories.filter(isMemoryContentComplete))
            }

            if refreshCounts {
                recordedMemoriesCount = loadedMemories.count
                favoriteSentencesCount = loadedMemories.reduce(into: 0) { partialResult, memory in
                    partialResult += memory.sentences.filter(\.isFavorite).count
                }
            }
            await refreshFavoriteSentenceStudyCounts()
            try accountRequests.check(revision)
            persistMemories()
            await MemoryWidgetSnapshotStore.refreshImmediately(with: loadedMemories)
        } catch {
            guard !Task.isCancelled, accountRequests.revision == revision else { return }
            memoryLoadState = .failed
            authErrorMessage = error.localizedDescription
        }
    }

    func loadMoreRemoteMemoriesIfNeeded(through visibleCount: Int) async {
        guard visibleCount > 0 else { return }
        guard let session = try? await ensureValidSession(), !session.isAnonymous else { return }

        remoteMemoryImageHydrationTargetCount = max(
            remoteMemoryImageHydrationTargetCount,
            min(visibleCount, memories.count)
        )

        if let remoteMemoryImageHydrationTask {
            await remoteMemoryImageHydrationTask.value
        }

        let targetCount = min(remoteMemoryImageHydrationTargetCount, memories.count)
        guard memories.prefix(targetCount).contains(where: shouldHydrateRemoteImage) else { return }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            self.isHydratingRemoteMemoryImages = true
            defer {
                self.isHydratingRemoteMemoryImages = false
                self.remoteMemoryImageHydrationTask = nil
            }

            let hydratedMemories = await self.hydrateRemoteMemoryImages(
                session: session,
                sourceMemories: self.memories,
                through: targetCount
            )
            guard self.isSessionStillCurrent(session) else { return }
            self.persistMemories()
            await MemoryWidgetSnapshotStore.refreshImmediately(with: hydratedMemories)
        }

        remoteMemoryImageHydrationTask = task
        await task.value

        if remoteMemoryImageHydrationTargetCount > targetCount {
            await loadMoreRemoteMemoriesIfNeeded(through: remoteMemoryImageHydrationTargetCount)
        }
    }

    private func hydrateRemoteMemoryImages(
        session: SupabaseSession,
        sourceMemories: [MemoryEntry],
        through visibleCount: Int
    ) async -> [MemoryEntry] {
        var hydratedMemories = sourceMemories
        let cappedVisibleCount = min(visibleCount, hydratedMemories.count)
        guard cappedVisibleCount > 0 else { return memories }
        var downloadedImageCount = 0

        for index in hydratedMemories.indices {
            guard index < cappedVisibleCount else { break }
            guard !Task.isCancelled, isSessionStillCurrent(session) else { return memories }
            guard shouldHydrateRemoteImage(hydratedMemories[index]) else { continue }
            guard let request = MemoryImageLoadRequest(memory: hydratedMemories[index], session: session) else { continue }

            // A visible cover may have already loaded this image while the batch was waiting.
            if let currentMemory = memories.first(where: { $0.id == request.memoryID }),
               currentMemory.remoteImagePath == request.remoteImagePath,
               !currentMemory.imageData.isEmpty {
                hydratedMemories[index] = currentMemory
                continue
            }

            do {
                let downloadedImageData = try await memoryImageLoader.load(request: request) { [supabaseService] in
                    try await supabaseService.downloadMemoryImage(session: session, path: request.remoteImagePath)
                }
                guard !downloadedImageData.isEmpty else { continue }
                hydratedMemories[index] = MemoryEntry(
                    id: hydratedMemories[index].id,
                    createdAt: hydratedMemories[index].createdAt,
                    imageData: downloadedImageData,
                    remoteImagePath: request.remoteImagePath,
                    syncedToAccount: hydratedMemories[index].syncedToAccount,
                    tags: hydratedMemories[index].tags,
                    sentences: hydratedMemories[index].sentences
                )

                downloadedImageCount += 1
                guard isSessionStillCurrent(session) else { return hydratedMemories }
                if downloadedImageCount.isMultiple(of: remoteImageHydrationUIBatchSize) {
                    mergeHydratedRemoteImages(from: hydratedMemories)
                }
                if downloadedImageCount.isMultiple(of: remoteImageHydrationPersistBatchSize) {
                    persistMemories()
                }
            } catch {
                continue
            }
        }

        guard isSessionStillCurrent(session) else { return memories }
        mergeHydratedRemoteImages(from: hydratedMemories)
        return memories
    }

    @discardableResult
    private func mergeHydratedRemoteImages(from hydratedMemories: [MemoryEntry]) -> Bool {
        let hydratedImagesByID: [UUID: (remoteImagePath: String, imageData: Data)] = Dictionary(
            hydratedMemories.compactMap { memory in
                guard let remoteImagePath = memory.remoteImagePath, !memory.imageData.isEmpty else {
                    return nil
                }
                return (memory.id, (remoteImagePath: remoteImagePath, imageData: memory.imageData))
            },
            uniquingKeysWith: { existing, _ in existing }
        )

        guard !hydratedImagesByID.isEmpty else { return false }

        var didUpdate = false
        for index in memories.indices {
            let currentMemory = memories[index]
            guard currentMemory.imageData.isEmpty,
                  let currentRemoteImagePath = currentMemory.remoteImagePath,
                  let hydratedImage = hydratedImagesByID[currentMemory.id],
                  hydratedImage.remoteImagePath == currentRemoteImagePath else {
                continue
            }

            memories[index] = MemoryEntry(
                id: currentMemory.id,
                createdAt: currentMemory.createdAt,
                imageData: hydratedImage.imageData,
                remoteImagePath: currentMemory.remoteImagePath,
                syncedToAccount: currentMemory.syncedToAccount,
                tags: currentMemory.tags,
                sentences: currentMemory.sentences
            )
            didUpdate = true
        }

        return didUpdate
    }

    private func shouldHydrateRemoteImage(_ memory: MemoryEntry) -> Bool {
        memory.imageData.isEmpty && memory.remoteImagePath != nil
    }

    func isSessionStillCurrent(_ session: SupabaseSession) -> Bool {
        guard !Task.isCancelled else { return false }
        guard let currentSession = supabaseSession else { return false }
        return currentSession.userID == session.userID && currentSession.isAnonymous == session.isAnonymous
    }

    func matchesMemoryIdentity(_ lhs: MemoryEntry, _ rhs: MemoryEntry) -> Bool {
        MemoryIdentity.matches(lhs, rhs)
    }

    func syncDeleteMemory(memoryID: UUID, imagePath: String?) async -> Bool {
        guard let session = try? await ensureValidSession() else { return false }
        do {
            try await supabaseService.deleteMemory(session: session, memoryID: memoryID, imagePath: imagePath)
            return true
        } catch {
            return false
        }
    }

    func retryPendingMemoryImageUploadsIfNeeded() async {
        guard !isRetryingPendingMemoryImageUploads else { return }
        guard !pendingMemoryImageUploads.isEmpty else { return }
        guard hasRemoteSession else { return }

        isRetryingPendingMemoryImageUploads = true
        defer { isRetryingPendingMemoryImageUploads = false }

        await processPendingMemoryImageUploads()
    }

    func processPendingMemoryImageUploads() async {
        guard !pendingMemoryImageUploads.isEmpty else { return }
        guard let session = try? await ensureValidSession() else { return }

        for pendingUpload in pendingMemoryImageUploads {
            guard let memory = memories.first(where: { $0.id == pendingUpload.memoryID }) else {
                removePendingMemoryImageUpload(memoryID: pendingUpload.memoryID)
                continue
            }

            guard !memory.imageData.isEmpty else {
                continue
            }

            guard memory.remoteImagePath == pendingUpload.remoteImagePath else {
                removePendingMemoryImageUpload(memoryID: pendingUpload.memoryID)
                continue
            }

            do {
                try await supabaseService.uploadMemoryImage(
                    session: session,
                    path: pendingUpload.remoteImagePath,
                    data: memory.imageData
                )
                removePendingMemoryImageUpload(memoryID: pendingUpload.memoryID)
            } catch {
                continue
            }
        }
    }

    func uploadMemoryImageIfNeeded(
        memoryID: UUID,
        remoteImagePath: String?,
        imageData: Data,
        session: SupabaseSession
    ) async {
        guard let remoteImagePath, !imageData.isEmpty else { return }
        let revision = accountRequests.revision

        do {
            try await supabaseService.uploadMemoryImage(
                session: session,
                path: remoteImagePath,
                data: imageData
            )
            try accountRequests.check(revision)
            removePendingMemoryImageUpload(memoryID: memoryID)
        } catch {
            guard (try? accountRequests.check(revision)) != nil,
                  !memorySyncState.deletedMemoryIDs.contains(memoryID),
                  memories.contains(where: { $0.id == memoryID }) else { return }
            queuePendingMemoryImageUpload(memoryID: memoryID, remoteImagePath: remoteImagePath)
        }
    }

    func enqueuePendingMemoryImageUploadIfNeeded(
        memoryID: UUID,
        remoteImagePath: String?,
        imageData: Data
    ) {
        guard let remoteImagePath, !imageData.isEmpty else { return }
        queuePendingMemoryImageUpload(memoryID: memoryID, remoteImagePath: remoteImagePath)
    }

    func queuePendingMemoryImageUpload(memoryID: UUID, remoteImagePath: String) {
        pendingMemoryImageUploads.removeAll { $0.memoryID == memoryID }
        pendingMemoryImageUploads.append(
            PendingMemoryImageUpload(memoryID: memoryID, remoteImagePath: remoteImagePath)
        )
        persistPendingMemoryImageUploads()
    }

    func removePendingMemoryImageUpload(memoryID: UUID) {
        let originalCount = pendingMemoryImageUploads.count
        pendingMemoryImageUploads.removeAll { $0.memoryID == memoryID }
        guard pendingMemoryImageUploads.count != originalCount else { return }
        persistPendingMemoryImageUploads()
    }

    func reconcilePendingGeneratedMemoryImage(
        with memories: inout [MemoryEntry],
        session: SupabaseSession
    ) async {
        guard let pendingGeneratedMemoryImage else { return }
        guard !pendingGeneratedMemoryImage.imageData.isEmpty else {
            clearPendingGeneratedMemoryImage()
            return
        }

        let previousMemoryIDs = Set(pendingGeneratedMemoryImage.previousMemoryIDs)
        guard let targetIndex = memories.firstIndex(where: { memory in
            !previousMemoryIDs.contains(memory.id) &&
            memory.createdAt >= pendingGeneratedMemoryImage.startedAt.addingTimeInterval(-120) &&
            memory.remoteImagePath != nil &&
            memory.imageData.isEmpty &&
            isMemoryContentComplete(memory)
        }) else {
            return
        }

        let targetMemory = memories[targetIndex]
        guard let remoteImagePath = targetMemory.remoteImagePath else { return }

        queuePendingMemoryImageUpload(memoryID: targetMemory.id, remoteImagePath: remoteImagePath)
        memories[targetIndex] = MemoryEntry(
            id: targetMemory.id,
            createdAt: targetMemory.createdAt,
            imageData: pendingGeneratedMemoryImage.imageData,
            remoteImagePath: remoteImagePath,
            syncedToAccount: targetMemory.syncedToAccount,
            tags: targetMemory.tags,
            sentences: targetMemory.sentences
        )
        clearPendingGeneratedMemoryImage()
        await uploadMemoryImageIfNeeded(
            memoryID: targetMemory.id,
            remoteImagePath: remoteImagePath,
            imageData: memories[targetIndex].imageData,
            session: session
        )
    }

    func upsertPendingGuestMemoryMigrationIfNeeded(_ memory: MemoryEntry) {
        guard !isSignedIn else { return }
        guard isMemoryContentComplete(memory) else { return }

        pendingGuestMemoryMigrationQueue.removeAll { $0.id == memory.id }
        pendingGuestMemoryMigrationQueue.append(memory)
        pendingGuestMemoryMigrationQueue = pendingGuestMemoryMigrationQueue
            .deduplicatedByMemoryID()
            .sorted { $0.createdAt > $1.createdAt }
        persistPendingGuestMemoryMigrationQueue()
    }

    func syncPendingGuestMemoryMigrationIfNeeded(memoryID: UUID) {
        guard !isSignedIn else { return }
        guard let memory = memories.first(where: { $0.id == memoryID }) else { return }
        guard pendingGuestMemoryMigrationQueue.contains(where: { $0.id == memoryID }) else { return }
        upsertPendingGuestMemoryMigrationIfNeeded(memory)
    }

    func removePendingGuestMemoryMigration(memoryID: UUID) {
        let originalCount = pendingGuestMemoryMigrationQueue.count
        pendingGuestMemoryMigrationQueue.removeAll { $0.id == memoryID }
        guard pendingGuestMemoryMigrationQueue.count != originalCount else { return }
        persistPendingGuestMemoryMigrationQueue()
    }

    func replacePendingGuestMemoryMigrationQueue(with memories: [MemoryEntry]) {
        guard !isSignedIn else { return }
        pendingGuestMemoryMigrationQueue = memories.sorted { $0.createdAt > $1.createdAt }
        persistPendingGuestMemoryMigrationQueue()
    }

    func queuePendingFavoriteChange(sentenceID: UUID, isFavorite: Bool) {
        pendingFavoriteChanges.removeAll { $0.sentenceID == sentenceID }
        pendingFavoriteChanges.append(
            PendingFavoriteChange(sentenceID: sentenceID, isFavorite: isFavorite)
        )
        persistPendingFavoriteChanges()
    }

    func queuePendingMemoryDeletion(memoryID: UUID, remoteImagePath: String?) {
        pendingMemoryDeletions.removeAll { $0.memoryID == memoryID }
        pendingMemoryDeletions.append(
            PendingMemoryDeletion(memoryID: memoryID, remoteImagePath: remoteImagePath)
        )
        persistPendingMemoryDeletions()
    }

    func refreshSentenceStudyDueCount() async {
        guard !Task.isCancelled else { return }
        let refreshID = UUID()
        studyOverviewRefreshID = refreshID
        studySceneSummariesRefreshID = refreshID
        guard !isRestoringAuthenticatedSession else { return }
        if !isSignedIn, loadStoredSession()?.isAnonymous == false {
            studyOverviewLoadState = .failed
            studySceneLoadState = .failed
            return
        }
        guard isSignedIn else {
            refreshLocalSentenceStudyCounts()
            refreshLocalFavoriteSentenceStudyCounts()
            memorySentenceCount = memories.reduce(0) { $0 + $1.sentences.count }
            masteredSentenceCount = localMasteredSentenceCount()
            sentenceStudyTopicSummaries = [.favorites: makeFavoriteStudyTopicSummary()]
            userStudySceneSummaries = []
            isRepeatingSentenceStudyQueue = false
            studyOverviewLoadState = .loaded
            studySceneLoadState = .loaded
            return
        }

        studyOverviewLoadState = .loading
        studySceneLoadState = .loading
        let revision = accountRequests.revision
        let requestedUserID = supabaseSession?.userID
        do {
            let session = try await ensureValidSession()
            guard !session.isAnonymous, session.userID == requestedUserID,
                  isSessionStillCurrent(session) else { return }
            let favoriteSentenceIDs = currentFavoriteSentenceIDs()
            let snapshot = try await StudyOverviewSnapshot.load(
                from: supabaseService,
                session: session,
                favoriteSentenceIDs: favoriteSentenceIDs,
                onScenesLoaded: { [weak self] scenes in
                    guard let self, !Task.isCancelled, accountRequests.revision == revision,
                          studySceneSummariesRefreshID == refreshID else { return }
                    if let scenes { userStudySceneSummaries = scenes }
                    studySceneLoadState = scenes == nil ? .failed : .loaded
                },
                onContentLoaded: { [weak self] scenes, count in
                    guard let self, !Task.isCancelled, accountRequests.revision == revision,
                          studyOverviewRefreshID == refreshID else { return }
                    if let count { memorySentenceCount = count }
                    studyOverviewLoadState = scenes != nil && count != nil ? .loaded : .failed
                    if studySceneSummariesRefreshID == refreshID {
                        if let scenes { userStudySceneSummaries = scenes }
                        studySceneLoadState = scenes == nil ? .failed : .loaded
                    }
                }
            )
            guard !Task.isCancelled, isSignedIn, isSessionStillCurrent(session),
                  studyOverviewRefreshID == refreshID else { return }

            if let count = snapshot.dueCount { sentenceStudyDueCount = count }
            if let count = snapshot.todayCount { sentenceStudyTodayCount = count }
            if let count = snapshot.reviewableTodayCount { sentenceStudyReviewableTodayCount = count }
            if let count = snapshot.sentenceCount { memorySentenceCount = count }
            if let count = snapshot.masteredCount { masteredSentenceCount = count }
            if let counts = snapshot.favoriteCounts {
                let existingCounts = favoriteSentenceStudyCounts
                favoriteSentenceStudyCounts = currentFavoriteSentenceIDs().reduce(into: [:]) { result, sentenceID in
                    result[sentenceID] = favoriteSentenceIDs.contains(sentenceID)
                        ? (counts[sentenceID] ?? 0)
                        : (existingCounts[sentenceID] ?? 0)
                }
            }
            sentenceStudyTopicSummaries = [.favorites: makeFavoriteStudyTopicSummary()]
            if studySceneSummariesRefreshID == refreshID, let scenes = snapshot.scenes {
                userStudySceneSummaries = scenes
            }
        } catch {
            // Network failures and view cancellation must not erase the last successful overview.
            if accountRequests.revision == revision, studyOverviewRefreshID == refreshID {
                if studyOverviewLoadState == .loading { studyOverviewLoadState = .failed }
                if studySceneSummariesRefreshID == refreshID, studySceneLoadState == .loading { studySceneLoadState = .failed }
            }
            return
        }
    }

    func loadSentenceStudyTopicSession(
        for topic: SentenceStudyTopic
    ) async throws -> SentenceStudyTopicSession? {
        // Built-in category queues were removed. Custom scenes use
        // loadUserStudySceneSession instead of this favorites-only path.
        guard topic.usesFavoriteQueue else { return nil }

        guard isSignedIn else {
            refreshLocalSentenceStudyCounts()
            sentenceStudyTopicSummaries = [.favorites: makeFavoriteStudyTopicSummary()]

            let queue = localSentenceStudyDueQueue(limit: Int.max, topic: topic).shuffled()
            if !queue.isEmpty {
                return SentenceStudyTopicSession(topic: topic, queue: queue, startsInReviewMode: false)
            }

            let reviewQueue = localSentenceStudyTodayReviewQueue(limit: Int.max, topic: topic).shuffled()
            guard !reviewQueue.isEmpty else { return nil }
            return SentenceStudyTopicSession(topic: topic, queue: reviewQueue, startsInReviewMode: true)
        }

        guard isNetworkAvailable else {
            throw SentenceStudyTopicLoadingError.networkUnavailable
        }

        let session = try await ensureValidSession()
        guard !session.isAnonymous else {
            throw SentenceStudyTopicLoadingError.networkUnavailable
        }

        let queue = try await supabaseService.fetchSentenceStudyQueue(
            session: session,
            limit: 1000
        ).shuffled()
        if !queue.isEmpty {
            await refreshSentenceStudyDueCount()
            return SentenceStudyTopicSession(topic: topic, queue: queue, startsInReviewMode: false)
        }

        let reviewQueue = try await supabaseService.fetchSentenceStudyTodayReviewQueue(
            session: session,
            limit: 1000
        ).shuffled()
        await refreshSentenceStudyDueCount()
        guard !reviewQueue.isEmpty else { return nil }
        return SentenceStudyTopicSession(topic: topic, queue: reviewQueue, startsInReviewMode: true)
    }

    func extractStudyTopicExpressions(
        topicKey: String,
        sourceSentences: [StudyTopicExpressionSourceSentence]
    ) async throws -> [StudyTopicExpression] {
        guard isNetworkAvailable else {
            throw SentenceStudyTopicLoadingError.networkUnavailable
        }

        let session = try await ensureValidSession()
        return try await supabaseService.extractStudyTopicExpressions(
            session: session,
            topicKey: topicKey,
            sourceSentences: session.isAnonymous ? sourceSentences : nil
        )
    }

    func refreshFavoriteSentenceStudyCounts() async {
        let favoriteSentenceIDs = currentFavoriteSentenceIDs()
        guard !favoriteSentenceIDs.isEmpty else {
            favoriteSentenceStudyCounts = [:]
            return
        }

        guard isSignedIn else {
            refreshLocalFavoriteSentenceStudyCounts(sentenceIDs: favoriteSentenceIDs)
            return
        }

        do {
            let session = try await ensureValidSession()
            guard !session.isAnonymous else {
                refreshLocalFavoriteSentenceStudyCounts(sentenceIDs: favoriteSentenceIDs)
                return
            }

            let remoteCounts = try await supabaseService.fetchSentenceStudyCounts(
                session: session,
                sentenceIDs: Array(favoriteSentenceIDs)
            )
            guard isSessionStillCurrent(session) else { return }
            favoriteSentenceStudyCounts = favoriteSentenceIDs.reduce(into: [:]) { partialResult, sentenceID in
                partialResult[sentenceID] = remoteCounts[sentenceID] ?? 0
            }
        } catch {
            favoriteSentenceStudyCounts = favoriteSentenceStudyCounts.filter { sentenceID, _ in
                favoriteSentenceIDs.contains(sentenceID)
            }
        }
    }

    func startSentenceStudy() async {
        guard !isLoadingSentenceStudyQueue else { return }

        isLoadingSentenceStudyQueue = true
        sentenceStudyErrorMessage = nil
        isRepeatingSentenceStudyQueue = false
        defer { isLoadingSentenceStudyQueue = false }

        guard isSignedIn else {
            startLocalSentenceStudy()
            return
        }

        guard isNetworkAvailable else {
            sentenceStudyErrorMessage = L10n.string("study.error.network_unavailable", "当前网络不可用，请连接网络后再开始学习。")
            return
        }

        do {
            let session = try await ensureValidSession()
            guard !session.isAnonymous else {
                sentenceStudyErrorMessage = L10n.string("study.error.sign_in_required", "登录后就可以同步学习记录了。")
                isShowingSignInSheet = true
                return
            }

            let dueCount = try await supabaseService.fetchSentenceStudyDueCount(session: session)
            let todayCount = (try? await supabaseService.fetchSentenceStudyTodayCount(session: session)) ?? 0
            let reviewableTodayCount = (try? await supabaseService.fetchSentenceStudyReviewableTodayCount(session: session)) ?? 0
            sentenceStudyDueCount = dueCount
            sentenceStudyTodayCount = todayCount
            sentenceStudyReviewableTodayCount = reviewableTodayCount

            if dueCount > 0 {
                let queue = try await supabaseService.fetchSentenceStudyQueue(
                    session: session,
                    limit: dueCount
                ).shuffled()
                sentenceStudyQueue = queue
                isRepeatingSentenceStudyQueue = false

                if queue.isEmpty {
                    sentenceStudyDueCount = 0
                    sentenceStudyErrorMessage = L10n.string("study.error.done_today", "今天该学的收藏句子已经完成了。")
                    isShowingSentenceStudySession = false
                    return
                }

                isShowingSentenceStudySession = true
                return
            }

            guard reviewableTodayCount > 0 else {
                sentenceStudyDueCount = 0
                sentenceStudyReviewableTodayCount = 0
                sentenceStudyErrorMessage = L10n.string("study.error.done_today", "今天该学的收藏句子已经完成了。")
                isShowingSentenceStudySession = false
                return
            }

            let reviewQueue = try await supabaseService.fetchSentenceStudyTodayReviewQueue(
                session: session,
                limit: max(reviewableTodayCount, 1)
            )
            let shuffledReviewQueue = reviewQueue.shuffled()
            sentenceStudyQueue = shuffledReviewQueue

            guard !shuffledReviewQueue.isEmpty else {
                isRepeatingSentenceStudyQueue = false
                sentenceStudyReviewableTodayCount = 0
                sentenceStudyErrorMessage = L10n.string("study.error.review_queue_unavailable", "今天学过的句子暂时无法加载，请稍后再试。")
                isShowingSentenceStudySession = false
                return
            }

            isRepeatingSentenceStudyQueue = true
            isShowingSentenceStudySession = true
        } catch {
            #if DEBUG
            print("[SentenceStudy] start failed :: \(error.localizedDescription)")
            #endif
            isRepeatingSentenceStudyQueue = false
            sentenceStudyErrorMessage = L10n.string("study.error.load_failed", "暂时无法加载学习内容，请稍后再试。")
        }
    }

    func prepareSentenceForDirectStudy(sentenceID: UUID) async -> SentenceStudyQueueItem? {
        guard let location = locateSentence(sentenceID) else { return nil }

        if isSignedIn && !isNetworkAvailable {
            sentenceStudyErrorMessage = L10n.string("study.error.network_unavailable", "当前网络不可用，请连接网络后再开始学习。")
            return nil
        }

        let memory = memories[location.memoryIndex]
        let sentence = memory.sentences[location.sentenceIndex]
        let progress = isSignedIn ? nil : localSentenceStudyProgress[
            SentenceStudyProgressKey(sentenceID: sentenceID, studyTopic: .favorites)
        ]

        return SentenceStudyQueueItem(
            sentenceID: sentence.id,
            memoryID: memory.id,
            english: sentence.english,
            chinese: sentence.chinese,
            imagePath: memory.remoteImagePath ?? "",
            createdAt: memory.createdAt,
            learningStep: progress?.learningStep ?? 0,
            masteredReviewCount: progress?.masteredReviewCount ?? 0,
            correctCount: progress?.correctCount ?? favoriteSentenceStudyCounts[sentenceID] ?? 0,
            wrongCount: progress?.wrongCount ?? 0,
            lastResult: progress?.lastResult,
            nextReviewAt: progress?.nextReviewDay
        )
    }

    func recordSentenceStudyCompletion(
        sentenceID: UUID,
        studyTopic: SentenceStudyTopic = .favorites
    ) async throws -> SentenceStudyProgress {
        guard isSignedIn else {
            return recordLocalSentenceStudyCompletion(sentenceID: sentenceID, studyTopic: studyTopic)
        }

        let session = try await ensureValidSession()
        let progress = try await supabaseService.recordSentenceStudyResult(
            session: session,
            sentenceID: sentenceID,
            wasCorrect: true,
            studyTopic: studyTopic
        )
        let isFavorite: Bool
        if let location = locateSentence(sentenceID) {
            isFavorite = memories[location.memoryIndex].sentences[location.sentenceIndex].isFavorite
        } else {
            isFavorite = false
        }

        if studyTopic.usesFavoriteQueue && isFavorite {
            favoriteSentenceStudyCounts[sentenceID] = progress.correctCount
            sentenceStudyDueCount = max(0, sentenceStudyDueCount - 1)
            sentenceStudyReviewableTodayCount += 1
        }
        sentenceStudyTodayCount += 1
        Task { await refreshSentenceStudyDueCount() }
        return progress
    }

    func loadSentenceStudyTodayReviewQueue(
        for topic: SentenceStudyTopic = .favorites
    ) async throws -> [SentenceStudyQueueItem] {
        guard topic.usesFavoriteQueue else { return [] }

        guard isSignedIn else {
            let reviewQueue = localSentenceStudyTodayReviewQueue(limit: 1000, topic: topic).shuffled()
            sentenceStudyQueue = reviewQueue
            sentenceStudyReviewableTodayCount = reviewQueue.count
            isRepeatingSentenceStudyQueue = !reviewQueue.isEmpty
            return reviewQueue
        }

        let session = try await ensureValidSession()
        guard !session.isAnonymous else { return [] }

        let todayCount = (try? await supabaseService.fetchSentenceStudyTodayCount(session: session)) ?? sentenceStudyTodayCount
        sentenceStudyTodayCount = todayCount
        let reviewableTodayCount = (try? await supabaseService.fetchSentenceStudyReviewableTodayCount(session: session)) ?? sentenceStudyReviewableTodayCount
        let reviewQueue = try await supabaseService.fetchSentenceStudyTodayReviewQueue(
            session: session,
            limit: max(reviewableTodayCount, 1)
        ).shuffled()
        sentenceStudyQueue = reviewQueue
        sentenceStudyReviewableTodayCount = reviewQueue.count
        isRepeatingSentenceStudyQueue = !reviewQueue.isEmpty
        return reviewQueue
    }

    func finishSentenceStudySession() async {
        isShowingSentenceStudySession = false
        isRepeatingSentenceStudyQueue = false
        sentenceStudyQueue = []
        await refreshSentenceStudyDueCount()
    }

    private func refreshLocalSentenceStudyCounts() {
        let today = localStudyDay()
        sentenceStudyTodayCount = localStudiedTodayCount(today: today)
        sentenceStudyDueCount = localSentenceStudyDueQueue(limit: Int.max, today: today).count
        sentenceStudyReviewableTodayCount = localSentenceStudyTodayReviewQueue(limit: Int.max, today: today).count
    }

    private func makeFavoriteStudyTopicSummary() -> SentenceStudyTopicSummary {
        let sentenceIDs = currentFavoriteSentenceIDs()
        let correctCounts = sentenceIDs.map { favoriteSentenceStudyCounts[$0] ?? 0 }
        let masteryScore = correctCounts.isEmpty
            ? 0
            : correctCounts.reduce(0) { partialResult, correctCount in
                partialResult + SentenceStudyMastery.score(forCorrectCount: correctCount)
            } / correctCounts.count

        return SentenceStudyTopicSummary(
            totalCount: sentenceIDs.count,
            dueCount: sentenceStudyDueCount,
            studiedCount: correctCounts.filter { $0 > 0 }.count,
            reviewableTodayCount: sentenceStudyReviewableTodayCount,
            masteryScore: masteryScore
        )
    }

    private func startLocalSentenceStudy() {
        refreshLocalSentenceStudyCounts()

        if sentenceStudyDueCount > 0 {
            let queue = localSentenceStudyDueQueue(limit: sentenceStudyDueCount).shuffled()
            sentenceStudyQueue = queue
            isRepeatingSentenceStudyQueue = false

            guard !queue.isEmpty else {
                sentenceStudyDueCount = 0
                sentenceStudyErrorMessage = L10n.string("study.error.done_today", "今天该学的收藏句子已经完成了。")
                isShowingSentenceStudySession = false
                return
            }

            isShowingSentenceStudySession = true
            return
        }

        guard sentenceStudyReviewableTodayCount > 0 else {
            sentenceStudyDueCount = 0
            sentenceStudyReviewableTodayCount = 0
            sentenceStudyErrorMessage = L10n.string("study.error.done_today", "今天该学的收藏句子已经完成了。")
            isShowingSentenceStudySession = false
            return
        }

        let reviewQueue = localSentenceStudyTodayReviewQueue(limit: sentenceStudyReviewableTodayCount).shuffled()
        sentenceStudyQueue = reviewQueue

        guard !reviewQueue.isEmpty else {
            isRepeatingSentenceStudyQueue = false
            sentenceStudyReviewableTodayCount = 0
            sentenceStudyErrorMessage = L10n.string("study.error.review_queue_unavailable", "今天学过的句子暂时无法加载，请稍后再试。")
            isShowingSentenceStudySession = false
            return
        }

        isRepeatingSentenceStudyQueue = true
        isShowingSentenceStudySession = true
    }

    private func recordLocalSentenceStudyCompletion(
        sentenceID: UUID,
        studyTopic: SentenceStudyTopic
    ) -> SentenceStudyProgress {
        let now = Date()
        let today = localStudyDay(for: now)
        let progressKey = SentenceStudyProgressKey(sentenceID: sentenceID, studyTopic: studyTopic)
        var progress = localSentenceStudyProgress[progressKey] ?? LocalSentenceStudyProgress(
            sentenceID: sentenceID,
            studyTopic: studyTopic,
            nextReviewDay: today
        )

        if let lastStudiedDay = progress.lastStudiedAt ?? progress.lastStudiedDay,
           isSameLocalStudyDay(lastStudiedDay, today) {
            return makeSentenceStudyProgress(from: progress)
        }

        progress.correctCount += 1
        progress.lastResult = .correct
        progress.lastStudiedAt = now
        progress.lastStudiedDay = today

        if progress.learningStep < 5 {
            progress.learningStep += 1
            progress.nextReviewDay = localNextReviewDay(after: today, learningStep: progress.learningStep)
        } else {
            progress.learningStep = 5
            progress.masteredReviewCount += 1
            progress.nextReviewDay = localMasteredNextReviewDay(after: today, masteredReviewCount: progress.masteredReviewCount)
        }

        localSentenceStudyProgress[progressKey] = progress
        if studyTopic.usesFavoriteQueue {
            favoriteSentenceStudyCounts[sentenceID] = progress.correctCount
        }
        persistLocalSentenceStudyProgress()
        refreshLocalSentenceStudyCounts()
        memorySentenceCount = memories.reduce(0) { $0 + $1.sentences.count }
        masteredSentenceCount = localMasteredSentenceCount()
        sentenceStudyTopicSummaries = [.favorites: makeFavoriteStudyTopicSummary()]
        return makeSentenceStudyProgress(from: progress)
    }

    private func localSentenceStudyDueQueue(
        limit: Int,
        today: Date? = nil,
        topic: SentenceStudyTopic? = nil
    ) -> [SentenceStudyQueueItem] {
        let studyDay = today ?? localStudyDay()
        return localSentenceStudyCandidates(today: studyDay, topic: topic)
            .filter { $0.priority < 99 }
            .sorted { lhs, rhs in
                if lhs.priority != rhs.priority {
                    return lhs.priority < rhs.priority
                }
                if lhs.nextReviewDay != rhs.nextReviewDay {
                    return lhs.nextReviewDay < rhs.nextReviewDay
                }
                return lhs.createdAt > rhs.createdAt
            }
            .prefix(max(limit, 0))
            .map(\.item)
    }

    private func localSentenceStudyTodayReviewQueue(
        limit: Int,
        today: Date? = nil,
        topic: SentenceStudyTopic? = nil
    ) -> [SentenceStudyQueueItem] {
        let studyDay = today ?? localStudyDay()

        return memories
            .flatMap { memory in
                memory.sentences
                    .filter { sentence in
                        matches(sentence: sentence, studyTopic: topic)
                    }
                    .compactMap { sentence -> LocalSentenceStudyCandidate? in
                        guard let progress = localProgress(for: sentence.id, topic: topic ?? .favorites),
                              let lastStudiedDay = progress.lastStudiedAt ?? progress.lastStudiedDay,
                              isSameLocalStudyDay(lastStudiedDay, studyDay) else {
                            return nil
                        }

                        return LocalSentenceStudyCandidate(
                            item: makeLocalSentenceStudyQueueItem(memory: memory, sentence: sentence, progress: progress),
                            priority: 0,
                            nextReviewDay: progress.nextReviewDay,
                            createdAt: memory.createdAt,
                            lastStudiedAt: progress.lastStudiedAt
                        )
                    }
            }
            .sorted { lhs, rhs in
                let lhsStudiedAt = lhs.lastStudiedAt ?? Date.distantFuture
                let rhsStudiedAt = rhs.lastStudiedAt ?? Date.distantFuture
                if lhsStudiedAt != rhsStudiedAt {
                    return lhsStudiedAt < rhsStudiedAt
                }
                return lhs.createdAt > rhs.createdAt
            }
            .prefix(max(limit, 0))
            .map(\.item)
    }

    private func localSentenceStudyCandidates(
        today: Date,
        topic: SentenceStudyTopic? = nil
    ) -> [LocalSentenceStudyCandidate] {
        memories
            .sorted { $0.createdAt > $1.createdAt }
            .flatMap { memory in
                memory.sentences
                    .filter { sentence in
                        matches(sentence: sentence, studyTopic: topic)
                    }
                    .map { sentence -> LocalSentenceStudyCandidate in
                        let progress = localProgress(for: sentence.id, topic: topic ?? .favorites)
                        let priority = localSentenceStudyPriority(progress: progress, today: today)
                        let nextReviewDay = progress?.nextReviewDay ?? today
                        return LocalSentenceStudyCandidate(
                            item: makeLocalSentenceStudyQueueItem(memory: memory, sentence: sentence, progress: progress),
                            priority: priority,
                            nextReviewDay: nextReviewDay,
                            createdAt: memory.createdAt,
                            lastStudiedAt: progress?.lastStudiedAt
                        )
                    }
            }
    }

    private func localSentenceStudyPriority(progress: LocalSentenceStudyProgress?, today: Date) -> Int {
        guard let progress else { return 2 }
        if let lastStudiedDay = progress.lastStudiedAt ?? progress.lastStudiedDay,
           isSameLocalStudyDay(lastStudiedDay, today) {
            return 99
        }
        guard localStudyDay(for: progress.nextReviewDay) <= today else { return 99 }
        return progress.learningStep < 5 ? 1 : 3
    }

    private func matches(sentence: SentenceRecord, studyTopic: SentenceStudyTopic?) -> Bool {
        guard let studyTopic else {
            return sentence.isFavorite
        }
        return studyTopic.usesFavoriteQueue && sentence.isFavorite
    }

    private func localProgress(
        for sentenceID: UUID,
        topic: SentenceStudyTopic
    ) -> LocalSentenceStudyProgress? {
        localSentenceStudyProgress[SentenceStudyProgressKey(sentenceID: sentenceID, studyTopic: topic)]
    }

    private func makeLocalSentenceStudyQueueItem(
        memory: MemoryEntry,
        sentence: SentenceRecord,
        progress: LocalSentenceStudyProgress?
    ) -> SentenceStudyQueueItem {
        SentenceStudyQueueItem(
            sentenceID: sentence.id,
            memoryID: memory.id,
            english: sentence.english,
            chinese: sentence.chinese,
            imagePath: memory.remoteImagePath ?? "",
            createdAt: memory.createdAt,
            learningStep: progress?.learningStep ?? 0,
            masteredReviewCount: progress?.masteredReviewCount ?? 0,
            correctCount: progress?.correctCount ?? 0,
            wrongCount: progress?.wrongCount ?? 0,
            lastResult: progress?.lastResult,
            nextReviewAt: progress?.nextReviewDay
        )
    }

    private func makeSentenceStudyProgress(from progress: LocalSentenceStudyProgress) -> SentenceStudyProgress {
        SentenceStudyProgress(
            id: progress.id,
            sentenceID: progress.sentenceID,
            learningStep: progress.learningStep,
            masteredReviewCount: progress.masteredReviewCount,
            correctCount: progress.correctCount,
            wrongCount: progress.wrongCount,
            lastResult: progress.lastResult,
            lastStudiedAt: progress.lastStudiedAt,
            nextReviewAt: progress.nextReviewDay
        )
    }

    private func currentFavoriteSentenceIDs() -> Set<UUID> {
        Set(
            memories.flatMap { memory in
                memory.sentences
                    .filter(\.isFavorite)
                    .map(\.id)
            }
        )
    }

    private func refreshLocalFavoriteSentenceStudyCounts(sentenceIDs: Set<UUID>? = nil) {
        let favoriteSentenceIDs = sentenceIDs ?? currentFavoriteSentenceIDs()
        favoriteSentenceStudyCounts = favoriteSentenceIDs.reduce(into: [:]) { partialResult, sentenceID in
            partialResult[sentenceID] = localProgress(for: sentenceID, topic: .favorites)?.correctCount ?? 0
        }
    }

    private func localMasteredSentenceCount() -> Int {
        Set(
            localSentenceStudyProgress.values.compactMap { progress in
                progress.correctCount >= 5 ? progress.sentenceID : nil
            }
        ).count
    }

    private func localStudiedTodayCount(today: Date) -> Int {
        localSentenceStudyProgress.values.filter { progress in
            guard let lastStudiedDay = progress.lastStudiedAt ?? progress.lastStudiedDay else { return false }
            return isSameLocalStudyDay(lastStudiedDay, today)
        }.count
    }

    private func localStudyDay(for date: Date = .now) -> Date {
        StudyCalendar.calendar().startOfDay(for: date)
    }

    private func isSameLocalStudyDay(_ lhs: Date, _ rhs: Date) -> Bool {
        StudyCalendar.calendar().isDate(lhs, inSameDayAs: rhs)
    }

    private func localNextReviewDay(after today: Date, learningStep: Int) -> Date {
        let daysToAdd: Int
        switch learningStep {
        case 1:
            daysToAdd = 1
        case 2:
            daysToAdd = 2
        case 3:
            daysToAdd = 4
        case 4:
            daysToAdd = 7
        default:
            daysToAdd = 14
        }
        return StudyCalendar.calendar().date(byAdding: .day, value: daysToAdd, to: today) ?? today
    }

    private func localMasteredNextReviewDay(after today: Date, masteredReviewCount: Int) -> Date {
        let daysToAdd = masteredReviewCount == 1 ? 30 : 60
        return StudyCalendar.calendar().date(byAdding: .day, value: daysToAdd, to: today) ?? today
    }
}

private struct LocalSentenceStudyCandidate {
    let item: SentenceStudyQueueItem
    let priority: Int
    let nextReviewDay: Date
    let createdAt: Date
    let lastStudiedAt: Date?
}
