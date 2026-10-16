import Foundation

extension SupabaseService {
    func generateMemorySentences(session: SupabaseSession, imageData: Data, spec: GenerationSpec,
                                 guestJobID: String?, clientRequestID: String?) async throws -> SupabaseGenerateMemoryResult {
        try spec.validate()
        var request = try makeRequest(path: "/functions/v1/generate-memory-v3", method: "POST",
            bearerToken: session.accessToken,
            body: SupabaseContentGenerationRequest(imageBase64: imageData.base64EncodedString(),
                generationSpec: spec, guestJobID: guestJobID, clientRequestID: clientRequestID))
        #if DEBUG
        request.setValue("1", forHTTPHeaderField: "X-Sanju-Generation-Timing")
        request.setValue(clientRequestID ?? guestJobID, forHTTPHeaderField: "X-Sanju-Generation-Trace-ID")
        #endif
        let response: SupabaseContentGenerationResponse = try await perform(request)
        try validateContentRequestIdentity(response, session: session, guestJobID: guestJobID, clientRequestID: clientRequestID)
        guard let result = try response.result(imageData: imageData, isAnonymous: session.isAnonymous),
              result.memory.context.targetLanguage == spec.targetLanguage,
              result.memory.context.translationLanguage == spec.translationLanguage,
              result.memory.context.teachingLocale == spec.teachingLocale else {
            throw SupabaseServiceError.invalidResponse
        }
        if spec.generationFormat == "dialogue_tabs_v1", result.memory.sentences.count != 12 {
            throw SupabaseServiceError.invalidResponse
        }
        return result
    }

    func recoverGeneration(session: SupabaseSession, imageData: Data, guestJobID: String?,
                           clientRequestID: String?) async throws -> SupabaseGenerateMemoryResult? {
        var request = try makeRequest(path: "/functions/v1/recover-generation-v2", method: "POST",
            bearerToken: session.accessToken,
            body: SupabaseContentRecoveryRequest(guestJobID: guestJobID, clientRequestID: clientRequestID))
        request.timeoutInterval = 12
        let response: SupabaseContentGenerationResponse = try await perform(request)
        if response.status != "not_found" {
            try validateContentRequestIdentity(response, session: session, guestJobID: guestJobID, clientRequestID: clientRequestID)
        }
        return try response.result(imageData: imageData, isAnonymous: session.isAnonymous)
    }

    private func validateContentRequestIdentity(_ response: SupabaseContentGenerationResponse,
        session: SupabaseSession, guestJobID: String?, clientRequestID: String?) throws {
        let requested = session.isAnonymous ? guestJobID : clientRequestID
        let returned = session.isAnonymous ? response.guestJobID : response.clientRequestID
        guard let requestedID = requested.flatMap(UUID.init(uuidString:)),
              let returnedID = returned.flatMap(UUID.init(uuidString:)), requestedID == returnedID else {
            throw SupabaseServiceError.invalidResponse
        }
    }

    func fetchContentMemories(session: SupabaseSession) async throws -> [SupabaseMemoryRecord] {
        var records: [SupabaseMemoryRecord] = []
        var cursor: SupabaseContentCursor?
        var seenCursors = Set<SupabaseContentCursor>()
        var seenIDs = Set<String>()
        repeat {
            try Task.checkCancellation()
            let page: SupabaseContentPage = try await contentRPC(session: session, name: "list_memories_v2",
                payload: SupabaseContentListRequest(cursor: cursor))
            guard page.schemaVersion == 2 else { throw LanguageContractError.unsupportedVersion }
            let decoded = try page.memories.map { try $0.record() }
            for record in decoded {
                guard seenIDs.insert(record.id).inserted else { throw SupabaseServiceError.invalidResponse }
                records.append(record)
            }
            cursor = page.nextCursor
            if let cursor {
                guard !decoded.isEmpty, seenCursors.insert(cursor).inserted else {
                    throw SupabaseServiceError.invalidResponse
                }
            }
        } while cursor != nil
        return records
    }

    func createMemoryCopy(session: SupabaseSession, memory: MemoryEntry, guestAccessToken: String?) async throws -> MemoryEntry {
        try await importContentMemory(session: session, memory: memory, guestAccessToken: guestAccessToken)
    }

    func importContentMemory(session: SupabaseSession, memory: MemoryEntry, guestAccessToken: String? = nil) async throws -> MemoryEntry {
        let path = "\(session.userID)/\(memory.id.uuidString.lowercased()).jpg"
        let content = SupabaseContentMemory(memory: memory, imagePath: path)
        try content.validate()
        guard [3, 6, 12].contains(content.sentences.count) else { throw SupabaseServiceError.invalidResponse }
        let existing: SupabaseContentMemory? = try await contentRPC(session: session, name: "get_memory_v2",
            payload: ["p_memory_id": memory.id.uuidString.lowercased()])
        if let existing {
            try existing.validate()
        } else {
            guard !memory.imageData.isEmpty else { throw SupabaseServiceError.invalidResponse }
            // After commit, Storage intentionally rejects old-style writes to non-legacy images.
            try await uploadMemoryImage(session: session, path: path, data: memory.imageData)
        }
        // The import transaction owns memory + sentence insertion and preserves all source UUIDs.
        let request = try makeRequest(path: "/functions/v1/import-guest-memories-v1", method: "POST",
            bearerToken: session.accessToken, body: SupabaseContentImportRequest(memories: [content], guestAccessToken: guestAccessToken))
        let response: SupabaseContentImportResponse = try await perform(request)
        guard response.schemaVersion == 1, response.results.count == 1,
              let result = response.results.first, result.id == memory.id else {
            throw SupabaseServiceError.invalidResponse
        }
        guard result.imported else {
            throw SupabaseServiceError.apiError(result.code ?? "import_failed")
        }
        return try (existing ?? content).memory(imageData: memory.imageData, isAnonymous: false)
    }
}
