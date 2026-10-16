import Foundation
import CryptoKit

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
    let timing: GenerationTiming
    let spec: GenerationSpec
    let accountRevision: UUID
}

private enum GenerationRequestOutcome {
    case generated(SupabaseGenerateMemoryResult, SupabaseSession)
    case recovered(MemoryEntry, SupabaseSession)
}

extension AppModel {
    private var recoveryRequestTimeout: Duration {
        .seconds(12)
    }

    private var pendingGeneratedRecoveryExpirationInterval: TimeInterval {
        24 * 60 * 60
    }

    private func waitForRecoveryDelay(_ delay: Duration) async -> Bool {
        guard !Task.isCancelled else { return false }
        guard delay != .zero else { return true }

        do {
            try await Task.sleep(for: delay)
        } catch {
            return false
        }

        return !Task.isCancelled
    }

    // MARK: - Generation

    func generateMemory(from imageData: Data) async throws -> MemoryEntry {
        guard learningPreferenceSync?.hasInvalidCache != true else {
            throw LanguageContractError.corruptContent
        }
        let spec = currentGenerationSpec
        try spec.validate()
        let scope = GenerationAccountScope(accountRequests: accountRequests,
            session: supabaseSession ?? loadStoredSession())
        guard !hasPendingGeneratedMemoryRecoveryCandidate() else {
            throw SupabaseServiceError.apiError("generation_in_progress")
        }
        let timing = GenerationTiming()
        var outcome = "failed"
        defer { timing.finish(outcome: outcome) }
        guard remainingCredits > 0 else {
            throw KimiServiceError.noCredits
        }

        try consumeGenerationAttemptIfAllowed()

        timing.start("client_compress")
        let images = try prepareGenerationImages(from: imageData)
        let context = try await prepareGenerationRequestContext(images: images, timing: timing,
            spec: spec, scope: scope)

        timing.start("client_generate_request")
        switch try await performGenerationRequest(images: images, context: context) {
        case let .generated(result, session):
            try accountRequests.check(context.accountRevision)
            timing.start("client_local_save")
            let memory = makeGeneratedMemory(
                from: result,
                memoryImageData: images.memoryImageData,
                isAnonymous: session.isAnonymous
            )
            await finalizeGeneratedMemory(
                memory,
                originalImageData: images.originalImageData,
                remainingCredits: result.remainingCredits,
                session: session,
                timing: timing
            )
            try accountRequests.check(context.accountRevision)
            outcome = "success"
            return memory

        case let .recovered(memory, _):
            try accountRequests.check(context.accountRevision)
            outcome = "recovered"
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

    private func prepareGenerationRequestContext(images: PreparedGenerationImages, timing: GenerationTiming,
        spec: GenerationSpec, scope: GenerationAccountScope) async throws -> GenerationRequestContext {
        timing.start("client_session")
        let session = try await ensureValidSession()
        let revision = try scope.resolvedRevision(session: session, currentSession: supabaseSession,
            accountRequests: accountRequests)
        guard !hasPendingGeneratedMemoryRecoveryCandidate() else {
            throw SupabaseServiceError.apiError("generation_in_progress")
        }
        timing.start("client_pending_save")
        let existingMemoryIDs = Set(memories.map(\.id))
        let guestJobID = session.isAnonymous ? UUID().uuidString.lowercased() : nil
        let clientRequestID = timing.requestID

        pendingGeneratedMemoryImage = PendingGeneratedMemoryImage(
            startedAt: .now,
            previousMemoryIDs: Array(existingMemoryIDs),
            guestJobID: guestJobID,
            clientRequestID: clientRequestID,
            imageData: images.memoryImageData,
            snapshot: GenerationRequestSnapshot(owner: session.userID, accountRevision: revision,
                requestID: UUID(uuidString: timing.requestID)!, guestJobID: guestJobID.flatMap(UUID.init(uuidString:)),
                spec: spec, imageDigest: SHA256.hash(data: images.analysisImageData).map { String(format: "%02x", $0) }.joined(),
                createdAt: .now)
        )
        guard persistPendingGeneratedMemoryImage() else {
            throw LanguageContractError.corruptContent
        }

        return GenerationRequestContext(
            session: session,
            existingMemoryIDs: existingMemoryIDs,
            guestJobID: guestJobID,
            clientRequestID: clientRequestID,
            timing: timing,
            spec: spec,
            accountRevision: revision
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
                spec: context.spec,
                guestJobID: context.guestJobID,
                clientRequestID: context.clientRequestID
            )
            try accountRequests.check(context.accountRevision)
            return .generated(result, context.session)
        } catch {
            try accountRequests.check(context.accountRevision)
            if isInvalidJWTGenerationError(error) {
                return try await retryGenerationAfterRefreshingSession(
                    images: images,
                    context: context
                )
            }

            context.timing.start("client_recovery")
            if let recoveredMemory = await recoverGeneratedMemoryIfNeeded(
                after: error,
                previousMemoryIDs: context.existingMemoryIDs,
                session: context.session
            ) {
                try accountRequests.check(context.accountRevision)
                let reconciledMemory = await finalizeRecoveredGeneratedMemory(
                    recoveredMemory,
                    originalImageData: images.originalImageData,
                    memoryImageData: images.memoryImageData,
                    session: context.session,
                    timing: context.timing
                )
                return .recovered(reconciledMemory, context.session)
            }

            try accountRequests.check(context.accountRevision)
            clearPendingGeneratedMemoryImageIfRecoveryIsNotNeeded(for: error)
            throw error
        }
    }

    private func retryGenerationAfterRefreshingSession(
        images: PreparedGenerationImages,
        context: GenerationRequestContext
    ) async throws -> GenerationRequestOutcome {
        context.timing.start("client_refresh_session")
        let refreshedSession = try await forceRefreshSession()
        try accountRequests.check(context.accountRevision)
        guard refreshedSession.userID == context.session.userID else { throw CancellationError() }

        do {
            context.timing.start("client_generate_request")
            let result = try await requestGeneratedMemorySentences(
                session: refreshedSession,
                imageData: images.analysisImageData,
                spec: context.spec,
                guestJobID: context.guestJobID,
                clientRequestID: context.clientRequestID
            )
            try accountRequests.check(context.accountRevision)
            return .generated(result, refreshedSession)
        } catch {
            try accountRequests.check(context.accountRevision)
            clearPendingGeneratedMemoryImageIfRecoveryIsNotNeeded(for: error)
            throw error
        }
    }

    private func requestGeneratedMemorySentences(
        session: SupabaseSession,
        imageData: Data,
        spec: GenerationSpec,
        guestJobID: String?,
        clientRequestID: String?
    ) async throws -> SupabaseGenerateMemoryResult {
        try await supabaseService.generateMemorySentences(
            session: session,
            imageData: imageData,
            spec: spec,
            guestJobID: guestJobID,
            clientRequestID: clientRequestID
        )
    }

    private func isInvalidJWTGenerationError(_ error: Error) -> Bool {
        guard case let SupabaseServiceError.apiError(message) = error else { return false }
        return message.localizedCaseInsensitiveContains("invalid jwt")
    }

    private func clearPendingGeneratedMemoryImageIfRecoveryIsNotNeeded(for error: Error) {
        if case .nonRecoverable = error.generationRecoveryDisposition {
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
        session: SupabaseSession,
        timing: GenerationTiming
    ) async -> MemoryEntry {
        let revision = accountRequests.revision
        timing.start("client_recovered_save")
        let reconciledMemory = MemoryEntry(
            id: recoveredMemory.id,
            createdAt: recoveredMemory.createdAt,
            imageData: memoryImageData,
            remoteImagePath: recoveredMemory.remoteImagePath,
            syncedToAccount: !session.isAnonymous,
            tags: recoveredMemory.tags,
            sentences: recoveredMemory.sentences,
            context: recoveredMemory.context
        )

        if let recoveredIndex = memories.firstIndex(where: { $0.id == recoveredMemory.id }) {
            memories[recoveredIndex] = reconciledMemory
            persistMemories()
        }

        if reconciledMemory.context.isLegacyCompatible {
            enqueuePendingMemoryImageUploadIfNeeded(
                memoryID: reconciledMemory.id,
                remoteImagePath: reconciledMemory.remoteImagePath,
                imageData: memoryImageData
            )
            timing.start("client_photo_upload")
            await uploadMemoryImageIfNeeded(
                memoryID: reconciledMemory.id,
                remoteImagePath: reconciledMemory.remoteImagePath,
                imageData: memoryImageData,
                session: session
            )
        }
        guard (try? accountRequests.check(revision)) != nil else { return reconciledMemory }

        timing.start("client_recovered_finish")
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
                    // Keep the server-issued ID so guest import retains sentence identity.
                    id: sentence.id,
                    english: sentence.english,
                    chinese: sentence.chinese,
                    presentationGroup: sentence.presentationGroup,
                    isFavorite: sentence.isFavorite,
                    contentVersion: sentence.contentVersion,
                    learningMaterial: sentence.learningMaterial
                )
            }
            return MemoryEntry(
                id: generationResult.memory.id,
                createdAt: generationResult.memory.createdAt,
                imageData: memoryImageData,
                remoteImagePath: nil,
                syncedToAccount: false,
                tags: generationResult.memory.tags,
                sentences: localSentences,
                context: generationResult.memory.context
            )
        }

        return MemoryEntry(
            id: generationResult.memory.id,
            createdAt: generationResult.memory.createdAt,
            imageData: memoryImageData,
            remoteImagePath: generationResult.memory.remoteImagePath,
            syncedToAccount: true,
            tags: generationResult.memory.tags,
            sentences: generationResult.memory.sentences,
            context: generationResult.memory.context
        )
    }

    private func finalizeGeneratedMemory(
        _ memory: MemoryEntry,
        originalImageData: Data,
        remainingCredits updatedRemainingCredits: Int,
        session: SupabaseSession,
        timing: GenerationTiming
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

        guard !session.isAnonymous, memory.context.isLegacyCompatible else { return }
        enqueuePendingMemoryImageUploadIfNeeded(
            memoryID: memory.id,
            remoteImagePath: memory.remoteImagePath,
            imageData: memory.imageData
        )
        timing.start("client_photo_upload")
        await uploadMemoryImageIfNeeded(
            memoryID: memory.id,
            remoteImagePath: memory.remoteImagePath,
            imageData: memory.imageData,
            session: session
        )
    }

    // MARK: - Recovery

    func recoverGeneratedMemoryIfNeeded(
        after error: Error,
        previousMemoryIDs: Set<UUID>,
        session: SupabaseSession
    ) async -> MemoryEntry? {
        guard shouldAttemptGenerationRecovery(for: error) else {
            return nil
        }

        if pendingGeneratedMemoryImage?.snapshot != nil {
            return await recoverVersionedGeneration(session: session, retryDelays: [.milliseconds(800), .seconds(2), .seconds(3), .seconds(4)])
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
            guard await waitForRecoveryDelay(delay) else { return nil }
            let didRefresh = await runRecoveryAttemptWithTimeout {
                await self.syncMemoriesFromRemote(refreshCounts: true)
            }
            guard !Task.isCancelled else { return nil }
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
        let revision = accountRequests.revision
        guard !Task.isCancelled else { return nil }
        guard let pendingRecovery = pendingGeneratedMemoryImage else { return nil }
        guard !isPendingGeneratedRecoveryExpired(pendingRecovery) else {
            clearPendingGeneratedMemoryImage()
            return nil
        }

        let previousMemoryIDs = Set(pendingRecovery.previousMemoryIDs)
        guard let session = try? await ensureValidSession() else { return nil }
        guard (try? accountRequests.check(revision)) != nil else { return nil }
        if pendingRecovery.snapshot != nil {
            let memory = await recoverVersionedGeneration(session: session, retryDelays: [.zero, .seconds(5), .seconds(10), .seconds(20)])
            guard (try? accountRequests.check(revision)) != nil else { return nil }
            if memory != nil { clearPendingGeneratedMemoryImage() }
            return memory
        }
        if session.isAnonymous {
            let recoveredMemory = await recoverAnonymousGeneratedMemoryIfNeeded(
                previousMemoryIDs: previousMemoryIDs,
                session: session
            )
            guard !Task.isCancelled else { return nil }
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
            guard !Task.isCancelled else { return nil }
            return finalizeExplicitPendingRecoveryResult(recoveredMemory)
        }

        let retryDelays: [Duration] = [
            .zero,
            .seconds(5),
            .seconds(10),
            .seconds(20)
        ]

        for delay in retryDelays {
            guard await waitForRecoveryDelay(delay) else { return nil }

            let didRefresh = await runRecoveryAttemptWithTimeout {
                await self.syncMemoriesFromRemote(refreshCounts: true, downloadsImages: false)
            }
            guard !Task.isCancelled else { return nil }
            guard didRefresh else { continue }

            if let recoveredMemory = firstRecoveredMemory(after: previousMemoryIDs) {
                return finalizeExplicitPendingRecoveryResult(recoveredMemory)
            }
        }

        return finalizeExplicitPendingRecoveryResult(nil)
    }

    private func finalizeExplicitPendingRecoveryResult(_ recoveredMemory: MemoryEntry?) -> MemoryEntry? {
        // A timeout is not evidence that the server failed. Preserve the recovery identity.
        return recoveredMemory
    }

    private func recoverVersionedGeneration(session: SupabaseSession, retryDelays: [Duration]) async -> MemoryEntry? {
        let revision = accountRequests.revision
        guard let pending = pendingGeneratedMemoryImage, let snapshot = pending.snapshot,
              snapshot.owner == session.userID,
              UUID(uuidString: pending.clientRequestID ?? "") == snapshot.requestID,
              pending.guestJobID.flatMap(UUID.init(uuidString:)) == snapshot.guestJobID,
              (try? snapshot.spec.validate()) != nil else { return nil }

        for delay in retryDelays {
            guard await waitForRecoveryDelay(delay), (try? accountRequests.check(revision)) != nil else { return nil }
            do {
                let result = try await supabaseService.recoverGeneration(session: session, imageData: pending.imageData,
                    guestJobID: pending.guestJobID, clientRequestID: pending.clientRequestID)
                try accountRequests.check(revision)
                guard pendingGeneratedMemoryImage?.snapshot == snapshot else { return nil }
                guard let result else { continue }
                guard result.memory.context == snapshot.spec.context else { throw SupabaseServiceError.invalidResponse }
                let recoveredMemory: MemoryEntry
                if let existing = memories.first(where: { $0.id == result.memory.id }) {
                    recoveredMemory = existing
                } else {
                    recoveredMemory = result.memory
                    memories.insert(recoveredMemory, at: 0)
                }
                recordedMemoriesCount = memories.count
                favoriteSentencesCount = memories.reduce(0) { $0 + $1.sentences.filter(\.isFavorite).count }
                remainingCredits = result.remainingCredits
                upsertPendingGuestMemoryMigrationIfNeeded(recoveredMemory)
                persistMemories()
                persistCredits()
                if !session.isAnonymous, recoveredMemory.context.isLegacyCompatible {
                    enqueuePendingMemoryImageUploadIfNeeded(memoryID: recoveredMemory.id,
                        remoteImagePath: recoveredMemory.remoteImagePath, imageData: recoveredMemory.imageData)
                }
                return recoveredMemory
            } catch {
                guard (try? accountRequests.check(revision)) != nil else { return nil }
                if case let SupabaseServiceError.apiError(message) = error, message == "generation_failed" {
                    clearPendingGeneratedMemoryImage()
                    return nil
                }
            }
        }
        return nil
    }

    private func recoverAuthenticatedGeneratedMemoryIfNeeded(
        clientRequestID: String,
        previousMemoryIDs: Set<UUID>,
        session: SupabaseSession,
        retryDelays: [Duration]
    ) async -> MemoryEntry? {
        let revision = accountRequests.revision
        guard !clientRequestID.isEmpty else { return nil }

        for delay in retryDelays {
            guard await waitForRecoveryDelay(delay) else { return nil }

            guard let job = await fetchGenerationJobForRecovery(
                session: session,
                clientRequestID: clientRequestID
            ) else {
                continue
            }
            guard (try? accountRequests.check(revision)) != nil else { return nil }

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
                guard (try? accountRequests.check(revision)) != nil else { return nil }
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
        let revision = accountRequests.revision
        guard !Task.isCancelled else { return nil }
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
            guard await waitForRecoveryDelay(delay) else { return nil }

            guard let recovered = await recoverGuestGenerationForRecovery(
                session: session,
                imageData: pendingRecovery.imageData,
                guestJobID: guestJobID
            ) else {
                continue
            }
            guard !Task.isCancelled else { return nil }

            guard (try? accountRequests.check(revision)) != nil else { return nil }
            let recoveredMemory: MemoryEntry
            if let existingIndex = memories.firstIndex(where: {
                matchesMemoryIdentity($0, recovered.memory)
            }) {
                // Replaying a completed job must not reset favorites changed after its first delivery.
                recoveredMemory = memories[existingIndex]
            } else {
                memories.insert(recovered.memory, at: 0)
                recoveredMemory = recovered.memory
            }

            recordedMemoriesCount = memories.count
            favoriteSentencesCount = memories.reduce(into: 0) { partialResult, memory in
                partialResult += memory.sentences.filter(\.isFavorite).count
            }
            remainingCredits = recovered.remainingCredits
            upsertPendingGuestMemoryMigrationIfNeeded(recoveredMemory)
            persistMemories()
            persistCredits()
            return recoveredMemory
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
        guard !Task.isCancelled else { return false }
        return await withTaskGroup(of: Bool.self) { group in
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
            return !Task.isCancelled && result
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

}
