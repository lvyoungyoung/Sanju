import Foundation

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

        try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let validFileNames = Set(imageFiles.map { memoryImageFileName(for: $0.memoryID) })
        if let existingFiles = try? fileManager.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil) {
            for fileURL in existingFiles where !validFileNames.contains(fileURL.lastPathComponent) {
                try? fileManager.removeItem(at: fileURL)
            }
        }

        for imageFile in imageFiles where !imageFile.imageData.isEmpty {
            let fileURL = directoryURL.appendingPathComponent(memoryImageFileName(for: imageFile.memoryID))
            guard !fileManager.fileExists(atPath: fileURL.path) else { continue }
            try? imageFile.imageData.write(to: fileURL, options: .atomic)
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

        try? fileManager.createDirectory(at: supportRootURL, withIntermediateDirectories: true)

        guard fileManager.fileExists(atPath: legacyURL.path) else {
            return targetURL
        }

        if !fileManager.fileExists(atPath: targetURL.path) {
            try? fileManager.moveItem(at: legacyURL, to: targetURL)
            return targetURL
        }

        if let legacyFiles = try? fileManager.contentsOfDirectory(at: legacyURL, includingPropertiesForKeys: nil) {
            try? fileManager.createDirectory(at: targetURL, withIntermediateDirectories: true)
            for fileURL in legacyFiles {
                let destinationURL = targetURL.appendingPathComponent(fileURL.lastPathComponent)
                guard !fileManager.fileExists(atPath: destinationURL.path) else { continue }
                try? fileManager.moveItem(at: fileURL, to: destinationURL)
            }
        }
        try? fileManager.removeItem(at: legacyURL)
        return targetURL
    }

    private static func memoryImageFileName(for memoryID: UUID) -> String {
        "\(memoryID.uuidString.lowercased()).jpg"
    }
}

extension AppModel {
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
    }

    private struct PersistedPendingGuestMemoryMigrationEntry: Codable {
        let id: UUID
        let createdAt: Date
        let remoteImagePath: String?
        let syncedToAccount: Bool?
        let sentences: [SentenceRecord]
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
        if let data = try? encoder.encode(supabaseSession) {
            KeychainStorage.set(data, for: AppStorageKey.supabaseSession)
        }
    }

    func loadStoredSession() -> SupabaseSession? {
        guard let data = KeychainStorage.get(for: AppStorageKey.supabaseSession) else {
            return nil
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SupabaseSession.self, from: data)
    }

    func clearStoredSession() {
        supabaseSession = nil
        KeychainStorage.remove(for: AppStorageKey.supabaseSession)
    }

    func persistProfile() {
        let encoder = JSONEncoder()
        let data = try? encoder.encode(profile)
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
        let data = try? encoder.encode(persistedMemories)
        defaults.set(data, forKey: AppStorageKey.memories)
        defaults.set(userID, forKey: AppStorageKey.memoriesUserID)
        MemoryImagePersistenceStore.schedulePersist(memories: memories)
        MemoryWidgetSnapshotStore.scheduleUpdate(with: memories)
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
        let data = try? encoder.encode(transition)
        defaults.set(data, forKey: AppStorageKey.pendingLocalAccountTransition)
    }

    private func loadPendingLocalAccountTransition() -> PendingLocalAccountTransition? {
        guard let data = defaults.data(forKey: AppStorageKey.pendingLocalAccountTransition) else {
            return nil
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(PendingLocalAccountTransition.self, from: data)
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
        let data = try? encoder.encode(pendingMemoryImageUploads)
        defaults.set(data, forKey: AppStorageKey.pendingMemoryImageUploads)
    }

    func persistPendingFavoriteChanges() {
        let encoder = JSONEncoder()
        let data = try? encoder.encode(pendingFavoriteChanges)
        defaults.set(data, forKey: AppStorageKey.pendingFavoriteChanges)
    }

    func persistPendingMemoryDeletions() {
        let encoder = JSONEncoder()
        let data = try? encoder.encode(pendingMemoryDeletions)
        defaults.set(data, forKey: AppStorageKey.pendingMemoryDeletions)
    }

    func persistPendingGuestCreditMigration() {
        guard let pendingGuestCreditMigration else {
            KeychainStorage.remove(for: AppStorageKey.pendingGuestCreditMigration)
            return
        }

        let encoder = JSONEncoder()
        let data = try? encoder.encode(pendingGuestCreditMigration)
        if let data {
            KeychainStorage.set(data, for: AppStorageKey.pendingGuestCreditMigration)
        }
    }

    func persistLocalSentenceStudyProgress() {
        let encoder = JSONEncoder()
        let progressRecords = Array(localSentenceStudyProgress.values)
        let data = try? encoder.encode(progressRecords)
        defaults.set(data, forKey: AppStorageKey.localSentenceStudyProgress)
    }

    func loadLocalSentenceStudyProgress() {
        guard let data = defaults.data(forKey: AppStorageKey.localSentenceStudyProgress) else {
            localSentenceStudyProgress = [:]
            return
        }

        let decoder = JSONDecoder()
        guard let progressRecords = try? decoder.decode([LocalSentenceStudyProgress].self, from: data) else {
            localSentenceStudyProgress = [:]
            return
        }

        localSentenceStudyProgress = Dictionary(
            uniqueKeysWithValues: progressRecords.map { ($0.sentenceID, $0) }
        )
    }

    func clearLocalSentenceStudyProgress() {
        localSentenceStudyProgress = [:]
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
                guestJobID: $0.guestJobID
            )
        }
        let data = try? encoder.encode(persistedValue)
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
        defaults.removeObject(forKey: AppStorageKey.memories)
        defaults.removeObject(forKey: AppStorageKey.memoriesUserID)
        try? FileManager.default.removeItem(at: memoryImageDirectoryURL())
        MemoryWidgetSnapshotStore.scheduleUpdate(with: [])
    }

    func clearPendingGuestMemoryMigrationQueue() {
        pendingGuestMemoryMigrationQueue = []
        defaults.removeObject(forKey: AppStorageKey.pendingGuestMemoryMigrationQueue)
        try? FileManager.default.removeItem(at: pendingGuestMemoryImageDirectoryURL())
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
        let data = try? encoder.encode(persistedQueue)
        defaults.set(data, forKey: AppStorageKey.pendingGuestMemoryMigrationQueue)
        persistPendingGuestMemoryImageFiles()
    }

    func loadPendingGuestMemoryMigrationQueue() {
        guard let data = defaults.data(forKey: AppStorageKey.pendingGuestMemoryMigrationQueue) else {
            pendingGuestMemoryMigrationQueue = []
            return
        }

        let decoder = JSONDecoder()
        guard let persistedQueue = try? decoder.decode([PersistedPendingGuestMemoryMigrationEntry].self, from: data) else {
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

    func applyCachedMemoriesIfAvailable(for userID: String) {
        guard let decodedMemories = cachedMemories(for: userID) else {
            memories = []
            recordedMemoriesCount = 0
            favoriteSentencesCount = 0
            return
        }

        memories = decodedMemories

        recordedMemoriesCount = memories.count
        favoriteSentencesCount = memories.reduce(into: 0) { partialResult, memory in
            partialResult += memory.sentences.filter(\.isFavorite).count
        }
    }

    func mergePendingGuestMemoriesIntoCurrentMemoriesIfNeeded(persistUserID: String? = nil) {
        var queuedMemories = pendingGuestMemoryMigrationQueue
            .filter(isMemoryContentComplete)
            .sorted { $0.createdAt > $1.createdAt }

        if let persistUserID,
           persistUserID != AppStorageKey.guestMemoriesUserID,
           let cachedGuestMemories = cachedMemories(for: AppStorageKey.guestMemoriesUserID) {
            for guestMemory in cachedGuestMemories
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

        var mergedMemories = memories
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

        mergedMemories.sort { $0.createdAt > $1.createdAt }
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

    private func cachedMemories(for userID: String) -> [MemoryEntry]? {
        let cachedUserID = defaults.string(forKey: AppStorageKey.memoriesUserID)
        guard cachedUserID == userID,
              let memoryData = defaults.data(forKey: AppStorageKey.memories) else {
            return nil
        }

        let decoder = JSONDecoder()
        if let persistedMemories = try? decoder.decode([PersistedMemoryEntry].self, from: memoryData) {
            let defaultSyncedToAccount = defaultSyncedValueForCachedMemories(userID: userID)
            let decodedMemories = persistedMemories.map { memory in
                MemoryEntry(
                    id: memory.id,
                    createdAt: memory.createdAt,
                    imageData: loadMemoryImageData(for: memory.id),
                    remoteImagePath: memory.remoteImagePath,
                    syncedToAccount: memory.syncedToAccount ?? defaultSyncedToAccount,
                    sentences: memory.sentences
                )
            }
            return decodedMemories
        }

        if let decodedLegacyMemories = try? decoder.decode([MemoryEntry].self, from: memoryData) {
            return decodedLegacyMemories
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

    func loadPendingMemoryImageUploads() {
        guard let data = defaults.data(forKey: AppStorageKey.pendingMemoryImageUploads) else {
            pendingMemoryImageUploads = []
            return
        }

        let decoder = JSONDecoder()
        pendingMemoryImageUploads = (try? decoder.decode([PendingMemoryImageUpload].self, from: data)) ?? []
    }

    func loadPendingFavoriteChanges() {
        guard let data = defaults.data(forKey: AppStorageKey.pendingFavoriteChanges) else {
            pendingFavoriteChanges = []
            return
        }

        let decoder = JSONDecoder()
        pendingFavoriteChanges = (try? decoder.decode([PendingFavoriteChange].self, from: data)) ?? []
    }



    func loadPendingMemoryDeletions() {
        guard let data = defaults.data(forKey: AppStorageKey.pendingMemoryDeletions) else {
            pendingMemoryDeletions = []
            return
        }

        let decoder = JSONDecoder()
        pendingMemoryDeletions = (try? decoder.decode([PendingMemoryDeletion].self, from: data)) ?? []
    }

    func loadPendingGuestCreditMigration() {
        defaults.removeObject(forKey: AppStorageKey.pendingGuestCreditMergeLegacy)

        guard let data = KeychainStorage.get(for: AppStorageKey.pendingGuestCreditMigration) else {
            pendingGuestCreditMigration = nil
            return
        }

        let decoder = JSONDecoder()
        pendingGuestCreditMigration = try? decoder.decode(PendingGuestCreditMigration.self, from: data)
    }

    func loadPendingGeneratedMemoryImage() {
        guard let data = defaults.data(forKey: AppStorageKey.pendingGeneratedMemoryImage) else {
            pendingGeneratedMemoryImage = nil
            return
        }

        let decoder = JSONDecoder()
        if let persistedValue = try? decoder.decode(PersistedPendingGeneratedMemoryImage.self, from: data) {
            let imageData = loadPendingGeneratedImageData()
            pendingGeneratedMemoryImage = imageData.map {
                PendingGeneratedMemoryImage(
                    startedAt: persistedValue.startedAt,
                    previousMemoryIDs: persistedValue.previousMemoryIDs,
                    guestJobID: persistedValue.guestJobID,
                    imageData: $0
                )
            }
        } else if let legacyValue = try? decoder.decode(PendingGeneratedMemoryImage.self, from: data) {
            pendingGeneratedMemoryImage = legacyValue
            persistPendingGeneratedMemoryImage()
        } else {
            pendingGeneratedMemoryImage = nil
        }
    }

    private func loadMemoryImageData(for memoryID: UUID) -> Data {
        let fileURL = memoryImageDirectoryURL().appendingPathComponent(memoryImageFileName(for: memoryID))
        return (try? Data(contentsOf: fileURL)) ?? Data()
    }

    private func persistPendingGuestMemoryImageFiles() {
        let fileManager = FileManager.default
        let directoryURL = pendingGuestMemoryImageDirectoryURL()

        try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let validFileNames = Set(pendingGuestMemoryMigrationQueue.map { memoryImageFileName(for: $0.id) })
        if let existingFiles = try? fileManager.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil) {
            for fileURL in existingFiles where !validFileNames.contains(fileURL.lastPathComponent) {
                try? fileManager.removeItem(at: fileURL)
            }
        }

        for memory in pendingGuestMemoryMigrationQueue where !memory.imageData.isEmpty {
            let fileURL = directoryURL.appendingPathComponent(memoryImageFileName(for: memory.id))
            guard !fileManager.fileExists(atPath: fileURL.path) else { continue }
            try? memory.imageData.write(to: fileURL, options: .atomic)
        }
    }

    private func loadPendingGuestMemoryImageData(for memoryID: UUID) -> Data {
        let fileURL = pendingGuestMemoryImageDirectoryURL().appendingPathComponent(memoryImageFileName(for: memoryID))
        return (try? Data(contentsOf: fileURL)) ?? Data()
    }

    private func writePendingGeneratedImageData(_ data: Data) {
        let fileManager = FileManager.default
        let directoryURL = pendingGeneratedImageDirectoryURL()
        try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try? data.write(to: pendingGeneratedImageFileURL(), options: .atomic)
    }

    private func loadPendingGeneratedImageData() -> Data? {
        try? Data(contentsOf: pendingGeneratedImageFileURL())
    }

    private func removePendingGeneratedImageData() {
        try? FileManager.default.removeItem(at: pendingGeneratedImageFileURL())
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

        try? fileManager.createDirectory(at: supportRootURL, withIntermediateDirectories: true)

        guard fileManager.fileExists(atPath: legacyURL.path) else {
            return targetURL
        }

        if !fileManager.fileExists(atPath: targetURL.path) {
            try? fileManager.moveItem(at: legacyURL, to: targetURL)
            return targetURL
        }

        if let legacyFiles = try? fileManager.contentsOfDirectory(at: legacyURL, includingPropertiesForKeys: nil) {
            try? fileManager.createDirectory(at: targetURL, withIntermediateDirectories: true)
            for fileURL in legacyFiles {
                let destinationURL = targetURL.appendingPathComponent(fileURL.lastPathComponent)
                guard !fileManager.fileExists(atPath: destinationURL.path) else { continue }
                try? fileManager.moveItem(at: fileURL, to: destinationURL)
            }
        }
        try? fileManager.removeItem(at: legacyURL)
        return targetURL
    }

    private func pendingGeneratedImageFileURL() -> URL {
        pendingGeneratedImageDirectoryURL().appendingPathComponent("pending-generated-image.jpg")
    }

    private func memoryImageFileName(for memoryID: UUID) -> String {
        "\(memoryID.uuidString.lowercased()).jpg"
    }
}
