import Foundation

enum CachedMemoryImageLoadingMode: Equatable {
    case immediateForAll
    case deferRemoteBacked
}

private enum MemoryImagePersistenceStore {
    private struct ImageFile {
        let memoryID: UUID
        let imageData: Data
    }

    private static let queue = DispatchQueue(
        label: "com.yanglv.sanju.memory-image-persistence",
        qos: .utility
    )

    static func schedulePersist(memories: [MemoryEntry]) {
        let imageFiles = memories.map { memory in
            ImageFile(memoryID: memory.id, imageData: memory.imageData)
        }

        queue.async {
            persist(imageFiles: imageFiles)
        }
    }

    static func persistImmediately(memories: [MemoryEntry]) {
        let imageFiles = memories.map { memory in
            ImageFile(memoryID: memory.id, imageData: memory.imageData)
        }

        persist(imageFiles: imageFiles)
    }

    private static func persist(imageFiles: [ImageFile]) {
        let fileManager = FileManager.default
        let directoryURL = memoryImageDirectoryURL()

        PersistenceDiagnostics.createDirectory(at: directoryURL, operation: "Create memory image directory")

        let validFileNames = Set(imageFiles.map { memoryImageFileName(for: $0.memoryID) })
        if let existingFiles = PersistenceDiagnostics.contentsOfDirectory(
            at: directoryURL,
            operation: "List memory image directory"
        ) {
            for fileURL in existingFiles where !validFileNames.contains(fileURL.lastPathComponent) {
                PersistenceDiagnostics.removeItem(at: fileURL, operation: "Remove stale memory image")
            }
        }

        for imageFile in imageFiles where !imageFile.imageData.isEmpty {
            let fileURL = directoryURL.appendingPathComponent(memoryImageFileName(for: imageFile.memoryID))
            guard !fileManager.fileExists(atPath: fileURL.path) else { continue }
            PersistenceDiagnostics.writeData(imageFile.imageData, to: fileURL, operation: "Write memory image")
        }
    }

    private static func memoryImageDirectoryURL() -> URL {
        persistentImageDirectoryURL(named: "SanjuMemoryImages")
    }

    private static func persistentImageDirectoryURL(named directoryName: String) -> URL {
        let fileManager = FileManager.default
        let supportRootURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sanju", isDirectory: true)
        let targetURL = supportRootURL.appendingPathComponent(directoryName, isDirectory: true)
        let legacyURL = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(directoryName, isDirectory: true)

        PersistenceDiagnostics.createDirectory(at: supportRootURL, operation: "Create support root directory")

        guard fileManager.fileExists(atPath: legacyURL.path) else {
            return targetURL
        }

        if !fileManager.fileExists(atPath: targetURL.path) {
            PersistenceDiagnostics.moveItem(at: legacyURL, to: targetURL, operation: "Move legacy image directory")
            return targetURL
        }

        if let legacyFiles = PersistenceDiagnostics.contentsOfDirectory(
            at: legacyURL,
            operation: "List legacy image directory"
        ) {
            PersistenceDiagnostics.createDirectory(at: targetURL, operation: "Create migrated image directory")
            for fileURL in legacyFiles {
                let destinationURL = targetURL.appendingPathComponent(fileURL.lastPathComponent)
                guard !fileManager.fileExists(atPath: destinationURL.path) else { continue }
                PersistenceDiagnostics.moveItem(at: fileURL, to: destinationURL, operation: "Move legacy image file")
            }
        }
        PersistenceDiagnostics.removeItem(at: legacyURL, operation: "Remove legacy image directory")
        return targetURL
    }

    private static func memoryImageFileName(for memoryID: UUID) -> String {
        "\(memoryID.uuidString.lowercased()).jpg"
    }
}

extension AppModel {
    private static let memoryWidgetSnapshotDebounceNanoseconds: UInt64 = 500_000_000

    private struct PersistedMemoryEntry: Codable {
        let id: UUID
        let createdAt: Date
        let remoteImagePath: String?
        let syncedToAccount: Bool?
        let sentences: [SentenceRecord]
    }

    private struct PersistedPendingGeneratedMemoryImage: Codable {
        let startedAt: Date
        let previousMemoryIDs: [UUID]
        let guestJobID: String?
        let clientRequestID: String?
    }

    private struct PersistedPendingGuestMemoryMigrationEntry: Codable {
        let id: UUID
        let createdAt: Date
        let remoteImagePath: String?
        let syncedToAccount: Bool?
        let sentences: [SentenceRecord]
    }

    private struct CachedMemories {
        let memories: [MemoryEntry]
        let deferredImageMemoryIDs: [UUID]
    }

    private struct PendingLocalAccountTransition: Codable {
        enum Kind: String, Codable {
            case signOut
            case deleteAccountLocalClear = "deleteAccountLocalRestore"
        }

        let kind: Kind
        let userID: String?
        let credits: Int
        let memories: [PersistedMemoryEntry]
        let recordedMemoriesCount: Int
        let favoriteSentencesCount: Int
        let remoteDeletionConfirmed: Bool
        let createdAt: Date
    }

    func persistSession() {
        guard let supabaseSession else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = PersistenceDiagnostics.encode(
            supabaseSession,
            using: encoder,
            operation: "Encode Supabase session"
        ) {
            KeychainStorage.set(data, for: AppStorageKey.supabaseSession)
        }
    }

    func loadStoredSession() -> SupabaseSession? {
        guard let data = KeychainStorage.get(for: AppStorageKey.supabaseSession) else {
            return nil
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return PersistenceDiagnostics.decode(
            SupabaseSession.self,
            from: data,
            using: decoder,
            operation: "Decode Supabase session"
        )
    }

    func clearStoredSession() {
        supabaseSession = nil
        KeychainStorage.remove(for: AppStorageKey.supabaseSession)
    }

    func persistProfile() {
        let encoder = JSONEncoder()
        let data = PersistenceDiagnostics.encode(profile, using: encoder, operation: "Encode profile")
        defaults.set(data, forKey: AppStorageKey.profile)
    }

    func persistMemories() {
        persistMemories(for: currentMemoryCacheUserID)
    }

    func persistMemories(for userID: String?) {
        let encoder = JSONEncoder()
        let persistedMemories = memories.map {
            PersistedMemoryEntry(
                id: $0.id,
                createdAt: $0.createdAt,
                remoteImagePath: $0.remoteImagePath,
                syncedToAccount: $0.syncedToAccount,
                sentences: $0.sentences
            )
        }
        let data = PersistenceDiagnostics.encode(
            persistedMemories,
            using: encoder,
            operation: "Encode persisted memories"
        )
        defaults.set(data, forKey: AppStorageKey.memories)
        defaults.set(userID, forKey: AppStorageKey.memoriesUserID)
        MemoryImagePersistenceStore.schedulePersist(memories: memories)
        scheduleMemoryWidgetSnapshotUpdate(with: memories)
    }

    func beginPendingLocalSignOutTransaction() {
        persistPendingLocalAccountTransition(
            PendingLocalAccountTransition(
                kind: .signOut,
                userID: supabaseSession?.userID,
                credits: 0,
                memories: [],
                recordedMemoriesCount: 0,
                favoriteSentencesCount: 0,
                remoteDeletionConfirmed: false,
                createdAt: Date()
            )
        )
    }

    func completePendingLocalSignOutIfNeeded() {
        guard let pendingTransition = loadPendingLocalAccountTransition(),
              pendingTransition.kind == .signOut else {
            return
        }

        completeLocalSignOutTransaction()
    }

    func completeLocalSignOutTransaction() {
        resetLocalAccountState(resetCredits: false)
        clearLearningDraft()
        clearPersistedMemories()
        clearPendingGuestMemoryMigrationQueue()
        clearPendingGuestCreditMigration()
        clearLocalSentenceStudyProgress()
        remainingCredits = 0
        persistCredits()
        defaults.removeObject(forKey: AppStorageKey.preserveLocalGuestCreditsAgainstAnonymousProfile)
        clearPendingLocalAccountTransition()
    }

    func beginPendingDeleteAccountLocalClear(session: SupabaseSession) {
        persistPendingLocalAccountTransition(
            PendingLocalAccountTransition(
                kind: .deleteAccountLocalClear,
                userID: session.userID,
                credits: 0,
                memories: [],
                recordedMemoriesCount: 0,
                favoriteSentencesCount: 0,
                remoteDeletionConfirmed: false,
                createdAt: Date()
            )
        )
    }

    func markPendingDeleteAccountRemoteDeletionConfirmed(for userID: String) {
        guard let pendingTransition = loadPendingLocalAccountTransition(),
              pendingTransition.kind == .deleteAccountLocalClear,
              pendingTransition.userID == userID else {
            return
        }

        persistPendingLocalAccountTransition(
            PendingLocalAccountTransition(
                kind: pendingTransition.kind,
                userID: pendingTransition.userID,
                credits: pendingTransition.credits,
                memories: pendingTransition.memories,
                recordedMemoriesCount: pendingTransition.recordedMemoriesCount,
                favoriteSentencesCount: pendingTransition.favoriteSentencesCount,
                remoteDeletionConfirmed: true,
                createdAt: pendingTransition.createdAt
            )
        )
    }

    func completeRemoteConfirmedPendingDeleteAccountLocalClearIfNeeded() {
        guard let pendingTransition = loadPendingLocalAccountTransition(),
              pendingTransition.kind == .deleteAccountLocalClear,
              pendingTransition.remoteDeletionConfirmed else {
            return
        }

        completeLocalDeleteAccountClear()
    }

    @discardableResult
    func completePendingDeleteAccountLocalClearIfNeeded() -> Bool {
        guard let pendingTransition = loadPendingLocalAccountTransition(),
              pendingTransition.kind == .deleteAccountLocalClear else {
            return false
        }

        completeLocalDeleteAccountClear()
        return true
    }

    func clearPendingDeleteAccountLocalClearIfNeeded(for userID: String) {
        guard let pendingTransition = loadPendingLocalAccountTransition(),
              pendingTransition.kind == .deleteAccountLocalClear,
              pendingTransition.userID == userID else {
            return
        }

        clearPendingLocalAccountTransition()
    }

    private func completeLocalDeleteAccountClear() {
        resetLocalAccountState(resetCredits: false)
        clearLearningDraft()
        clearPersistedMemories()
        clearPendingGuestMemoryMigrationQueue()
        clearPendingGuestCreditMigration()
        clearLocalSentenceStudyProgress()
        remainingCredits = 0
        persistCredits()
        defaults.removeObject(forKey: AppStorageKey.preserveLocalGuestCreditsAgainstAnonymousProfile)
        clearPendingLocalAccountTransition()
    }

    private func persistPendingLocalAccountTransition(_ transition: PendingLocalAccountTransition) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = PersistenceDiagnostics.encode(
            transition,
            using: encoder,
            operation: "Encode pending local account transition"
        )
        defaults.set(data, forKey: AppStorageKey.pendingLocalAccountTransition)
    }

    private func loadPendingLocalAccountTransition() -> PendingLocalAccountTransition? {
        guard let data = defaults.data(forKey: AppStorageKey.pendingLocalAccountTransition) else {
            return nil
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return PersistenceDiagnostics.decode(
            PendingLocalAccountTransition.self,
            from: data,
            using: decoder,
            operation: "Decode pending local account transition"
        )
    }

    private func clearPendingLocalAccountTransition() {
        defaults.removeObject(forKey: AppStorageKey.pendingLocalAccountTransition)
    }

    private var currentMemoryCacheUserID: String {
        hasAuthenticatedSession ? (supabaseSession?.userID ?? AppStorageKey.guestMemoriesUserID) : AppStorageKey.guestMemoriesUserID
    }

    var currentCreditsOwnerID: String {
        hasAuthenticatedSession ? (supabaseSession?.userID ?? AppStorageKey.guestMemoriesUserID) : AppStorageKey.guestMemoriesUserID
    }

    var persistedCreditsOwnerID: String? {
        defaults.string(forKey: AppStorageKey.remainingCreditsOwnerID)
    }

    var localCreditsBelongToGuest: Bool {
        if let persistedCreditsOwnerID {
            return persistedCreditsOwnerID == AppStorageKey.guestMemoriesUserID
        }

        return !hasAuthenticatedSession && profile == nil
    }

    func persistPendingMemoryImageUploads() {
        let encoder = JSONEncoder()
        let data = PersistenceDiagnostics.encode(
            pendingMemoryImageUploads,
            using: encoder,
            operation: "Encode pending memory image uploads"
        )
        defaults.set(data, forKey: AppStorageKey.pendingMemoryImageUploads)
    }

    func persistPendingFavoriteChanges() {
        let encoder = JSONEncoder()
        let data = PersistenceDiagnostics.encode(
            pendingFavoriteChanges,
            using: encoder,
            operation: "Encode pending favorite changes"
        )
        defaults.set(data, forKey: AppStorageKey.pendingFavoriteChanges)
    }

    func persistPendingMemoryDeletions() {
        let encoder = JSONEncoder()
        let data = PersistenceDiagnostics.encode(
            pendingMemoryDeletions,
            using: encoder,
            operation: "Encode pending memory deletions"
        )
        defaults.set(data, forKey: AppStorageKey.pendingMemoryDeletions)
    }

    func persistPendingGuestCreditMigration() {
        guard let pendingGuestCreditMigration else {
            KeychainStorage.remove(for: AppStorageKey.pendingGuestCreditMigration)
            return
        }

        let encoder = JSONEncoder()
        let data = PersistenceDiagnostics.encode(
            pendingGuestCreditMigration,
            using: encoder,
            operation: "Encode pending guest credit migration"
        )
        if let data {
            KeychainStorage.set(data, for: AppStorageKey.pendingGuestCreditMigration)
        }
    }

    func persistLocalSentenceStudyProgress() {
        let encoder = JSONEncoder()
        let progressRecords = Array(localSentenceStudyProgress.values)
        let data = PersistenceDiagnostics.encode(
            progressRecords,
            using: encoder,
            operation: "Encode local sentence study progress"
        )
        defaults.set(data, forKey: AppStorageKey.localSentenceStudyProgress)
    }

    func loadLocalSentenceStudyProgress() {
        guard let data = defaults.data(forKey: AppStorageKey.localSentenceStudyProgress) else {
            localSentenceStudyProgress = [:]
            return
        }

        let decoder = JSONDecoder()
        guard let progressRecords = PersistenceDiagnostics.decode(
            [LocalSentenceStudyProgress].self,
            from: data,
            using: decoder,
            operation: "Decode local sentence study progress"
        ) else {
            localSentenceStudyProgress = [:]
            return
        }

        localSentenceStudyProgress = Dictionary(
            progressRecords.map { ($0.sentenceID, $0) },
            uniquingKeysWith: { current, candidate in
                let currentDate = current.lastStudiedAt ?? .distantPast
                let candidateDate = candidate.lastStudiedAt ?? .distantPast
                return currentDate >= candidateDate ? current : candidate
            }
        )
    }

    func clearLocalSentenceStudyProgress() {
        localSentenceStudyProgress = [:]
        favoriteSentenceStudyCounts = [:]
        defaults.removeObject(forKey: AppStorageKey.localSentenceStudyProgress)
    }

    func clearPendingMemoryImageUploads() {
        pendingMemoryImageUploads = []
        defaults.removeObject(forKey: AppStorageKey.pendingMemoryImageUploads)
    }

    func persistPendingGeneratedMemoryImage() {
        let encoder = JSONEncoder()
        if let pendingGeneratedMemoryImage {
            writePendingGeneratedImageData(pendingGeneratedMemoryImage.imageData)
        } else {
            removePendingGeneratedImageData()
        }
        let persistedValue = pendingGeneratedMemoryImage.map {
                PersistedPendingGeneratedMemoryImage(
                    startedAt: $0.startedAt,
                    previousMemoryIDs: $0.previousMemoryIDs,
                    guestJobID: $0.guestJobID,
                    clientRequestID: $0.clientRequestID
                )
            }
        let data = PersistenceDiagnostics.encode(
            persistedValue,
            using: encoder,
            operation: "Encode pending generated memory image metadata"
        )
        defaults.set(data, forKey: AppStorageKey.pendingGeneratedMemoryImage)
    }

    func clearPendingGeneratedMemoryImage() {
        pendingGeneratedMemoryImage = nil
        removePendingGeneratedImageData()
        defaults.removeObject(forKey: AppStorageKey.pendingGeneratedMemoryImage)
    }

    func clearPendingGuestCreditMigration() {
        pendingGuestCreditMigration = nil
        KeychainStorage.remove(for: AppStorageKey.pendingGuestCreditMigration)
    }

    func clearPersistedMemories() {
        cachedMemoryImageHydrationTask?.cancel()
        memoryWidgetSnapshotUpdateTask?.cancel()
        defaults.removeObject(forKey: AppStorageKey.memories)
        defaults.removeObject(forKey: AppStorageKey.memoriesUserID)
        PersistenceDiagnostics.removeItem(at: memoryImageDirectoryURL(), operation: "Remove memory image directory")
        MemoryWidgetSnapshotStore.scheduleUpdate(with: [])
    }

    func clearPendingGuestMemoryMigrationQueue() {
        pendingGuestMemoryMigrationQueue = []
        defaults.removeObject(forKey: AppStorageKey.pendingGuestMemoryMigrationQueue)
        PersistenceDiagnostics.removeItem(
            at: pendingGuestMemoryImageDirectoryURL(),
            operation: "Remove pending guest memory image directory"
        )
    }

    func persistPendingGuestMemoryMigrationQueue() {
        let encoder = JSONEncoder()
        let persistedQueue = pendingGuestMemoryMigrationQueue.map {
            PersistedPendingGuestMemoryMigrationEntry(
                id: $0.id,
                createdAt: $0.createdAt,
                remoteImagePath: $0.remoteImagePath,
                syncedToAccount: $0.syncedToAccount,
                sentences: $0.sentences
            )
        }
        let data = PersistenceDiagnostics.encode(
            persistedQueue,
            using: encoder,
            operation: "Encode pending guest memory migration queue"
        )
        defaults.set(data, forKey: AppStorageKey.pendingGuestMemoryMigrationQueue)
        persistPendingGuestMemoryImageFiles()
    }

    func loadPendingGuestMemoryMigrationQueue() {
        guard let data = defaults.data(forKey: AppStorageKey.pendingGuestMemoryMigrationQueue) else {
            pendingGuestMemoryMigrationQueue = []
            return
        }

        let decoder = JSONDecoder()
        guard let persistedQueue = PersistenceDiagnostics.decode(
            [PersistedPendingGuestMemoryMigrationEntry].self,
            from: data,
            using: decoder,
            operation: "Decode pending guest memory migration queue"
        ) else {
            pendingGuestMemoryMigrationQueue = []
            return
        }

        pendingGuestMemoryMigrationQueue = persistedQueue.map { memory in
            MemoryEntry(
                id: memory.id,
                createdAt: memory.createdAt,
                imageData: loadPendingGuestMemoryImageData(for: memory.id),
                remoteImagePath: memory.remoteImagePath,
                syncedToAccount: memory.syncedToAccount ?? false,
                sentences: memory.sentences
            )
        }
    }

    func persistCredits() {
        defaults.set(remainingCredits, forKey: AppStorageKey.remainingCredits)
        defaults.set(currentCreditsOwnerID, forKey: AppStorageKey.remainingCreditsOwnerID)
    }

    func applyCachedMemoriesIfAvailable(
        for userID: String,
        imageLoading: CachedMemoryImageLoadingMode = .immediateForAll
    ) {
        guard let cachedMemories = cachedMemories(for: userID, imageLoading: imageLoading) else {
            memories = []
            recordedMemoriesCount = 0
            favoriteSentencesCount = 0
            return
        }

        memories = cachedMemories.memories.deduplicatedByMemoryID()

        recordedMemoriesCount = memories.count
        favoriteSentencesCount = memories.reduce(into: 0) { partialResult, memory in
            partialResult += memory.sentences.filter(\.isFavorite).count
        }

        scheduleCachedMemoryImageHydrationIfNeeded(
            for: cachedMemories.deferredImageMemoryIDs,
            userID: userID
        )
    }

    func mergePendingGuestMemoriesIntoCurrentMemoriesIfNeeded(persistUserID: String? = nil) {
        var queuedMemories = pendingGuestMemoryMigrationQueue
            .filter(isMemoryContentComplete)
            .deduplicatedByMemoryID()
            .sorted { $0.createdAt > $1.createdAt }

        if let persistUserID,
           persistUserID != AppStorageKey.guestMemoriesUserID,
           let cachedGuestMemories = cachedMemories(for: AppStorageKey.guestMemoriesUserID) {
            for guestMemory in cachedGuestMemories.memories
                .filter({ isMemoryContentComplete($0) && !$0.syncedToAccount })
                .sorted(by: { $0.createdAt > $1.createdAt }) {
                let alreadyQueued = queuedMemories.contains { queuedMemory in
                    matchesMemoryIdentity(queuedMemory, guestMemory)
                }

                if !alreadyQueued {
                    queuedMemories.append(guestMemory)
                }
            }
        }

        guard !queuedMemories.isEmpty else { return }

        var mergedMemories = memories.deduplicatedByMemoryID()
        var didChange = false

        for queuedMemory in queuedMemories {
            if let exactIndex = mergedMemories.firstIndex(where: { $0.id == queuedMemory.id }) {
                if mergedMemories[exactIndex] != queuedMemory {
                    mergedMemories[exactIndex] = queuedMemory
                    didChange = true
                }
                continue
            }

            if let matchingIndex = mergedMemories.firstIndex(where: { matchesMemoryIdentity($0, queuedMemory) }) {
                if mergedMemories[matchingIndex].imageData.isEmpty && !queuedMemory.imageData.isEmpty {
                    mergedMemories[matchingIndex] = MemoryEntry(
                        id: mergedMemories[matchingIndex].id,
                        createdAt: mergedMemories[matchingIndex].createdAt,
                        imageData: queuedMemory.imageData,
                        remoteImagePath: mergedMemories[matchingIndex].remoteImagePath,
                        syncedToAccount: mergedMemories[matchingIndex].syncedToAccount,
                        sentences: mergedMemories[matchingIndex].sentences
                    )
                    didChange = true
                }
                continue
            }

            mergedMemories.append(queuedMemory)
            didChange = true
        }

        guard didChange else { return }

        mergedMemories = mergedMemories
            .deduplicatedByMemoryID()
            .sorted { $0.createdAt > $1.createdAt }
        memories = mergedMemories
        recordedMemoriesCount = mergedMemories.count
        favoriteSentencesCount = mergedMemories.reduce(into: 0) { partialResult, memory in
            partialResult += memory.sentences.filter(\.isFavorite).count
        }
        if let persistUserID {
            persistMemories(for: persistUserID)
        } else {
            persistMemories()
        }
    }

    private func cachedMemories(
        for userID: String,
        imageLoading: CachedMemoryImageLoadingMode = .immediateForAll
    ) -> CachedMemories? {
        let cachedUserID = defaults.string(forKey: AppStorageKey.memoriesUserID)
        guard cachedUserID == userID,
              let memoryData = defaults.data(forKey: AppStorageKey.memories) else {
            return nil
        }

        let decoder = JSONDecoder()
        if let persistedMemories = PersistenceDiagnostics.decode(
            [PersistedMemoryEntry].self,
            from: memoryData,
            using: decoder,
            operation: "Decode cached memories"
        ) {
            let defaultSyncedToAccount = defaultSyncedValueForCachedMemories(userID: userID)
            var deferredImageMemoryIDs: [UUID] = []
            let decodedMemories = persistedMemories.map { memory -> MemoryEntry in
                let syncedToAccount = memory.syncedToAccount ?? defaultSyncedToAccount
                let shouldDeferImage = imageLoading == .deferRemoteBacked
                    && syncedToAccount
                    && memory.remoteImagePath != nil
                if shouldDeferImage {
                    deferredImageMemoryIDs.append(memory.id)
                }
                return MemoryEntry(
                    id: memory.id,
                    createdAt: memory.createdAt,
                    imageData: shouldDeferImage ? Data() : loadMemoryImageData(for: memory.id),
                    remoteImagePath: memory.remoteImagePath,
                    syncedToAccount: syncedToAccount,
                    sentences: memory.sentences
                )
            }
            return CachedMemories(memories: decodedMemories, deferredImageMemoryIDs: deferredImageMemoryIDs)
        }

        if let decodedLegacyMemories = PersistenceDiagnostics.decode(
            [MemoryEntry].self,
            from: memoryData,
            using: decoder,
            operation: "Decode legacy cached memories"
        ) {
            return CachedMemories(memories: decodedLegacyMemories, deferredImageMemoryIDs: [])
        }

        return nil
    }

    private func defaultSyncedValueForCachedMemories(userID: String) -> Bool {
        userID != AppStorageKey.guestMemoriesUserID
    }

    func hasCachedMemories(for userID: String) -> Bool {
        let cachedUserID = defaults.string(forKey: AppStorageKey.memoriesUserID)
        guard cachedUserID == userID else { return false }
        return defaults.data(forKey: AppStorageKey.memories) != nil
    }

    private func scheduleCachedMemoryImageHydrationIfNeeded(
        for memoryIDs: [UUID],
        userID: String
    ) {
        cachedMemoryImageHydrationTask?.cancel()

        guard !memoryIDs.isEmpty else { return }

        let directoryURL = memoryImageDirectoryURL()
        cachedMemoryImageHydrationTask = Task { [weak self] in
            let imagesByID = await Task.detached(priority: .utility) {
                var loadedImages: [UUID: Data] = [:]
                for memoryID in memoryIDs {
                    guard !Task.isCancelled else { return loadedImages }
                    let fileName = "\(memoryID.uuidString.lowercased()).jpg"
                    let fileURL = directoryURL.appendingPathComponent(fileName)
                    guard let imageData = PersistenceDiagnostics.readData(
                        from: fileURL,
                        operation: "Hydrate cached memory image"
                    ),
                          !imageData.isEmpty else {
                        continue
                    }
                    loadedImages[memoryID] = imageData
                }
                return loadedImages
            }.value

            guard !Task.isCancelled, let self else { return }
            guard self.defaults.string(forKey: AppStorageKey.memoriesUserID) == userID else { return }

            var didHydrateImage = false
            let hydratedMemories = self.memories.map { memory in
                guard memory.imageData.isEmpty,
                      let imageData = imagesByID[memory.id],
                      !imageData.isEmpty else {
                    return memory
                }

                didHydrateImage = true
                return MemoryEntry(
                    id: memory.id,
                    createdAt: memory.createdAt,
                    imageData: imageData,
                    remoteImagePath: memory.remoteImagePath,
                    syncedToAccount: memory.syncedToAccount,
                    sentences: memory.sentences
                )
            }

            guard didHydrateImage else { return }
            self.memories = hydratedMemories
            self.scheduleMemoryWidgetSnapshotUpdate(with: hydratedMemories)
        }
    }

    private func scheduleMemoryWidgetSnapshotUpdate(with memories: [MemoryEntry]) {
        memoryWidgetSnapshotUpdateTask?.cancel()
        let snapshotMemories = memories

        memoryWidgetSnapshotUpdateTask = Task {
            try? await Task.sleep(nanoseconds: Self.memoryWidgetSnapshotDebounceNanoseconds)
            guard !Task.isCancelled else { return }
            MemoryWidgetSnapshotStore.scheduleUpdate(with: snapshotMemories)
        }
    }

    func loadPendingMemoryImageUploads() {
        guard let data = defaults.data(forKey: AppStorageKey.pendingMemoryImageUploads) else {
            pendingMemoryImageUploads = []
            return
        }

        let decoder = JSONDecoder()
        pendingMemoryImageUploads = PersistenceDiagnostics.decode(
            [PendingMemoryImageUpload].self,
            from: data,
            using: decoder,
            operation: "Decode pending memory image uploads"
        ) ?? []
    }

    func loadPendingFavoriteChanges() {
        guard let data = defaults.data(forKey: AppStorageKey.pendingFavoriteChanges) else {
            pendingFavoriteChanges = []
            return
        }

        let decoder = JSONDecoder()
        pendingFavoriteChanges = PersistenceDiagnostics.decode(
            [PendingFavoriteChange].self,
            from: data,
            using: decoder,
            operation: "Decode pending favorite changes"
        ) ?? []
    }



    func loadPendingMemoryDeletions() {
        guard let data = defaults.data(forKey: AppStorageKey.pendingMemoryDeletions) else {
            pendingMemoryDeletions = []
            return
        }

        let decoder = JSONDecoder()
        pendingMemoryDeletions = PersistenceDiagnostics.decode(
            [PendingMemoryDeletion].self,
            from: data,
            using: decoder,
            operation: "Decode pending memory deletions"
        ) ?? []
    }

    func loadPendingGuestCreditMigration() {
        defaults.removeObject(forKey: AppStorageKey.pendingGuestCreditMergeLegacy)

        guard let data = KeychainStorage.get(for: AppStorageKey.pendingGuestCreditMigration) else {
            pendingGuestCreditMigration = nil
            return
        }

        let decoder = JSONDecoder()
        pendingGuestCreditMigration = PersistenceDiagnostics.decode(
            PendingGuestCreditMigration.self,
            from: data,
            using: decoder,
            operation: "Decode pending guest credit migration"
        )
    }

    func loadPendingGeneratedMemoryImage() {
        guard let data = defaults.data(forKey: AppStorageKey.pendingGeneratedMemoryImage) else {
            pendingGeneratedMemoryImage = nil
            return
        }

        let decoder = JSONDecoder()
        if let persistedValue = PersistenceDiagnostics.decode(
            PersistedPendingGeneratedMemoryImage.self,
            from: data,
            using: decoder,
            operation: "Decode pending generated memory image metadata"
        ) {
            let imageData = loadPendingGeneratedImageData()
            pendingGeneratedMemoryImage = imageData.map {
                PendingGeneratedMemoryImage(
                    startedAt: persistedValue.startedAt,
                    previousMemoryIDs: persistedValue.previousMemoryIDs,
                    guestJobID: persistedValue.guestJobID,
                    clientRequestID: persistedValue.clientRequestID,
                    imageData: $0
                )
            }
        } else if let legacyValue = PersistenceDiagnostics.decode(
            PendingGeneratedMemoryImage.self,
            from: data,
            using: decoder,
            operation: "Decode legacy pending generated memory image"
        ) {
            pendingGeneratedMemoryImage = legacyValue
            persistPendingGeneratedMemoryImage()
        } else {
            pendingGeneratedMemoryImage = nil
        }
    }

    private func loadMemoryImageData(for memoryID: UUID) -> Data {
        let fileURL = memoryImageDirectoryURL().appendingPathComponent(memoryImageFileName(for: memoryID))
        return PersistenceDiagnostics.readData(from: fileURL, operation: "Load memory image") ?? Data()
    }

    private func persistPendingGuestMemoryImageFiles() {
        let fileManager = FileManager.default
        let directoryURL = pendingGuestMemoryImageDirectoryURL()

        PersistenceDiagnostics.createDirectory(at: directoryURL, operation: "Create pending guest memory image directory")

        let validFileNames = Set(pendingGuestMemoryMigrationQueue.map { memoryImageFileName(for: $0.id) })
        if let existingFiles = PersistenceDiagnostics.contentsOfDirectory(
            at: directoryURL,
            operation: "List pending guest memory image directory"
        ) {
            for fileURL in existingFiles where !validFileNames.contains(fileURL.lastPathComponent) {
                PersistenceDiagnostics.removeItem(at: fileURL, operation: "Remove stale pending guest memory image")
            }
        }

        for memory in pendingGuestMemoryMigrationQueue where !memory.imageData.isEmpty {
            let fileURL = directoryURL.appendingPathComponent(memoryImageFileName(for: memory.id))
            guard !fileManager.fileExists(atPath: fileURL.path) else { continue }
            PersistenceDiagnostics.writeData(memory.imageData, to: fileURL, operation: "Write pending guest memory image")
        }
    }

    private func loadPendingGuestMemoryImageData(for memoryID: UUID) -> Data {
        let fileURL = pendingGuestMemoryImageDirectoryURL().appendingPathComponent(memoryImageFileName(for: memoryID))
        return PersistenceDiagnostics.readData(from: fileURL, operation: "Load pending guest memory image") ?? Data()
    }

    private func writePendingGeneratedImageData(_ data: Data) {
        let directoryURL = pendingGeneratedImageDirectoryURL()
        PersistenceDiagnostics.createDirectory(at: directoryURL, operation: "Create pending generated image directory")
        PersistenceDiagnostics.writeData(data, to: pendingGeneratedImageFileURL(), operation: "Write pending generated image")
    }

    private func loadPendingGeneratedImageData() -> Data? {
        PersistenceDiagnostics.readData(from: pendingGeneratedImageFileURL(), operation: "Load pending generated image")
    }

    private func removePendingGeneratedImageData() {
        PersistenceDiagnostics.removeItem(at: pendingGeneratedImageFileURL(), operation: "Remove pending generated image")
    }

    private func memoryImageDirectoryURL() -> URL {
        persistentImageDirectoryURL(named: "SanjuMemoryImages")
    }

    private func pendingGeneratedImageDirectoryURL() -> URL {
        persistentImageDirectoryURL(named: "SanjuPendingImages")
    }

    private func pendingGuestMemoryImageDirectoryURL() -> URL {
        persistentImageDirectoryURL(named: "SanjuPendingGuestMemoryImages")
    }

    private func persistentImageDirectoryURL(named directoryName: String) -> URL {
        let fileManager = FileManager.default
        let supportRootURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sanju", isDirectory: true)
        let targetURL = supportRootURL.appendingPathComponent(directoryName, isDirectory: true)
        let legacyURL = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(directoryName, isDirectory: true)

        PersistenceDiagnostics.createDirectory(at: supportRootURL, operation: "Create support root directory")

        guard fileManager.fileExists(atPath: legacyURL.path) else {
            return targetURL
        }

        if !fileManager.fileExists(atPath: targetURL.path) {
            PersistenceDiagnostics.moveItem(at: legacyURL, to: targetURL, operation: "Move legacy image directory")
            return targetURL
        }

        if let legacyFiles = PersistenceDiagnostics.contentsOfDirectory(
            at: legacyURL,
            operation: "List legacy image directory"
        ) {
            PersistenceDiagnostics.createDirectory(at: targetURL, operation: "Create migrated image directory")
            for fileURL in legacyFiles {
                let destinationURL = targetURL.appendingPathComponent(fileURL.lastPathComponent)
                guard !fileManager.fileExists(atPath: destinationURL.path) else { continue }
                PersistenceDiagnostics.moveItem(at: fileURL, to: destinationURL, operation: "Move legacy image file")
            }
        }
        PersistenceDiagnostics.removeItem(at: legacyURL, operation: "Remove legacy image directory")
        return targetURL
    }

    private func pendingGeneratedImageFileURL() -> URL {
        pendingGeneratedImageDirectoryURL().appendingPathComponent("pending-generated-image.jpg")
    }

    private func memoryImageFileName(for memoryID: UUID) -> String {
        "\(memoryID.uuidString.lowercased()).jpg"
    }
}
