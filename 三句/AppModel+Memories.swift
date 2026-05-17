import Foundation

private struct PreparedGenerationImages {
    let originalImageData: Data
    let analysisImageData: Data
    let memoryImageData: Data
}

private struct GenerationRequestContext {
    var session: SupabaseSession
    let existingMemoryIDs: Set<UUID>
    let guestJobID: String?
    let clientRequestID: String?
}

private enum GenerationRequestOutcome {
    case generated(SupabaseGenerateMemoryResult, SupabaseSession)
    case recovered(MemoryEntry, SupabaseSession)
}

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

    private var recoveryRequestTimeout: Duration {
        .seconds(12)
    }

    private var pendingGeneratedRecoveryExpirationInterval: TimeInterval {
        24 * 60 * 60
    }

    func generateMemory(from imageData: Data) async throws -> MemoryEntry {
        guard remainingCredits > 0 else {
            throw KimiServiceError.noCredits
        }

        try consumeGenerationAttemptIfAllowed()

        let images = try prepareGenerationImages(from: imageData)
        let context = try await prepareGenerationRequestContext(memoryImageData: images.memoryImageData)

        switch try await performGenerationRequest(images: images, context: context) {
        case let .generated(result, session):
            let memory = makeGeneratedMemory(
                from: result,
                memoryImageData: images.memoryImageData,
                isAnonymous: session.isAnonymous
            )
            await finalizeGeneratedMemory(
                memory,
                originalImageData: images.originalImageData,
                remainingCredits: result.remainingCredits,
                session: session
            )
            return memory

        case let .recovered(memory, _):
            return memory
        }
    }

    private func prepareGenerationImages(from imageData: Data) throws -> PreparedGenerationImages {
        PreparedGenerationImages(
            originalImageData: imageData,
            analysisImageData: try ImageCompressor.analysisJPEGData(from: imageData),
            memoryImageData: try ImageCompressor.memoryJPEGData(from: imageData)
        )
    }

    private func prepareGenerationRequestContext(memoryImageData: Data) async throws -> GenerationRequestContext {
        let session = try await ensureValidSession()
        let existingMemoryIDs = Set(memories.map(\.id))
        let guestJobID = session.isAnonymous ? UUID().uuidString.lowercased() : nil
        let clientRequestID = UUID().uuidString.lowercased()

        pendingGeneratedMemoryImage = PendingGeneratedMemoryImage(
            startedAt: .now,
            previousMemoryIDs: Array(existingMemoryIDs),
            guestJobID: guestJobID,
            clientRequestID: clientRequestID,
            imageData: memoryImageData
        )
        persistPendingGeneratedMemoryImage()

        return GenerationRequestContext(
            session: session,
            existingMemoryIDs: existingMemoryIDs,
            guestJobID: guestJobID,
            clientRequestID: clientRequestID
        )
    }

    private func performGenerationRequest(
        images: PreparedGenerationImages,
        context: GenerationRequestContext
    ) async throws -> GenerationRequestOutcome {
        do {
            let result = try await requestGeneratedMemorySentences(
                session: context.session,
                imageData: images.analysisImageData,
                guestJobID: context.guestJobID,
                clientRequestID: context.clientRequestID
            )
            return .generated(result, context.session)
        } catch {
            if isInvalidJWTGenerationError(error) {
                return try await retryGenerationAfterRefreshingSession(
                    images: images,
                    context: context
                )
            }

            if let recoveredMemory = await recoverGeneratedMemoryIfNeeded(
                after: error,
                previousMemoryIDs: context.existingMemoryIDs,
                session: context.session
            ) {
                let reconciledMemory = await finalizeRecoveredGeneratedMemory(
                    recoveredMemory,
                    originalImageData: images.originalImageData,
                    memoryImageData: images.memoryImageData,
                    session: context.session
                )
                return .recovered(reconciledMemory, context.session)
            }

            clearPendingGeneratedMemoryImageIfRecoveryIsNotNeeded(for: error)
            throw error
        }
    }

    private func retryGenerationAfterRefreshingSession(
        images: PreparedGenerationImages,
        context: GenerationRequestContext
    ) async throws -> GenerationRequestOutcome {
        let refreshedSession = try await forceRefreshSession()

        do {
            let result = try await requestGeneratedMemorySentences(
                session: refreshedSession,
                imageData: images.analysisImageData,
                guestJobID: context.guestJobID,
                clientRequestID: context.clientRequestID
            )
            return .generated(result, refreshedSession)
        } catch {
            clearPendingGeneratedMemoryImageIfRecoveryIsNotNeeded(for: error)
            throw error
        }
    }

    private func requestGeneratedMemorySentences(
        session: SupabaseSession,
        imageData: Data,
        guestJobID: String?,
        clientRequestID: String?
    ) async throws -> SupabaseGenerateMemoryResult {
        try await supabaseService.generateMemorySentences(
            session: session,
            imageData: imageData,
            englishLevel: englishLevel,
            languageStyle: languageStyle,
            guestJobID: guestJobID,
            clientRequestID: clientRequestID
        )
    }

    private func isInvalidJWTGenerationError(_ error: Error) -> Bool {
        guard case let SupabaseServiceError.apiError(message) = error else { return false }
        return message.localizedCaseInsensitiveContains("invalid jwt")
    }

    private func clearPendingGeneratedMemoryImageIfRecoveryIsNotNeeded(for error: Error) {
        if !shouldAttemptGenerationRecovery(for: error) {
            clearPendingGeneratedMemoryImage()
        }
    }

    func hasPendingGeneratedMemoryRecoveryCandidate() -> Bool {
        guard let pendingGeneratedMemoryImage,
              !isPendingGeneratedRecoveryExpired(pendingGeneratedMemoryImage) else {
            return false
        }

        return pendingGeneratedMemoryImage.guestJobID?.isEmpty == false ||
            pendingGeneratedMemoryImage.clientRequestID != nil
    }

    private func finalizeRecoveredGeneratedMemory(
        _ recoveredMemory: MemoryEntry,
        originalImageData: Data,
        memoryImageData: Data,
        session: SupabaseSession
    ) async -> MemoryEntry {
        let reconciledMemory = MemoryEntry(
            id: recoveredMemory.id,
            createdAt: recoveredMemory.createdAt,
            imageData: memoryImageData,
            remoteImagePath: recoveredMemory.remoteImagePath,
            syncedToAccount: !session.isAnonymous,
            sentences: recoveredMemory.sentences
        )

        if let recoveredIndex = memories.firstIndex(where: { $0.id == recoveredMemory.id }) {
            memories[recoveredIndex] = reconciledMemory
            persistMemories()
        }

        enqueuePendingMemoryImageUploadIfNeeded(
            memoryID: reconciledMemory.id,
            remoteImagePath: reconciledMemory.remoteImagePath,
            imageData: memoryImageData
        )
        await uploadMemoryImageIfNeeded(
            memoryID: reconciledMemory.id,
            remoteImagePath: reconciledMemory.remoteImagePath,
            imageData: memoryImageData,
            session: session
        )

        draftLearningImageData = originalImageData
        draftGeneratedMemory = reconciledMemory
        draftGeneratedMemoryID = reconciledMemory.id
        upsertPendingGuestMemoryMigrationIfNeeded(reconciledMemory)
        clearPendingGeneratedMemoryImage()
        return reconciledMemory
    }

    private func makeGeneratedMemory(
        from generationResult: SupabaseGenerateMemoryResult,
        memoryImageData: Data,
        isAnonymous: Bool
    ) -> MemoryEntry {
        if isAnonymous {
            let localSentences = generationResult.memory.sentences.map { sentence in
                SentenceRecord(
                    id: UUID(),
                    english: sentence.english,
                    chinese: sentence.chinese,
                    isFavorite: sentence.isFavorite
                )
            }
            return MemoryEntry(
                id: UUID(),
                createdAt: generationResult.memory.createdAt,
                imageData: memoryImageData,
                remoteImagePath: nil,
                syncedToAccount: false,
                sentences: localSentences
            )
        }

        return MemoryEntry(
            id: generationResult.memory.id,
            createdAt: generationResult.memory.createdAt,
            imageData: memoryImageData,
            remoteImagePath: generationResult.memory.remoteImagePath,
            syncedToAccount: true,
            sentences: generationResult.memory.sentences
        )
    }

    private func finalizeGeneratedMemory(
        _ memory: MemoryEntry,
        originalImageData: Data,
        remainingCredits updatedRemainingCredits: Int,
        session: SupabaseSession
    ) async {
        memories.removeAll { $0.id == memory.id }
        memories.insert(memory, at: 0)
        memories = memories.deduplicatedByMemoryID()
        recordedMemoriesCount = memories.count
        draftLearningImageData = originalImageData
        draftGeneratedMemory = memory
        draftGeneratedMemoryID = memory.id
        remainingCredits = updatedRemainingCredits
        upsertPendingGuestMemoryMigrationIfNeeded(memory)
        persistMemories()
        persistCredits()
        clearPendingGeneratedMemoryImage()

        guard !session.isAnonymous else { return }
        enqueuePendingMemoryImageUploadIfNeeded(
            memoryID: memory.id,
            remoteImagePath: memory.remoteImagePath,
            imageData: memory.imageData
        )
        await uploadMemoryImageIfNeeded(
            memoryID: memory.id,
            remoteImagePath: memory.remoteImagePath,
            imageData: memory.imageData,
            session: session
        )
    }

    func clearLearningDraft() {
        draftLearningImageData = nil
        draftLearningItemIdentifier = nil
        draftGeneratedMemory = nil
        draftGeneratedMemoryID = nil
    }

    func ensureMemoryImageLoaded(memoryID: UUID) async {
        guard let memoryIndex = memories.firstIndex(where: { $0.id == memoryID }) else {
            return
        }

        let memory = memories[memoryIndex]
        guard memory.imageData.isEmpty, let remoteImagePath = memory.remoteImagePath else {
            return
        }

        guard !memoryImageLoadTaskIDs.contains(memoryID) else {
            return
        }
        memoryImageLoadTaskIDs.insert(memoryID)
        defer {
            memoryImageLoadTaskIDs.remove(memoryID)
        }

        guard let session = try? await ensureValidSession() else {
            return
        }

        do {
            let downloadedImageData = try await supabaseService.downloadMemoryImage(
                session: session,
                path: remoteImagePath
            )

            guard let refreshedIndex = memories.firstIndex(where: { $0.id == memoryID }) else {
                return
            }

            memories[refreshedIndex] = MemoryEntry(
                id: memories[refreshedIndex].id,
                createdAt: memories[refreshedIndex].createdAt,
                imageData: downloadedImageData,
                remoteImagePath: remoteImagePath,
                syncedToAccount: memories[refreshedIndex].syncedToAccount,
                sentences: memories[refreshedIndex].sentences
            )
            persistMemories()
        } catch {
            return
        }
    }

    func toggleFavorite(sentenceID: UUID) {
        guard let location = locateSentence(sentenceID) else { return }
        memories[location.memoryIndex].sentences[location.sentenceIndex].isFavorite.toggle()
        let isFavorite = memories[location.memoryIndex].sentences[location.sentenceIndex].isFavorite
        favoriteSentencesCount += isFavorite ? 1 : -1
        persistMemories()
        guard isSignedIn else {
            Task { await refreshSentenceStudyDueCount() }
            return
        }
        Task {
            let didSync = await syncFavorite(sentenceID: sentenceID, isFavorite: isFavorite)
            if didSync {
                clearPendingFavoriteChange(sentenceID: sentenceID, isFavorite: isFavorite)
                await refreshSentenceStudyDueCount()
            } else {
                queuePendingFavoriteChange(sentenceID: sentenceID, isFavorite: isFavorite)
                authErrorMessage = L10n.string("sync.favorite.failed", "收藏状态同步失败，会在下次同步时重试。")
            }
        }
    }

    func deleteFavorite(sentenceID: UUID) {
        guard let location = locateSentence(sentenceID) else { return }
        memories[location.memoryIndex].sentences[location.sentenceIndex].isFavorite = false
        favoriteSentencesCount = max(0, favoriteSentencesCount - 1)
        persistMemories()
        guard isSignedIn else {
            Task { await refreshSentenceStudyDueCount() }
            return
        }
        Task {
            let didSync = await syncFavorite(sentenceID: sentenceID, isFavorite: false)
            if didSync {
                clearPendingFavoriteChange(sentenceID: sentenceID, isFavorite: false)
                await refreshSentenceStudyDueCount()
            } else {
                queuePendingFavoriteChange(sentenceID: sentenceID, isFavorite: false)
                authErrorMessage = L10n.string("sync.unfavorite.failed", "取消收藏失败，会在下次同步时重试。")
            }
        }
    }

    func deleteMemory(memoryID: UUID) {
        let deletedMemory = memories.first(where: { $0.id == memoryID })
        let imagePath = deletedMemory?.remoteImagePath
        let removedFavoriteCount = deletedMemory?.sentences.filter(\.isFavorite).count ?? 0
        removePendingMemoryImageUpload(memoryID: memoryID)
        memories.removeAll { $0.id == memoryID }
        recordedMemoriesCount = memories.count
        favoriteSentencesCount = max(0, favoriteSentencesCount - removedFavoriteCount)
        if let deletedMemory, deletedMemory.syncedToAccount {
            queuePendingMemoryDeletion(memoryID: memoryID, remoteImagePath: imagePath)
        }
        persistMemories()
        guard isSignedIn else {
            Task { await refreshSentenceStudyDueCount() }
            return
        }
        Task {
            let didSync = await syncDeleteMemory(memoryID: memoryID, imagePath: imagePath)
            if didSync {
                pendingMemoryDeletions.removeAll { $0.memoryID == memoryID }
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
        if let remoteContentRefreshTask {
            await remoteContentRefreshTask.value
            return
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.remoteContentRefreshTask = nil }
            await self.performRemoteContentRefresh()
        }

        remoteContentRefreshTask = task
        await task.value
    }

    private func performRemoteContentRefresh() async {
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

        if session.isAnonymous {
            refreshLocalSentenceStudyCounts()
            await syncMemoriesFromRemote(refreshCounts: true)
            return
        }

        if let migratedProfile = await retryPendingGuestCreditMigrationIfNeeded(for: session) {
            applyRemoteProfile(
                migratedProfile,
                fallbackAppleUserID: profile?.appleUserID ?? "",
                treatAsGuest: session.isAnonymous
            )
            persistProfile()
            persistCredits()
        } else if let remoteProfile = try? await supabaseService.fetchProfile(session: session) {
            applyRemoteProfile(
                remoteProfile,
                fallbackAppleUserID: profile?.appleUserID ?? "",
                treatAsGuest: session.isAnonymous
            )
            persistProfile()
            persistCredits()
        }

        await syncMemoriesFromRemote(refreshCounts: true)
        await syncPendingCloudChangesIfNeeded()
        await syncMemoriesFromRemote(refreshCounts: true)
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
        if let remoteMemoriesSyncTask {
            await remoteMemoriesSyncTask.value
            if !downloadsImages || !memories.contains(where: \.imageData.isEmpty) {
                return
            }
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.remoteMemoriesSyncTask = nil }
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
        guard let session = try? await ensureValidSession() else { return }

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
            persistMemories()
            return
        }

        isSyncingRemoteMemories = true
        defer { isSyncingRemoteMemories = false }

        do {
            let remoteRecords = try await supabaseService.fetchMemories(session: session)
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
                    sentences: sentences
                )
            }
            .filter { isMemoryContentComplete($0) }

            var loadedMemories = remoteMemories
            var localMemoriesToKeep = memories.filter { memory in
                isMemoryContentComplete(memory) && !memory.syncedToAccount
            }

            if !session.isAnonymous {
                for queuedMemory in pendingGuestMemoryMigrationQueue
                    .filter(isMemoryContentComplete)
                    .sorted(by: { $0.createdAt > $1.createdAt }) {
                    let alreadyQueuedLocally = localMemoriesToKeep.contains { localMemory in
                        matchesMemoryIdentity(localMemory, queuedMemory)
                    }

                    if !alreadyQueuedLocally {
                        localMemoriesToKeep.append(queuedMemory)
                    }
                }
            }

            for localMemory in localMemoriesToKeep {
                let alreadyLoadedRemotely = remoteMemories.contains { remoteMemory in
                    matchesMemoryIdentity(remoteMemory, localMemory)
                }

                if !alreadyLoadedRemotely {
                    loadedMemories.append(localMemory)
                }
            }

            loadedMemories = loadedMemories
                .deduplicatedByMemoryID()
                .sorted { $0.createdAt > $1.createdAt }
            await reconcilePendingGeneratedMemoryImage(with: &loadedMemories, session: session)
            guard isSessionStillCurrent(session) else { return }
            memories = loadedMemories
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
            persistMemories()
            await MemoryWidgetSnapshotStore.refreshImmediately(with: loadedMemories)
        } catch {
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
        guard cappedVisibleCount > 0 else { return hydratedMemories }
        var downloadedImageCount = 0

        for index in hydratedMemories.indices {
            guard index < cappedVisibleCount else { break }
            guard shouldHydrateRemoteImage(hydratedMemories[index]) else { continue }
            guard let remoteImagePath = hydratedMemories[index].remoteImagePath else { continue }

            do {
                let downloadedImageData = try await supabaseService.downloadMemoryImage(
                    session: session,
                    path: remoteImagePath
                )
                hydratedMemories[index] = MemoryEntry(
                    id: hydratedMemories[index].id,
                    createdAt: hydratedMemories[index].createdAt,
                    imageData: downloadedImageData,
                    remoteImagePath: remoteImagePath,
                    syncedToAccount: hydratedMemories[index].syncedToAccount,
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
                sentences: currentMemory.sentences
            )
            didUpdate = true
        }

        return didUpdate
    }

    private func shouldHydrateRemoteImage(_ memory: MemoryEntry) -> Bool {
        memory.imageData.isEmpty && memory.remoteImagePath != nil
    }

    private func isSessionStillCurrent(_ session: SupabaseSession) -> Bool {
        guard let currentSession = supabaseSession else { return false }
        return currentSession.userID == session.userID && currentSession.isAnonymous == session.isAnonymous
    }

    func matchesMemoryIdentity(_ lhs: MemoryEntry, _ rhs: MemoryEntry) -> Bool {
        MemoryIdentity.matches(lhs, rhs)
    }

    func syncFavorite(sentenceID: UUID, isFavorite: Bool) async -> Bool {
        guard let session = try? await ensureValidSession() else { return false }

        do {
            try await supabaseService.updateSentenceFavorite(session: session, sentenceID: sentenceID, isFavorite: isFavorite)
            return true
        } catch {
            return false
        }
    }

    func recoverGeneratedMemoryIfNeeded(
        after error: Error,
        previousMemoryIDs: Set<UUID>,
        session: SupabaseSession
    ) async -> MemoryEntry? {
        guard shouldAttemptGenerationRecovery(for: error) else {
            return nil
        }

        if session.isAnonymous, pendingGeneratedMemoryImage?.guestJobID?.isEmpty == false {
            return await recoverAnonymousGeneratedMemoryIfNeeded(
                previousMemoryIDs: previousMemoryIDs,
                session: session
            )
        }

        if !session.isAnonymous, let clientRequestID = pendingGeneratedMemoryImage?.clientRequestID {
            return await recoverAuthenticatedGeneratedMemoryIfNeeded(
                clientRequestID: clientRequestID,
                previousMemoryIDs: previousMemoryIDs,
                session: session,
                retryDelays: [
                    .milliseconds(800),
                    .seconds(2),
                    .seconds(3),
                    .seconds(4)
                ]
            )
        }

        let retryDelays: [Duration] = [
            .milliseconds(800),
            .seconds(2),
            .seconds(3),
            .seconds(4)
        ]

        for delay in retryDelays {
            try? await Task.sleep(for: delay)
            let didRefresh = await runRecoveryAttemptWithTimeout {
                await self.syncMemoriesFromRemote(refreshCounts: true)
            }
            guard didRefresh else { continue }

            if let remoteProfile = await fetchProfileForRecovery(session: session) {
                applyRemoteProfile(
                    remoteProfile,
                    fallbackAppleUserID: profile?.appleUserID ?? "",
                    treatAsGuest: session.isAnonymous
                )
                persistProfile()
                persistCredits()
            }

            if let recoveredMemory = firstRecoveredMemory(after: previousMemoryIDs) {
                return recoveredMemory
            }
        }

        return nil
    }

    func resumePendingGeneratedMemoryRecoveryIfNeeded() async -> MemoryEntry? {
        guard let pendingRecovery = pendingGeneratedMemoryImage else { return nil }
        guard !isPendingGeneratedRecoveryExpired(pendingRecovery) else {
            clearPendingGeneratedMemoryImage()
            return nil
        }

        let previousMemoryIDs = Set(pendingRecovery.previousMemoryIDs)
        guard let session = try? await ensureValidSession() else { return nil }
        if session.isAnonymous {
            let recoveredMemory = await recoverAnonymousGeneratedMemoryIfNeeded(
                previousMemoryIDs: previousMemoryIDs,
                session: session
            )
            return finalizeExplicitPendingRecoveryResult(recoveredMemory)
        }

        if let clientRequestID = pendingRecovery.clientRequestID {
            let recoveredMemory = await recoverAuthenticatedGeneratedMemoryIfNeeded(
                clientRequestID: clientRequestID,
                previousMemoryIDs: previousMemoryIDs,
                session: session,
                retryDelays: [
                    .zero,
                    .seconds(5),
                    .seconds(10),
                    .seconds(20)
                ]
            )
            return finalizeExplicitPendingRecoveryResult(recoveredMemory)
        }

        let retryDelays: [Duration] = [
            .zero,
            .seconds(5),
            .seconds(10),
            .seconds(20)
        ]

        for delay in retryDelays {
            if delay != .zero {
                try? await Task.sleep(for: delay)
            }

            let didRefresh = await runRecoveryAttemptWithTimeout {
                await self.syncMemoriesFromRemote(refreshCounts: true, downloadsImages: false)
            }
            guard didRefresh else { continue }

            if let recoveredMemory = firstRecoveredMemory(after: previousMemoryIDs) {
                return finalizeExplicitPendingRecoveryResult(recoveredMemory)
            }
        }

        return finalizeExplicitPendingRecoveryResult(nil)
    }

    private func finalizeExplicitPendingRecoveryResult(_ recoveredMemory: MemoryEntry?) -> MemoryEntry? {
        guard let recoveredMemory else {
            clearPendingGeneratedMemoryImage()
            return nil
        }

        return recoveredMemory
    }

    private func recoverAuthenticatedGeneratedMemoryIfNeeded(
        clientRequestID: String,
        previousMemoryIDs: Set<UUID>,
        session: SupabaseSession,
        retryDelays: [Duration]
    ) async -> MemoryEntry? {
        guard !clientRequestID.isEmpty else { return nil }

        for delay in retryDelays {
            if delay != .zero {
                try? await Task.sleep(for: delay)
            }

            guard let job = await fetchGenerationJobForRecovery(
                session: session,
                clientRequestID: clientRequestID
            ) else {
                continue
            }

            switch job.status {
            case "completed":
                if let remainingCredits = job.remainingCredits {
                    self.remainingCredits = remainingCredits
                    persistCredits()
                }

                guard let memoryIDString = job.memoryID,
                      let memoryID = UUID(uuidString: memoryIDString) else {
                    continue
                }

                let didRefresh = await runRecoveryAttemptWithTimeout {
                    await self.syncMemoriesFromRemote(refreshCounts: true, downloadsImages: false)
                }
                guard didRefresh else { continue }

                if let recoveredMemory = memory(withID: memoryID) {
                    return recoveredMemory
                }

                if let recoveredMemory = firstRecoveredMemory(after: previousMemoryIDs) {
                    return recoveredMemory
                }

            case "failed":
                clearPendingGeneratedMemoryImage()
                return nil

            default:
                continue
            }
        }

        return nil
    }

    private func fetchGenerationJobForRecovery(
        session: SupabaseSession,
        clientRequestID: String
    ) async -> SupabaseGenerationJobRecord? {
        await withTaskGroup(of: SupabaseGenerationJobRecord?.self) { group in
            group.addTask {
                try? await self.supabaseService.fetchGenerationJob(
                    session: session,
                    clientRequestID: clientRequestID
                )
            }

            group.addTask { [recoveryRequestTimeout] in
                try? await Task.sleep(for: recoveryRequestTimeout)
                return nil
            }

            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    private func recoverAnonymousGeneratedMemoryIfNeeded(
        previousMemoryIDs: Set<UUID>,
        session: SupabaseSession
    ) async -> MemoryEntry? {
        guard let pendingRecovery = pendingGeneratedMemoryImage else { return nil }
        guard !isPendingGeneratedRecoveryExpired(pendingRecovery) else {
            clearPendingGeneratedMemoryImage()
            return nil
        }
        guard let guestJobID = pendingRecovery.guestJobID, !guestJobID.isEmpty else { return nil }

        let retryDelays: [Duration] = [
            .zero,
            .seconds(5),
            .seconds(10),
            .seconds(20)
        ]

        for delay in retryDelays {
            if delay != .zero {
                try? await Task.sleep(for: delay)
            }

            guard let recovered = await recoverGuestGenerationForRecovery(
                session: session,
                imageData: pendingRecovery.imageData,
                guestJobID: guestJobID
            ) else {
                continue
            }

            if let existingIndex = memories.firstIndex(where: {
                !previousMemoryIDs.contains($0.id) && matchesMemoryIdentity($0, recovered.memory)
            }) {
                memories[existingIndex] = recovered.memory
            } else {
                memories.insert(recovered.memory, at: 0)
            }

            recordedMemoriesCount = memories.count
            favoriteSentencesCount = memories.reduce(into: 0) { partialResult, memory in
                partialResult += memory.sentences.filter(\.isFavorite).count
            }
            remainingCredits = recovered.remainingCredits
            upsertPendingGuestMemoryMigrationIfNeeded(recovered.memory)
            persistMemories()
            persistCredits()
            return recovered.memory
        }

        return nil
    }

    private func firstRecoveredMemory(after previousMemoryIDs: Set<UUID>) -> MemoryEntry? {
        memories.first(where: {
            !previousMemoryIDs.contains($0.id) && isMemoryContentComplete($0)
        })
    }

    func isMemoryContentComplete(_ memory: MemoryEntry) -> Bool {
        MemoryIdentity.isContentComplete(memory)
    }

    func shouldAttemptGenerationRecovery(for error: Error) -> Bool {
        switch error.generationRecoveryDisposition {
        case .recoverable:
            return true
        case .nonRecoverable, .unknown:
            return false
        }
    }

    func isPendingGeneratedRecoveryExpired(_ pendingRecovery: PendingGeneratedMemoryImage) -> Bool {
        Date().timeIntervalSince(pendingRecovery.startedAt) > pendingGeneratedRecoveryExpirationInterval
    }

    private func runRecoveryAttemptWithTimeout(
        operation: @escaping @Sendable () async -> Void
    ) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await operation()
                return true
            }

            group.addTask { [recoveryRequestTimeout] in
                try? await Task.sleep(for: recoveryRequestTimeout)
                return false
            }

            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }

    private func fetchProfileForRecovery(session: SupabaseSession) async -> SupabaseProfileRecord? {
        let result = await withTaskGroup(of: SupabaseProfileRecord?.self) { group in
            group.addTask {
                try? await self.supabaseService.fetchProfile(session: session)
            }

            group.addTask { [recoveryRequestTimeout] in
                try? await Task.sleep(for: recoveryRequestTimeout)
                return nil
            }

            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }

        return result
    }

    private func recoverGuestGenerationForRecovery(
        session: SupabaseSession,
        imageData: Data,
        guestJobID: String
    ) async -> SupabaseGuestGenerationRecoveryResult? {
        let result = await withTaskGroup(of: SupabaseGuestGenerationRecoveryResult?.self) { group in
            group.addTask {
                try? await self.supabaseService.recoverGuestGeneration(
                    session: session,
                    imageData: imageData,
                    guestJobID: guestJobID
                )
            }

            group.addTask { [recoveryRequestTimeout] in
                try? await Task.sleep(for: recoveryRequestTimeout)
                return nil
            }

            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }

        return result
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

        do {
            try await supabaseService.uploadMemoryImage(
                session: session,
                path: remoteImagePath,
                data: imageData
            )
            removePendingMemoryImageUpload(memoryID: memoryID)
        } catch {
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

    func clearPendingFavoriteChange(sentenceID: UUID, isFavorite: Bool? = nil) {
        let originalCount = pendingFavoriteChanges.count
        pendingFavoriteChanges.removeAll { change in
            guard change.sentenceID == sentenceID else { return false }
            guard let isFavorite else { return true }
            return change.isFavorite == isFavorite
        }
        guard pendingFavoriteChanges.count != originalCount else { return }
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
        guard isSignedIn else {
            refreshLocalSentenceStudyCounts()
            isRepeatingSentenceStudyQueue = false
            return
        }

        do {
            let session = try await ensureValidSession()
            guard !session.isAnonymous else {
                sentenceStudyDueCount = 0
                sentenceStudyTodayCount = 0
                sentenceStudyReviewableTodayCount = 0
                isRepeatingSentenceStudyQueue = false
                return
            }
            sentenceStudyDueCount = try await supabaseService.fetchSentenceStudyDueCount(session: session)
            sentenceStudyTodayCount = (try? await supabaseService.fetchSentenceStudyTodayCount(session: session)) ?? 0
            sentenceStudyReviewableTodayCount = (try? await supabaseService.fetchSentenceStudyReviewableTodayCount(session: session)) ?? 0
        } catch {
            sentenceStudyDueCount = 0
            sentenceStudyTodayCount = 0
            sentenceStudyReviewableTodayCount = 0
            isRepeatingSentenceStudyQueue = false
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

    func recordSentenceStudyCompletion(sentenceID: UUID) async throws -> SentenceStudyProgress {
        guard isSignedIn else {
            return recordLocalSentenceStudyCompletion(sentenceID: sentenceID)
        }

        let session = try await ensureValidSession()
        let progress = try await supabaseService.recordSentenceStudyResult(
            session: session,
            sentenceID: sentenceID,
            wasCorrect: true
        )
        sentenceStudyDueCount = max(0, sentenceStudyDueCount - 1)
        sentenceStudyTodayCount += 1
        sentenceStudyReviewableTodayCount += 1
        return progress
    }

    func loadSentenceStudyTodayReviewQueue() async throws -> [SentenceStudyQueueItem] {
        guard isSignedIn else {
            let reviewQueue = localSentenceStudyTodayReviewQueue(limit: max(sentenceStudyReviewableTodayCount, 1)).shuffled()
            sentenceStudyQueue = reviewQueue
            sentenceStudyReviewableTodayCount = reviewQueue.count
            isRepeatingSentenceStudyQueue = !reviewQueue.isEmpty
            return reviewQueue
        }

        let session = try await ensureValidSession()
        guard !session.isAnonymous else { return [] }

        let todayCount = (try? await supabaseService.fetchSentenceStudyTodayCount(session: session)) ?? sentenceStudyTodayCount
        let reviewableTodayCount = (try? await supabaseService.fetchSentenceStudyReviewableTodayCount(session: session)) ?? sentenceStudyReviewableTodayCount
        sentenceStudyTodayCount = todayCount
        sentenceStudyReviewableTodayCount = reviewableTodayCount
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

    private func recordLocalSentenceStudyCompletion(sentenceID: UUID) -> SentenceStudyProgress {
        let now = Date()
        let today = localStudyDay(for: now)
        var progress = localSentenceStudyProgress[sentenceID] ?? LocalSentenceStudyProgress(
            sentenceID: sentenceID,
            nextReviewDay: today
        )

        if let lastStudiedDay = progress.lastStudiedDay,
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

        localSentenceStudyProgress[sentenceID] = progress
        persistLocalSentenceStudyProgress()
        refreshLocalSentenceStudyCounts()
        return makeSentenceStudyProgress(from: progress)
    }

    private func localSentenceStudyDueQueue(limit: Int, today: Date? = nil) -> [SentenceStudyQueueItem] {
        let studyDay = today ?? localStudyDay()
        let remainingSlots = max(SentenceStudyPolicy.dailyLimit - localStudiedTodayCount(today: studyDay), 0)
        guard remainingSlots > 0 else { return [] }

        return localSentenceStudyCandidates(today: studyDay)
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
            .prefix(min(max(limit, 0), remainingSlots, SentenceStudyPolicy.dailyLimit))
            .map(\.item)
    }

    private func localSentenceStudyTodayReviewQueue(limit: Int, today: Date? = nil) -> [SentenceStudyQueueItem] {
        let studyDay = today ?? localStudyDay()

        return memories
            .flatMap { memory in
                memory.sentences
                    .filter { $0.isFavorite }
                    .compactMap { sentence -> LocalSentenceStudyCandidate? in
                        guard let progress = localSentenceStudyProgress[sentence.id],
                              let lastStudiedDay = progress.lastStudiedDay,
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

    private func localSentenceStudyCandidates(today: Date) -> [LocalSentenceStudyCandidate] {
        memories
            .sorted { $0.createdAt > $1.createdAt }
            .flatMap { memory in
                memory.sentences
                    .filter(\.isFavorite)
                    .map { sentence -> LocalSentenceStudyCandidate in
                        let progress = localSentenceStudyProgress[sentence.id]
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
        if let lastStudiedDay = progress.lastStudiedDay,
           isSameLocalStudyDay(lastStudiedDay, today) {
            return 99
        }
        guard progress.nextReviewDay <= today else { return 99 }
        return progress.learningStep < 5 ? 1 : 3
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

    private func localStudiedTodayCount(today: Date) -> Int {
        localSentenceStudyProgress.values.filter { progress in
            guard let lastStudiedDay = progress.lastStudiedDay else { return false }
            return isSameLocalStudyDay(lastStudiedDay, today)
        }.count
    }

    private func localStudyDay(for date: Date = .now) -> Date {
        Calendar.current.startOfDay(for: date)
    }

    private func isSameLocalStudyDay(_ lhs: Date, _ rhs: Date) -> Bool {
        Calendar.current.isDate(lhs, inSameDayAs: rhs)
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
        return Calendar.current.date(byAdding: .day, value: daysToAdd, to: today) ?? today
    }

    private func localMasteredNextReviewDay(after today: Date, masteredReviewCount: Int) -> Date {
        let daysToAdd = masteredReviewCount == 1 ? 30 : 60
        return Calendar.current.date(byAdding: .day, value: daysToAdd, to: today) ?? today
    }
}

private struct LocalSentenceStudyCandidate {
    let item: SentenceStudyQueueItem
    let priority: Int
    let nextReviewDay: Date
    let createdAt: Date
    let lastStudiedAt: Date?
}
