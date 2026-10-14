import Foundation
import XCTest
@testable import 三句

@MainActor
final class MultilingualClientContentTests: XCTestCase {
    private let session = SupabaseSession(accessToken: "test", refreshToken: "test", userID: "test-owner",
                                          expiresAt: .distantFuture, isAnonymous: false)

    private func memory(_ language: LearningLanguage = .spanish, favorite: Bool = true) -> MemoryEntry {
        let text = language == .japanese ? "こんにちは。" : "Bonjour."
        let material = language == .japanese ? SentenceLearningMaterial(textDigest: SentenceLearningMaterial.digest(text),
            segments: [.init(id: "s0", surface: text, kind: .phrase, canBlank: true)]) : nil
        return MemoryEntry(createdAt: Date(timeIntervalSince1970: 1_750_000_000.123456), imageData: Data([1, 2, 3]),
            tags: ["natural_scenery"], sentences: (0..<3).map { _ in
                SentenceRecord(targetText: text, translationText: "Hello.", learningMaterial: material, isFavorite: favorite)
            }, context: MemoryContentContext(targetLanguage: language,
                translationLanguage: language == .english ? .simplifiedChinese : .english,
                teachingLocale: language.teachingLocale))
    }

    private func wire(_ memory: MemoryEntry) throws -> [String: Any] {
        let dto = SupabaseContentMemory(memory: memory, imagePath: "test-owner/\(memory.id.uuidString.lowercased()).jpg")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(dto)) as? [String: Any])
    }

    private func service(_ replies: [Any]) throws -> SupabaseService {
        ContentTestURLProtocol.configure(try replies.map { try JSONSerialization.data(withJSONObject: $0, options: .fragmentsAllowed) })
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ContentTestURLProtocol.self]
        return SupabaseService(session: URLSession(configuration: configuration),
            baseURL: URL(string: "https://content.invalid")!, publishableKey: "test")
    }

    func testRemoteMappingAndImageMergePreserveJapaneseContent() throws {
        var original = memory(.japanese)
        original.remoteImagePath = "test-owner/photo.jpg"
        let record = try SupabaseContentMemory(memory: original, imagePath: original.remoteImagePath!).record()
        let manager = CloudSyncManager()
        let mapped = try XCTUnwrap(manager.makeRemoteMemories(from: [record], cachedMemories: [original]).first)
        XCTAssertEqual(mapped.context, original.context)
        XCTAssertEqual(mapped.sentences, original.sentences)
        XCTAssertEqual(mapped.imageData, original.imageData)

        let remoteWithoutPhoto = try manager.makeRemoteMemories(from: [record])
        let sync = MemorySyncState()
        let merged = sync.merge(remote: remoteWithoutPhoto, current: [original], queuedGuests: [],
            pendingFavorites: [], pendingDeletions: [], snapshot: sync.snapshot(memories: [original]))
        XCTAssertEqual(merged.first?.context, original.context)
        XCTAssertEqual(merged.first?.sentences, original.sentences)
        XCTAssertEqual(merged.first?.imageData, original.imageData)
        let reconciled = manager.reconcileLocalMemories(localMemories: [original], remoteMemories: [mapped],
            sessionUserID: "test-owner")
        XCTAssertEqual(reconciled.memories.first?.context, original.context)
        XCTAssertEqual(reconciled.memories.first?.sentences, original.sentences)
    }

    func testRemoteMappingRejectsUnknownVersionAndDuplicateIDs() throws {
        let original = memory(.japanese)
        let record = try SupabaseContentMemory(memory: original, imagePath: "test-owner/photo.jpg").record()
        let manager = CloudSyncManager()
        XCTAssertThrowsError(try manager.makeRemoteMemories(from: [record, record]))
        var unknown = record
        unknown.context = MemoryContentContext(schemaVersion: 99, targetLanguage: .japanese,
            translationLanguage: .english, teachingLocale: .standardJapanese)
        XCTAssertThrowsError(try manager.makeRemoteMemories(from: [record, unknown]))
    }

    func testSnapshotRecoveryNeverUsesLegacyTimingCandidate() throws {
        let original = memory(.english)
        let candidate = try CloudSyncManager().makeRemoteMemories(from: [
            SupabaseContentMemory(memory: original, imagePath: "test-owner/photo.jpg").record()
        ])
        var pending = PendingGeneratedMemoryImage(startedAt: original.createdAt, previousMemoryIDs: [],
            guestJobID: nil, clientRequestID: UUID().uuidString, imageData: original.imageData)
        let manager = CloudSyncManager()
        XCTAssertEqual(manager.legacyRecoveryCandidateIndex(for: pending, in: candidate), 0)
        pending.snapshot = GenerationRequestSnapshot(owner: "test-owner", accountRevision: UUID(),
            requestID: UUID(), guestJobID: nil,
            spec: GenerationSpec(selection: .legacyEnglish(explanationLanguage: .simplifiedChinese), level: .beginner),
            imageDigest: "digest", createdAt: original.createdAt)
        XCTAssertNil(manager.legacyRecoveryCandidateIndex(for: pending, in: candidate))
        pending.snapshot = nil
        let japanese = memory(.japanese)
        let nonlegacy = try manager.makeRemoteMemories(from: [
            SupabaseContentMemory(memory: japanese, imagePath: "test-owner/other.jpg").record()
        ])
        XCTAssertNil(manager.legacyRecoveryCandidateIndex(for: pending, in: nonlegacy))
    }

    func testAllTenPairsUseImmutableGenerationSpec() throws {
        var pairs = 0
        for support in SupportLanguage.allCases {
            for target in LanguageCatalog.targets(for: support) {
                let spec = GenerationSpec(selection: try .standard(target: target, support: support), level: .beginner)
                try spec.validate()
                let snapshot = GenerationRequestSnapshot(owner: "owner", accountRevision: UUID(), requestID: UUID(),
                    guestJobID: nil, spec: spec, imageDigest: "abc", createdAt: .now)
                let restored = try JSONDecoder().decode(GenerationRequestSnapshot.self, from: JSONEncoder().encode(snapshot))
                XCTAssertEqual(restored, snapshot)
                let payload = SupabaseContentGenerationRequest(imageBase64: "AQ==", generationSpec: snapshot.spec,
                    guestJobID: nil, clientRequestID: snapshot.requestID.uuidString)
                let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any])
                let encodedSpec = try XCTUnwrap(object["generationSpec"] as? [String: Any])
                XCTAssertEqual(encodedSpec["targetLanguage"] as? String, target.rawValue)
                XCTAssertEqual(encodedSpec["translationLanguage"] as? String, support.rawValue)
                XCTAssertNil(object["englishLevel"])
                pairs += 1
            }
        }
        XCTAssertEqual(pairs, 10)
    }

    func testAllLanguagePaginationPreservesExactCursorAndStableIDs() async throws {
        let spanish = memory(), japanese = memory(.japanese)
        let cursor = "2026-10-14T01:02:03.123456+00:00"
        let api = try service([
            ["schemaVersion": 2, "memories": [try wire(spanish)],
             "nextCursor": ["createdAt": cursor, "id": spanish.id.uuidString]],
            ["schemaVersion": 2, "memories": [try wire(japanese)], "nextCursor": NSNull()]
        ])
        let records = try await api.fetchMemories(session: session)
        XCTAssertEqual(records.map(\.context.targetLanguage), [.spanish, .japanese])
        XCTAssertEqual(records[0].createdAt.timeIntervalSince1970, spanish.createdAt.timeIntervalSince1970, accuracy: 0.000001)
        XCTAssertEqual(records[1].sentences.map(\.id), japanese.sentences.map { $0.id.uuidString.lowercased() })
        XCTAssertNotNil(records[1].sentences[0].learningMaterial)
        let requests = ContentTestURLProtocol.recordedRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests.allSatisfy { $0.url?.path == "/rest/v1/rpc/list_memories_v2" })
        let body = try ContentTestURLProtocol.body(requests[1])
        XCTAssertEqual(body["p_cursor_created_at"] as? String, cursor)
        XCTAssertTrue(body["p_target_language"] is NSNull)
    }

    func testUnknownSecondPageFailsInsteadOfReturningPartialAccount() async throws {
        let first = memory()
        let api = try service([
            ["schemaVersion": 2, "memories": [try wire(first)],
             "nextCursor": ["createdAt": "2026-10-14T00:00:00Z", "id": first.id.uuidString]],
            ["schemaVersion": 99, "memories": [], "nextCursor": NSNull()]
        ])
        do {
            _ = try await api.fetchMemories(session: session)
            XCTFail("Unknown page versions must not return a partial list")
        } catch {}
    }

    func testUnknownLanguageAndContentVersionAreRejected() async throws {
        for field in ["language", "version"] {
            var value = try wire(memory())
            if field == "language" {
                var context = try XCTUnwrap(value["context"] as? [String: Any])
                context["targetLanguage"] = "future-language"
                value["context"] = context
            } else {
                var sentences = try XCTUnwrap(value["sentences"] as? [[String: Any]])
                sentences[0]["contentVersion"] = 99
                value["sentences"] = sentences
            }
            let api = try service([["schemaVersion": 2, "memories": [value], "nextCursor": NSNull()]])
            do {
                _ = try await api.fetchMemories(session: session)
                XCTFail("Unknown content must fail the whole list")
            } catch {}
        }
    }

    func testRecoveryUsesV2AndKeepsLanguage() async throws {
        let original = memory(.french)
        let requestID = UUID().uuidString.lowercased()
        let api = try service([["status": "completed", "memory": try wire(original),
                                "remainingCredits": 7, "clientRequestID": requestID]])
        let result = try await api.recoverGeneration(session: session, imageData: original.imageData,
                                                     guestJobID: nil, clientRequestID: requestID)
        XCTAssertEqual(result?.memory.context, original.context)
        XCTAssertEqual(result?.memory.sentences.map(\.id), original.sentences.map(\.id))
        XCTAssertEqual(ContentTestURLProtocol.recordedRequests().first?.url?.path, "/functions/v1/recover-generation-v2")
    }

    func testGenerationRejectsMismatchedLanguage() async throws {
        let original = memory(.french)
        let requestID = UUID().uuidString.lowercased()
        let api = try service([["status": "completed", "memory": try wire(original), "remainingCredits": 7,
                                "clientRequestID": requestID]])
        let spec = GenerationSpec(selection: try .standard(target: .spanish, support: .english), level: .beginner)
        do {
            _ = try await api.generateMemorySentences(session: session, imageData: original.imageData,
                spec: spec, guestJobID: nil, clientRequestID: requestID)
            XCTFail("A mismatched server result must not be saved")
        } catch {}
        XCTAssertEqual(ContentTestURLProtocol.recordedRequests().first?.url?.path, "/functions/v1/generate-memory-v3")
    }

    func testGenerationUsesV3SnapshotSpecAndKeepsStableIDs() async throws {
        let original = memory()
        let requestID = UUID().uuidString.lowercased()
        let api = try service([["status": "completed", "memory": try wire(original), "remainingCredits": 7,
                                "clientRequestID": requestID]])
        let spec = GenerationSpec(selection: try .standard(target: .spanish, support: .english), level: .beginner)
        let result = try await api.generateMemorySentences(session: session, imageData: original.imageData,
            spec: spec, guestJobID: nil, clientRequestID: requestID)
        XCTAssertEqual(result.memory.context, spec.context)
        XCTAssertEqual(result.memory.sentences.map(\.id), original.sentences.map(\.id))
        let request = try XCTUnwrap(ContentTestURLProtocol.recordedRequests().first)
        let body = try ContentTestURLProtocol.body(request)
        let sentSpec = try XCTUnwrap(body["generationSpec"] as? [String: Any])
        XCTAssertEqual(sentSpec["targetLanguage"] as? String, "es")
        XCTAssertEqual(sentSpec["level"] as? String, "beginner")
        XCTAssertEqual(body["clientRequestID"] as? String, requestID)
    }

    func testGuestImportUploadsBeforeAtomicInsertWithProof() async throws {
        let original = memory()
        let api = try service([NSNull(), [:], ["schemaVersion": 1,
            "results": [["id": original.id.uuidString, "imported": true]]]])
        let result = try await api.createMemoryCopy(session: session, memory: original, guestAccessToken: "guest-proof")
        XCTAssertEqual(result.sentences.map(\.id), original.sentences.map(\.id))
        XCTAssertEqual(result.context, original.context)
        let requests = ContentTestURLProtocol.recordedRequests()
        XCTAssertEqual(requests.count, 3)
        XCTAssertTrue(requests[1].url!.path.hasPrefix("/storage/v1/object/memories/"))
        XCTAssertEqual(requests[2].url?.path, "/functions/v1/import-guest-memories-v1")
        XCTAssertEqual(try ContentTestURLProtocol.body(requests[2])["guestAccessToken"] as? String, "guest-proof")
    }

    func testGuestImportReplayDoesNotUploadOrResetRemoteFavorite() async throws {
        let original = memory()
        var remote = original
        remote.sentences[0].isFavorite = false
        let api = try service([try wire(remote), ["schemaVersion": 1,
            "results": [["id": original.id.uuidString, "imported": true]]]])
        let result = try await api.createMemoryCopy(session: session, memory: original)
        XCTAssertFalse(result.sentences[0].isFavorite)
        XCTAssertEqual(ContentTestURLProtocol.recordedRequests().count, 2)
    }

    func testV2CacheBacksUpLegacyBytesAndRetainsLanguageIDsAndPhoto() throws {
        let name = "MultilingualCacheTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let original = memory(.japanese)
        let old = try JSONEncoder().encode([original])
        defaults.set(old, forKey: "cache")
        try MemoryCachePersistence.write([original], key: "cache", userID: "owner", previousOwner: "owner", defaults: defaults)
        let backup = try JSONDecoder().decode(MemoryCachePersistence.Backup.self,
            from: XCTUnwrap(defaults.data(forKey: "cache.preV2Backup")))
        XCTAssertEqual(backup.data, old)
        let restored = try MemoryCachePersistence.decode([MemoryEntry].self,
            data: XCTUnwrap(defaults.data(forKey: "cache")), userID: "owner")
        XCTAssertEqual(restored, [original])
        XCTAssertEqual(try MemoryCachePersistence.owner(in: XCTUnwrap(defaults.data(forKey: "cache")), legacyOwner: "stale-owner"), "owner")
        XCTAssertThrowsError(try MemoryCachePersistence.decode([MemoryEntry].self,
            data: XCTUnwrap(defaults.data(forKey: "cache")), userID: "another-owner"))
    }

    func testUnknownAndCorruptCachesAreNeverOverwritten() throws {
        let name = "MultilingualCacheTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        for raw in [Data("broken".utf8), Data(#"{"schemaVersion":99,"userID":"owner","payload":[]}"#.utf8)] {
            defaults.set(raw, forKey: "cache")
            XCTAssertThrowsError(try MemoryCachePersistence.write([memory()], key: "cache", userID: "owner",
                previousOwner: "owner", defaults: defaults))
            XCTAssertEqual(defaults.data(forKey: "cache"), raw)
            XCTAssertNil(defaults.data(forKey: "cache.preV2Backup"))
        }
    }

    func testImportTimestampRetainsMicroseconds() throws {
        let value = try wire(memory())
        XCTAssertEqual(value["createdAt"] as? String, "2025-06-15T15:06:40.123456Z")
    }

    func testPreferenceRequestsUseVersionedRPCs() async throws {
        let api = try service([["schemaVersion": 1, "selection": NSNull(), "languages": []],
            ["schemaVersion": 1, "selection": NSNull(), "languages": []],
            ["schemaVersion": 1, "catalogVersion": 1, "voiceCatalogVersion": 1, "combinations": []]])
        _ = try await api.getLearningPreferences(session: session)
        _ = try await api.updateLearningPreferences(session: session,
            patch: LearningPreferencePatch(language: .init(targetLanguage: .spanish, level: .beginner, expectedLevelRevision: 0)))
        _ = try await api.getLanguageCapabilities(session: session)
        XCTAssertEqual(ContentTestURLProtocol.recordedRequests().map { $0.url!.lastPathComponent },
            ["get_learning_preferences_v1", "update_learning_preferences_v1", "get_language_capabilities_v1"])
    }

    func testUnfinishedActivationImportsWithoutInventingStudyResult() async throws {
        let sentenceID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_750_000_000)
        let activation = StudyActivationStore.Activation(ownerID: "guest", sentenceID: sentenceID,
            firstActivatedAt: startedAt, isLegacy: false)
        let api = try service([[["sentence_id": sentenceID.uuidString, "study_scope": "favorites"]]])
        let accepted = try await api.mergeLocalSentenceStudyProgress(session: session, progressRecords: [], activations: [activation])
        XCTAssertEqual(accepted, [SentenceStudyProgressKey(sentenceID: sentenceID, studyTopic: .favorites)])
        let request = try XCTUnwrap(ContentTestURLProtocol.recordedRequests().first)
        XCTAssertEqual(request.url?.lastPathComponent, "merge_local_sentence_study_progress_v2")
        let body = try ContentTestURLProtocol.body(request)
        let rows = try XCTUnwrap(body["p_items"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0]["correct_count"] as? Int, 0)
        XCTAssertEqual(rows[0]["learning_step"] as? Int, 0)
        XCTAssertNil(rows[0]["last_studied_at"])
        XCTAssertNil(rows[0]["last_result"])
        XCTAssertEqual(rows[0]["first_activated_at"] as? String, "2025-06-15T15:06:40Z")
    }

    func testLegacyActivationUsesHistoricalDateAndPreservesRealProgress() {
        let sentenceID = UUID()
        let activation = StudyActivationStore.Activation(ownerID: "guest", sentenceID: sentenceID,
            firstActivatedAt: .distantPast, isLegacy: true)
        let progress = LocalSentenceStudyProgress(sentenceID: sentenceID, learningStep: 2, correctCount: 2)
        let rows = SupabaseLocalSentenceStudyProgressMergeItem.guestImport(progressRecords: [progress], activations: [activation])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].firstActivatedAt, Date(timeIntervalSince1970: 0))
        XCTAssertEqual(rows[0].learningStep, 2)
        XCTAssertEqual(rows[0].correctCount, 2)
    }
}

private nonisolated final class ContentTestURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var replies: [Data] = []
    private nonisolated(unsafe) static var requests: [URLRequest] = []

    static func configure(_ values: [Data]) {
        lock.lock(); defer { lock.unlock() }
        replies = values; requests = []
    }
    static func recordedRequests() -> [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return requests
    }
    static func body(_ request: URLRequest) throws -> [String: Any] {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request)
        let data = Self.replies.isEmpty ? nil : Self.replies.removeFirst()
        Self.lock.unlock()
        guard let data else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200,
            httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
