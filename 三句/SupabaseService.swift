//
//  SupabaseService.swift
//  三句
//
//  Created by Codex.
//

import Foundation

protocol SupabaseServicing {
    var isConfigured: Bool { get }

    func signInWithEmail(email: String, password: String) async throws -> SupabaseSession
    func signUpWithEmail(email: String, password: String, nickname: String) async throws -> SupabaseEmailSignUpResult
    func requestPasswordReset(email: String) async throws
    func updatePassword(session: SupabaseSession, newPassword: String) async throws
    func verifyRecoveryOTP(email: String, token: String) async throws -> SupabaseSession
    func signInAnonymously() async throws -> SupabaseSession
    func refreshSession(refreshToken: String) async throws -> SupabaseSession
    func fetchCurrentUser(session: SupabaseSession) async throws -> SupabaseCurrentAuthUserResponse
    func upsertProfile(
        session: SupabaseSession,
        appleUserID: String,
        nickname: String,
        email: String?,
        englishLevel: EnglishLevel,
        languageStyle: LanguageStyle,
        initialAvailableGenerations: Int?
    ) async throws -> SupabaseProfileRecord
    func fetchProfile(session: SupabaseSession) async throws -> SupabaseProfileRecord?
    func updateProfile(
        session: SupabaseSession,
        nickname: String?,
        englishLevel: EnglishLevel?,
        languageStyle: LanguageStyle?
    ) async throws -> SupabaseProfileRecord?
    func updateAnonymousStarterCredits(
        session: SupabaseSession,
        availableGenerations: Int
    ) async throws -> SupabaseProfileRecord?
    func confirmPurchase(
        session: SupabaseSession,
        transactionID: String,
        productID: String
    ) async throws -> Int
    func generateMemorySentences(
        session: SupabaseSession,
        imageData: Data,
        englishLevel: EnglishLevel,
        languageStyle: LanguageStyle,
        guestJobID: String?
    ) async throws -> SupabaseGenerateMemoryResult
    func recoverGuestGeneration(
        session: SupabaseSession,
        imageData: Data,
        guestJobID: String
    ) async throws -> SupabaseGuestGenerationRecoveryResult?
    func deleteAccount(session: SupabaseSession) async throws
    func migrateGuestCredits(
        session: SupabaseSession,
        guestRefreshToken: String,
        guestUserID: String
    ) async throws -> SupabaseProfileRecord
    func uploadMemoryImage(session: SupabaseSession, path: String, data: Data) async throws
    func downloadMemoryImage(session: SupabaseSession, path: String) async throws -> Data
    func deleteMemoryImage(session: SupabaseSession, path: String) async throws
    func fetchMemories(session: SupabaseSession) async throws -> [SupabaseMemoryRecord]
    func createMemoryCopy(session: SupabaseSession, memory: MemoryEntry) async throws -> MemoryEntry
    func fetchMemoriesCount(session: SupabaseSession) async throws -> Int
    func fetchFavoriteSentencesCount(session: SupabaseSession) async throws -> Int
    func fetchSentenceStudyDueCount(session: SupabaseSession) async throws -> Int
    func fetchSentenceStudyTodayCount(session: SupabaseSession) async throws -> Int
    func fetchSentenceStudyReviewableTodayCount(session: SupabaseSession) async throws -> Int
    func fetchSentenceStudyQueue(
        session: SupabaseSession,
        limit: Int
    ) async throws -> [SentenceStudyQueueItem]
    func fetchSentenceStudyTodayReviewQueue(
        session: SupabaseSession,
        limit: Int
    ) async throws -> [SentenceStudyQueueItem]
    func recordSentenceStudyResult(
        session: SupabaseSession,
        sentenceID: UUID,
        wasCorrect: Bool
    ) async throws -> SentenceStudyProgress
    func mergeLocalSentenceStudyProgress(
        session: SupabaseSession,
        progressRecords: [LocalSentenceStudyProgress]
    ) async throws -> Set<UUID>
    func updateSentenceFavorite(
        session: SupabaseSession,
        sentenceID: UUID,
        isFavorite: Bool
    ) async throws
    func deleteMemory(
        session: SupabaseSession,
        memoryID: UUID,
        imagePath: String?
    ) async throws
}

extension SupabaseServicing {
    func upsertProfile(
        session: SupabaseSession,
        appleUserID: String,
        nickname: String,
        email: String?,
        englishLevel: EnglishLevel,
        languageStyle: LanguageStyle
    ) async throws -> SupabaseProfileRecord {
        try await upsertProfile(
            session: session,
            appleUserID: appleUserID,
            nickname: nickname,
            email: email,
            englishLevel: englishLevel,
            languageStyle: languageStyle,
            initialAvailableGenerations: nil
        )
    }

    func updateProfile(
        session: SupabaseSession,
        nickname: String
    ) async throws -> SupabaseProfileRecord? {
        try await updateProfile(
            session: session,
            nickname: nickname,
            englishLevel: nil,
            languageStyle: nil
        )
    }

    func updateProfile(
        session: SupabaseSession,
        englishLevel: EnglishLevel,
        languageStyle: LanguageStyle
    ) async throws -> SupabaseProfileRecord? {
        try await updateProfile(
            session: session,
            nickname: nil,
            englishLevel: englishLevel,
            languageStyle: languageStyle
        )
    }
}

struct SupabaseService: SupabaseServicing {
    private let session: URLSession = .shared
    private let memoryBucket = "memories"
    private let authRequestTimeout: TimeInterval = 90
    private let memoryFetchPageSize = 100

    private var baseURL: URL? {
        guard let raw = Bundle.main.supabaseURL else {
            return nil
        }
        return URL(string: raw)
    }

    private var publishableKey: String? {
        Bundle.main.supabasePublishableKey
    }

    var isConfigured: Bool {
        baseURL != nil && !(publishableKey?.isEmpty ?? true)
    }

    private func debugLog(_ message: @autoclosure () -> String) {
        #if DEBUG
        print("[SupabaseService] \(message())")
        #endif
    }

    private static func sentenceStudyDayString(from date: Date?) -> String? {
        guard let date else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    func signInWithEmail(email: String, password: String) async throws -> SupabaseSession {
        var request = try makeRequest(
            path: "/auth/v1/token?grant_type=password",
            method: "POST",
            bearerToken: nil,
            body: SupabaseEmailSignInRequest(
                email: email,
                password: password
            )
        )
        applyAuthRequestSettings(to: &request)

        let response: SupabaseAuthResponse = try await perform(request, retryOnTimeout: 1)
        return response.session
    }

    func signUpWithEmail(email: String, password: String, nickname: String) async throws -> SupabaseEmailSignUpResult {
        var request = try makeRequest(
            path: "/auth/v1/signup",
            method: "POST",
            bearerToken: nil,
            body: SupabaseEmailSignUpRequest(
                email: email,
                password: password,
                data: SupabaseEmailSignUpUserMetadata(nickname: nickname)
            )
        )
        applyAuthRequestSettings(to: &request)

        let response: SupabaseOptionalAuthResponse = try await perform(request, retryOnTimeout: 1)
        if let session = response.session {
            return .session(session)
        }

        return .requiresEmailConfirmation
    }

    func requestPasswordReset(email: String) async throws {
        var request = try makeRequest(
            path: "/auth/v1/recover",
            method: "POST",
            bearerToken: nil,
            body: SupabasePasswordResetRequest(email: email)
        )
        applyAuthRequestSettings(to: &request)

        _ = try await performWithoutBody(request, retryOnTimeout: 1)
    }

    func updatePassword(session: SupabaseSession, newPassword: String) async throws {
        var request = try makeRequest(
            path: "/auth/v1/user",
            method: "PUT",
            bearerToken: session.accessToken,
            body: SupabasePasswordUpdateRequest(password: newPassword)
        )
        applyAuthRequestSettings(to: &request)

        _ = try await performWithoutBody(request, retryOnTimeout: 1)
    }

    func verifyRecoveryOTP(email: String, token: String) async throws -> SupabaseSession {
        var request = try makeRequest(
            path: "/auth/v1/verify",
            method: "POST",
            bearerToken: nil,
            body: SupabaseVerifyRecoveryOTPRequest(
                email: email,
                token: token,
                type: "recovery"
            )
        )
        applyAuthRequestSettings(to: &request)

        let response: SupabaseAuthResponse = try await perform(request, retryOnTimeout: 1)
        return response.session
    }

    func signInAnonymously() async throws -> SupabaseSession {
        let request = try makeRequest(
            path: "/auth/v1/signup",
            method: "POST",
            bearerToken: nil,
            body: SupabaseAnonymousSignInRequest()
        )

        let response: SupabaseAuthResponse = try await perform(request)
        return response.session
    }

    func refreshSession(refreshToken: String) async throws -> SupabaseSession {
        let request = try makeRequest(
            path: "/auth/v1/token?grant_type=refresh_token",
            method: "POST",
            bearerToken: nil,
            body: SupabaseRefreshRequest(refreshToken: refreshToken)
        )

        let response: SupabaseAuthResponse = try await perform(request)
        return response.session
    }

    func fetchCurrentUser(session: SupabaseSession) async throws -> SupabaseCurrentAuthUserResponse {
        let request = try makeRequest(
            path: "/auth/v1/user",
            method: "GET",
            bearerToken: session.accessToken
        )

        let response: SupabaseCurrentAuthUserResponse = try await perform(request)
        return response
    }

    func upsertProfile(
        session: SupabaseSession,
        appleUserID: String,
        nickname: String,
        email: String?,
        englishLevel: EnglishLevel,
        languageStyle: LanguageStyle,
        initialAvailableGenerations: Int? = nil
    ) async throws -> SupabaseProfileRecord {
        let request = try makeRequest(
            path: "/rest/v1/profiles?on_conflict=id",
            method: "POST",
            bearerToken: session.accessToken,
            additionalHeaders: [
                "Prefer": "return=representation,resolution=merge-duplicates"
            ],
            body: [
                SupabaseProfileUpsertPayload(
                    id: session.userID,
                    appleUserID: appleUserID,
                    nickname: nickname,
                    email: email,
                    englishLevel: englishLevel.rawValue,
                    languageStyle: languageStyle.rawValue,
                    initialAvailableGenerations: initialAvailableGenerations
                )
            ]
        )

        let records: [SupabaseProfileRecord] = try await perform(request)
        guard let record = records.first else {
            throw SupabaseServiceError.invalidResponse
        }
        return record
    }

    func fetchProfile(session: SupabaseSession) async throws -> SupabaseProfileRecord? {
        let select = "id,apple_user_id,nickname,email,english_level,language_style,available_generations"
        let request = try makeRequest(
            path: "/rest/v1/profiles?id=eq.\(session.userID)&select=\(select.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? select)",
            method: "GET",
            bearerToken: session.accessToken
        )

        let records: [SupabaseProfileRecord] = try await perform(request)
        return records.first
    }

    func updateProfile(
        session: SupabaseSession,
        nickname: String? = nil,
        englishLevel: EnglishLevel? = nil,
        languageStyle: LanguageStyle? = nil
    ) async throws -> SupabaseProfileRecord? {
        let request = try makeRequest(
            path: "/rest/v1/profiles?id=eq.\(session.userID)",
            method: "PATCH",
            bearerToken: session.accessToken,
            additionalHeaders: [
                "Prefer": "return=representation"
            ],
            body: SupabaseProfilePatchPayload(
                nickname: nickname,
                englishLevel: englishLevel?.rawValue,
                languageStyle: languageStyle?.rawValue
            )
        )

        let records: [SupabaseProfileRecord] = try await perform(request)
        return records.first
    }

    func updateAnonymousStarterCredits(
        session: SupabaseSession,
        availableGenerations: Int
    ) async throws -> SupabaseProfileRecord? {
        guard session.isAnonymous else {
            throw SupabaseServiceError.apiError("Only anonymous profiles can sync starter credits.")
        }

        let request = try makeRequest(
            path: "/rest/v1/profiles?id=eq.\(session.userID)",
            method: "PATCH",
            bearerToken: session.accessToken,
            additionalHeaders: [
                "Prefer": "return=representation"
            ],
            body: [
                "available_generations": availableGenerations
            ]
        )

        let records: [SupabaseProfileRecord] = try await perform(request)
        return records.first
    }

    func confirmPurchase(
        session: SupabaseSession,
        transactionID: String,
        productID: String
    ) async throws -> Int {
        let request = try makeRequest(
            path: "/functions/v1/confirm-purchase",
            method: "POST",
            bearerToken: session.accessToken,
            body: SupabaseConfirmPurchaseRequest(
                transactionID: transactionID,
                productID: productID
            )
        )

        let response: SupabaseConfirmPurchaseResponse = try await perform(request)
        return response.remainingCredits
    }

    func generateMemorySentences(
        session: SupabaseSession,
        imageData: Data,
        englishLevel: EnglishLevel,
        languageStyle: LanguageStyle,
        guestJobID: String?
    ) async throws -> SupabaseGenerateMemoryResult {
        let request = try makeRequest(
            path: "/functions/v1/generate-memory-v2",
            method: "POST",
            bearerToken: session.accessToken,
            body: SupabaseGenerateMemoryRequest(
                imageBase64: imageData.base64EncodedString(),
                englishLevel: englishLevel.rawValue,
                languageStyle: languageStyle.rawValue,
                guestJobID: guestJobID
            )
        )

        let response: SupabaseGenerateMemoryResponse = try await perform(request)
        guard response.memory.sentences.count == 3,
              let memoryID = UUID(uuidString: response.memory.id) else {
            throw SupabaseServiceError.invalidResponse
        }

        let sentences = response.memory.sentences.compactMap { sentence -> SentenceRecord? in
            let sentenceID = sentence.id.flatMap(UUID.init(uuidString:)) ?? UUID()
            let english = sentence.english.trimmingCharacters(in: .whitespacesAndNewlines)
            let chinese = sentence.chinese.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !english.isEmpty, !chinese.isEmpty else { return nil }
            return SentenceRecord(
                id: sentenceID,
                english: english,
                chinese: chinese,
                isFavorite: sentence.isFavorite ?? false
            )
        }

        guard sentences.count == 3 else {
            throw SupabaseServiceError.invalidResponse
        }

        return SupabaseGenerateMemoryResult(
            memory: MemoryEntry(
                id: memoryID,
                createdAt: response.memory.createdAt,
                imageData: imageData,
                remoteImagePath: response.memory.imagePath,
                syncedToAccount: !session.isAnonymous,
                sentences: sentences
            ),
            remainingCredits: response.remainingCredits,
            guestJobID: response.guestJobID
        )
    }

    func recoverGuestGeneration(
        session: SupabaseSession,
        imageData: Data,
        guestJobID: String
    ) async throws -> SupabaseGuestGenerationRecoveryResult? {
        let request = try makeRequest(
            path: "/functions/v1/recover-guest-generation",
            method: "POST",
            bearerToken: session.accessToken,
            body: SupabaseRecoverGuestGenerationRequest(guestJobID: guestJobID)
        )

        let response: SupabaseRecoverGuestGenerationResponse = try await perform(request)
        guard response.recovered else { return nil }
        guard let guestJobID = response.guestJobID,
              let memory = response.memory,
              memory.sentences.count == 3,
              let memoryID = UUID(uuidString: memory.id) else {
            throw SupabaseServiceError.invalidResponse
        }

        let sentences = memory.sentences.compactMap { sentence -> SentenceRecord? in
            let sentenceID = sentence.id.flatMap(UUID.init(uuidString:)) ?? UUID()
            let english = sentence.english.trimmingCharacters(in: .whitespacesAndNewlines)
            let chinese = sentence.chinese.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !english.isEmpty, !chinese.isEmpty else { return nil }
            return SentenceRecord(
                id: sentenceID,
                english: english,
                chinese: chinese,
                isFavorite: sentence.isFavorite ?? false
            )
        }

        guard sentences.count == 3, let remainingCredits = response.remainingCredits else {
            throw SupabaseServiceError.invalidResponse
        }

        return SupabaseGuestGenerationRecoveryResult(
            guestJobID: guestJobID,
            memory: MemoryEntry(
                id: memoryID,
                createdAt: memory.createdAt,
                imageData: imageData,
                remoteImagePath: nil,
                syncedToAccount: false,
                sentences: sentences
            ),
            remainingCredits: remainingCredits
        )
    }

    func deleteAccount(session: SupabaseSession) async throws {
        let request = try makeRequest(
            path: "/functions/v1/delete-account",
            method: "POST",
            bearerToken: session.accessToken
        )

        let _: SupabaseDeleteAccountResponse = try await perform(request)
    }

    func migrateGuestCredits(
        session: SupabaseSession,
        guestRefreshToken: String,
        guestUserID: String
    ) async throws -> SupabaseProfileRecord {
        let request = try makeRequest(
            path: "/functions/v1/migrate-guest-credits",
            method: "POST",
            bearerToken: session.accessToken,
            body: SupabaseMigrateGuestCreditsRequest(
                guestRefreshToken: guestRefreshToken,
                guestUserID: guestUserID
            )
        )

        let response: SupabaseMigrateGuestCreditsResponse = try await perform(request)
        guard response.guestUserID == guestUserID else {
            throw SupabaseServiceError.invalidResponse
        }
        return response.profile
    }

    func uploadMemoryImage(session: SupabaseSession, path: String, data: Data) async throws {
        var request = try makeRequest(
            path: "/storage/v1/object/\(memoryBucket)/\(path)",
            method: "POST",
            bearerToken: session.accessToken,
            additionalHeaders: [
                "x-upsert": "true",
                "Content-Type": "image/jpeg"
            ]
        )
        request.httpBody = data
        _ = try await performWithoutBody(request)
    }

    func downloadMemoryImage(session: SupabaseSession, path: String) async throws -> Data {
        let request = try makeRequest(
            path: "/storage/v1/object/authenticated/\(memoryBucket)/\(path)",
            method: "GET",
            bearerToken: session.accessToken
        )

        let (data, response) = try await self.session.data(for: request)
        try validate(response: response, data: data)
        return data
    }

    func deleteMemoryImage(session: SupabaseSession, path: String) async throws {
        let request = try makeRequest(
            path: "/storage/v1/object/\(memoryBucket)",
            method: "DELETE",
            bearerToken: session.accessToken,
            body: SupabaseStorageRemoveRequest(prefixes: [path])
        )
        _ = try await performWithoutBody(request)
    }

    func fetchMemories(session: SupabaseSession) async throws -> [SupabaseMemoryRecord] {
        let select = "id,image_url,created_at,memory_sentences(id,sort_order,english,chinese,is_favorite)"
        let encodedSelect = select.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? select
        let path = "/rest/v1/memories?select=\(encodedSelect)&order=created_at.desc"
        var allRecords: [SupabaseMemoryRecord] = []
        var lowerBound = 0

        while true {
            let upperBound = lowerBound + memoryFetchPageSize - 1
            let request = try makeRequest(
                path: path,
                method: "GET",
                bearerToken: session.accessToken,
                additionalHeaders: [
                    "Range-Unit": "items",
                    "Range": "\(lowerBound)-\(upperBound)"
                ]
            )

            let page: [SupabaseMemoryRecord] = try await perform(request)
            allRecords.append(contentsOf: page)

            guard page.count == memoryFetchPageSize else {
                break
            }

            lowerBound += memoryFetchPageSize
        }

        return allRecords
    }

    func createMemoryCopy(session: SupabaseSession, memory: MemoryEntry) async throws -> MemoryEntry {
        let memoryID = memory.id
        let imagePath = "\(session.userID)/\(memoryID.uuidString.lowercased()).jpg"

        try await uploadMemoryImage(session: session, path: imagePath, data: memory.imageData)

        let insertMemoryRequest = try makeRequest(
            path: "/rest/v1/memories",
            method: "POST",
            bearerToken: session.accessToken,
            additionalHeaders: [
                "Prefer": "return=representation,resolution=merge-duplicates"
            ],
            body: [
                SupabaseMemoryInsertPayload(
                    id: memoryID.uuidString.lowercased(),
                    userID: session.userID,
                    imagePath: imagePath,
                    createdAt: memory.createdAt
                )
            ]
        )

        let insertedMemories: [SupabaseInsertedMemoryRecord] = try await perform(insertMemoryRequest)
        guard let insertedMemory = insertedMemories.first else {
            throw SupabaseServiceError.invalidResponse
        }

        let sentencePayloads = memory.sentences.enumerated().map { index, sentence in
            SupabaseMemorySentenceInsertPayload(
                id: sentence.id.uuidString.lowercased(),
                memoryID: memoryID.uuidString.lowercased(),
                sortOrder: index + 1,
                english: sentence.english,
                chinese: sentence.chinese,
                isFavorite: sentence.isFavorite
            )
        }

        let insertSentenceRequest = try makeRequest(
            path: "/rest/v1/memory_sentences",
            method: "POST",
            bearerToken: session.accessToken,
            additionalHeaders: [
                "Prefer": "resolution=merge-duplicates"
            ],
            body: sentencePayloads
        )

        _ = try await performWithoutBody(insertSentenceRequest)

        let migratedSentences = memory.sentences.enumerated().map { index, sentence in
            SentenceRecord(
                id: UUID(uuidString: sentencePayloads[index].id) ?? sentence.id,
                english: sentence.english,
                chinese: sentence.chinese,
                isFavorite: sentence.isFavorite
            )
        }

        return MemoryEntry(
            id: memoryID,
            createdAt: insertedMemory.createdAt,
            imageData: memory.imageData,
            remoteImagePath: imagePath,
            syncedToAccount: true,
            sentences: migratedSentences
        )
    }

    func fetchMemoriesCount(session: SupabaseSession) async throws -> Int {
        let request = try makeCountRequest(
            path: "/rest/v1/memories?select=id",
            bearerToken: session.accessToken
        )
        return try await performCount(request)
    }

    func fetchFavoriteSentencesCount(session: SupabaseSession) async throws -> Int {
        let select = "id,memories!inner(id)"
        let encodedSelect = select.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? select
        let path = "/rest/v1/memory_sentences?select=\(encodedSelect)&is_favorite=eq.true&memories.user_id=eq.\(session.userID)"
        let request = try makeCountRequest(
            path: path,
            bearerToken: session.accessToken
        )
        return try await performCount(request)
    }

    func fetchSentenceStudyDueCount(session: SupabaseSession) async throws -> Int {
        let request = try makeRequest(
            path: "/rest/v1/rpc/count_sentence_study_queue",
            method: "POST",
            bearerToken: session.accessToken
        )
        return try await perform(request)
    }

    func fetchSentenceStudyTodayCount(session: SupabaseSession) async throws -> Int {
        let request = try makeRequest(
            path: "/rest/v1/rpc/count_sentence_studied_today",
            method: "POST",
            bearerToken: session.accessToken
        )
        return try await perform(request)
    }

    func fetchSentenceStudyReviewableTodayCount(session: SupabaseSession) async throws -> Int {
        let request = try makeRequest(
            path: "/rest/v1/rpc/count_sentence_studied_today_reviewable",
            method: "POST",
            bearerToken: session.accessToken
        )
        return try await perform(request)
    }

    func fetchSentenceStudyQueue(
        session: SupabaseSession,
        limit: Int = 5
    ) async throws -> [SentenceStudyQueueItem] {
        let request = try makeRequest(
            path: "/rest/v1/rpc/get_sentence_study_queue",
            method: "POST",
            bearerToken: session.accessToken,
            body: SupabaseSentenceStudyQueueRequest(limit: limit)
        )
        let records: [SupabaseSentenceStudyQueueRecord] = try await perform(request)
        return records.compactMap(Self.makeSentenceStudyQueueItem(from:))
    }

    func fetchSentenceStudyTodayReviewQueue(
        session: SupabaseSession,
        limit: Int
    ) async throws -> [SentenceStudyQueueItem] {
        let request = try makeRequest(
            path: "/rest/v1/rpc/get_sentence_studied_today_queue",
            method: "POST",
            bearerToken: session.accessToken,
            body: SupabaseSentenceStudyQueueRequest(limit: limit)
        )
        let records: [SupabaseSentenceStudyQueueRecord] = try await perform(request)
        return records.compactMap(Self.makeSentenceStudyQueueItem(from:))
    }

    func recordSentenceStudyResult(
        session: SupabaseSession,
        sentenceID: UUID,
        wasCorrect: Bool
    ) async throws -> SentenceStudyProgress {
        let request = try makeRequest(
            path: "/rest/v1/rpc/record_sentence_study_result",
            method: "POST",
            bearerToken: session.accessToken,
            body: SupabaseSentenceStudyResultRequest(
                sentenceID: sentenceID.uuidString.lowercased(),
                wasCorrect: wasCorrect
            )
        )
        let record: SupabaseSentenceStudyProgressRecord = try await perform(request)
        guard let progress = Self.makeSentenceStudyProgress(from: record) else {
            throw SupabaseServiceError.invalidResponse
        }
        return progress
    }

    func mergeLocalSentenceStudyProgress(
        session: SupabaseSession,
        progressRecords: [LocalSentenceStudyProgress]
    ) async throws -> Set<UUID> {
        guard !progressRecords.isEmpty else { return [] }

        let items = progressRecords.map { progress in
            SupabaseLocalSentenceStudyProgressMergeItem(
                sentenceID: progress.sentenceID.uuidString.lowercased(),
                learningStep: progress.learningStep,
                masteredReviewCount: progress.masteredReviewCount,
                correctCount: progress.correctCount,
                wrongCount: progress.wrongCount,
                lastResult: progress.lastResult?.rawValue,
                lastStudiedAt: progress.lastStudiedAt,
                lastStudiedOn: Self.sentenceStudyDayString(from: progress.lastStudiedDay),
                nextReviewOn: Self.sentenceStudyDayString(from: progress.nextReviewDay) ?? Self.sentenceStudyDayString(from: Date()) ?? ""
            )
        }

        let request = try makeRequest(
            path: "/rest/v1/rpc/merge_local_sentence_study_progress",
            method: "POST",
            bearerToken: session.accessToken,
            body: SupabaseLocalSentenceStudyProgressMergeRequest(items: items)
        )
        let records: [SupabaseMergedSentenceStudyProgressRecord] = try await perform(request)
        return Set(records.compactMap { UUID(uuidString: $0.sentenceID) })
    }

    func updateSentenceFavorite(
        session: SupabaseSession,
        sentenceID: UUID,
        isFavorite: Bool
    ) async throws {
        let request = try makeRequest(
            path: "/rest/v1/memory_sentences?id=eq.\(sentenceID.uuidString.lowercased())",
            method: "PATCH",
            bearerToken: session.accessToken,
            body: SupabaseSentenceFavoritePatchPayload(isFavorite: isFavorite)
        )

        _ = try await performWithoutBody(request)
    }

    func deleteMemory(
        session: SupabaseSession,
        memoryID: UUID,
        imagePath: String?
    ) async throws {
        if let imagePath {
            let storageRequest = try makeRequest(
                path: "/storage/v1/object/\(memoryBucket)",
                method: "DELETE",
                bearerToken: session.accessToken,
                body: SupabaseStorageRemoveRequest(prefixes: [imagePath])
            )
            _ = try await performWithoutBody(storageRequest)
        }

        let dbRequest = try makeRequest(
            path: "/rest/v1/memories?id=eq.\(memoryID.uuidString.lowercased())",
            method: "DELETE",
            bearerToken: session.accessToken
        )
        _ = try await performWithoutBody(dbRequest)
    }

    private func makeRequest<T: Encodable>(
        path: String,
        method: String,
        bearerToken: String?,
        additionalHeaders: [String: String] = [:],
        body: T
    ) throws -> URLRequest {
        var request = try makeRequest(path: path, method: method, bearerToken: bearerToken, additionalHeaders: additionalHeaders)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        request.httpBody = try encoder.encode(body)
        return request
    }

    private func makeRequest(
        path: String,
        method: String,
        bearerToken: String?,
        additionalHeaders: [String: String] = [:]
    ) throws -> URLRequest {
        guard let baseURL, let publishableKey, !publishableKey.isEmpty else {
            throw SupabaseServiceError.missingConfiguration
        }

        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw SupabaseServiceError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        request.setValue(publishableKey, forHTTPHeaderField: "apikey")
        additionalHeaders.forEach { key, value in
            request.setValue(value, forHTTPHeaderField: key)
        }

        if let bearerToken {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }

        return request
    }

    private func makeCountRequest(path: String, bearerToken: String?) throws -> URLRequest {
        try makeRequest(
            path: path,
            method: "HEAD",
            bearerToken: bearerToken,
            additionalHeaders: [
                "Prefer": "count=exact"
            ]
        )
    }

    private static func makeSentenceStudyQueueItem(
        from record: SupabaseSentenceStudyQueueRecord
    ) -> SentenceStudyQueueItem? {
        guard let sentenceID = UUID(uuidString: record.sentenceID),
              let memoryID = UUID(uuidString: record.memoryID) else {
            return nil
        }

        return SentenceStudyQueueItem(
            sentenceID: sentenceID,
            memoryID: memoryID,
            english: record.english,
            chinese: record.chinese,
            imagePath: record.imagePath,
            createdAt: record.createdAt,
            learningStep: record.learningStep,
            masteredReviewCount: record.masteredReviewCount,
            correctCount: record.correctCount,
            wrongCount: record.wrongCount,
            lastResult: record.lastResult.flatMap(SentenceStudyResult.init(rawValue:)),
            nextReviewAt: record.nextReviewAt
        )
    }

    private static func makeSentenceStudyProgress(
        from record: SupabaseSentenceStudyProgressRecord
    ) -> SentenceStudyProgress? {
        guard let id = UUID(uuidString: record.id),
              let sentenceID = UUID(uuidString: record.sentenceID) else {
            return nil
        }

        return SentenceStudyProgress(
            id: id,
            sentenceID: sentenceID,
            learningStep: record.learningStep,
            masteredReviewCount: record.masteredReviewCount,
            correctCount: record.correctCount,
            wrongCount: record.wrongCount,
            lastResult: record.lastResult.flatMap(SentenceStudyResult.init(rawValue:)),
            lastStudiedAt: record.lastStudiedAt,
            nextReviewAt: record.nextReviewAt
        )
    }

    private func perform<Response: Decodable>(_ request: URLRequest, retryOnTimeout: Int = 0) async throws -> Response {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError where urlError.code == .timedOut {
            debugLog("Request timed out -> \(request.httpMethod ?? "REQUEST") \(request.url?.absoluteString ?? "<missing-url>")")
            if retryOnTimeout > 0 {
                debugLog("Retrying request after timeout -> \(request.httpMethod ?? "REQUEST") \(request.url?.absoluteString ?? "<missing-url>") :: remaining_retries=\(retryOnTimeout)")
                return try await perform(request, retryOnTimeout: retryOnTimeout - 1)
            }
            throw SupabaseServiceError.apiError("request timed out")
        } catch {
            debugLog("Transport error -> \(request.httpMethod ?? "REQUEST") \(request.url?.absoluteString ?? "<missing-url>") :: \(error.localizedDescription)")
            throw error
        }
        try validate(response: response, data: data)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            try Self.decodeFlexibleISO8601Date(from: decoder)
        }
        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            if Self.isHTMLDocument(data) {
                debugLog("Decode failed with HTML response -> \(request.url?.absoluteString ?? "<missing-url>")")
                throw SupabaseServiceError.apiError("服务网关异常，请稍后重试。")
            }
            let decodingDetails = decodingErrorDescription(from: error)
            #if DEBUG
            let rawResponse = String(data: data, encoding: .utf8) ?? "<non-utf8 response>"
            let compactRawResponse = rawResponse
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let truncatedResponse = String(compactRawResponse.prefix(300))
            debugLog("Decode failed -> \(request.url?.absoluteString ?? "<missing-url>") :: \(decodingDetails) :: \(truncatedResponse)")
            #endif
            throw SupabaseServiceError.apiError("服务返回格式异常，请稍后重试。")
        }
    }

    private func performWithoutBody(_ request: URLRequest, retryOnTimeout: Int = 0) async throws -> HTTPURLResponse {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError where urlError.code == .timedOut {
            debugLog("Request timed out -> \(request.httpMethod ?? "REQUEST") \(request.url?.absoluteString ?? "<missing-url>")")
            if retryOnTimeout > 0 {
                debugLog("Retrying request after timeout -> \(request.httpMethod ?? "REQUEST") \(request.url?.absoluteString ?? "<missing-url>") :: remaining_retries=\(retryOnTimeout)")
                return try await performWithoutBody(request, retryOnTimeout: retryOnTimeout - 1)
            }
            throw SupabaseServiceError.apiError("request timed out")
        } catch {
            debugLog("Transport error -> \(request.httpMethod ?? "REQUEST") \(request.url?.absoluteString ?? "<missing-url>") :: \(error.localizedDescription)")
            throw error
        }
        try validate(response: response, data: data)
        guard let http = response as? HTTPURLResponse else {
            throw SupabaseServiceError.invalidResponse
        }
        _ = data
        return http
    }

    private func performCount(_ request: URLRequest) async throws -> Int {
        let response = try await performWithoutBody(request)
        guard let contentRange = response.value(forHTTPHeaderField: "Content-Range") else {
            throw SupabaseServiceError.invalidResponse
        }

        guard let totalPart = contentRange.split(separator: "/").last,
              let total = Int(totalPart) else {
            throw SupabaseServiceError.invalidResponse
        }

        return total
    }

    private func applyAuthRequestSettings(to request: inout URLRequest) {
        request.timeoutInterval = authRequestTimeout
        request.allowsCellularAccess = true
        request.allowsConstrainedNetworkAccess = true
        request.allowsExpensiveNetworkAccess = true
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SupabaseServiceError.invalidResponse
        }

        guard 200..<300 ~= httpResponse.statusCode else {
            let rawText = String(data: data, encoding: .utf8)?
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "<non-utf8 response>"
            debugLog("HTTP \(httpResponse.statusCode) <- \(httpResponse.url?.absoluteString ?? "<missing-url>") :: \(String(rawText.prefix(500)))")
            if httpResponse.statusCode == 429 {
                throw SupabaseServiceError.apiError("rate_limit_exceeded")
            }
            if Self.isHTMLDocument(data) {
                throw SupabaseServiceError.apiError("服务网关异常，请稍后重试。")
            }

            if let apiError = try? JSONDecoder().decode(SupabaseAPIError.self, from: data) {
                throw SupabaseServiceError.apiError(apiError.message)
            }

            if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                throw SupabaseServiceError.apiError(text)
            }

            throw SupabaseServiceError.invalidResponse
        }
    }

    private static func isHTMLDocument(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() else {
            return false
        }

        return text.hasPrefix("<!doctype html") || text.hasPrefix("<html")
    }

    nonisolated private static func decodeFlexibleISO8601Date(from decoder: Decoder) throws -> Date {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)

        let iso8601FractionalFormatter = ISO8601DateFormatter()
        iso8601FractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        if let date = iso8601FractionalFormatter.date(from: value) {
            return date
        }

        let iso8601Formatter = ISO8601DateFormatter()
        iso8601Formatter.formatOptions = [.withInternetDateTime]

        if let date = iso8601Formatter.date(from: value) {
            return date
        }

        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Invalid ISO8601 date: \(value)"
        )
    }

    private func decodingErrorDescription(from error: Error) -> String {
        guard let decodingError = error as? DecodingError else {
            return error.localizedDescription
        }

        switch decodingError {
        case .keyNotFound(let key, let context):
            return "缺少字段 \(codingPathDescription(from: context.codingPath + [key]))。"
        case .typeMismatch(_, let context):
            return "字段类型不匹配：\(codingPathDescription(from: context.codingPath))。"
        case .valueNotFound(_, let context):
            return "字段值缺失：\(codingPathDescription(from: context.codingPath))。"
        case .dataCorrupted(let context):
            return "数据损坏：\(codingPathDescription(from: context.codingPath))。"
        @unknown default:
            return error.localizedDescription
        }
    }

    private func codingPathDescription(from codingPath: [CodingKey]) -> String {
        guard !codingPath.isEmpty else {
            return "<root>"
        }

        return codingPath
            .map { key in
                if let intValue = key.intValue {
                    return "[\(intValue)]"
                }
                return key.stringValue
            }
            .joined(separator: ".")
            .replacingOccurrences(of: ".[", with: "[")
    }
}
