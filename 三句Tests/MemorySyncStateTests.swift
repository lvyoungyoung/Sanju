import XCTest
@testable import 三句

@MainActor
final class MemorySyncStateTests: XCTestCase {
    private func memory(id: UUID = UUID(), favorite: Bool = false, synced: Bool = true) -> MemoryEntry {
        MemoryEntry(id: id, imageData: Data([1]), remoteImagePath: synced ? "owner/\(id).jpg" : nil,
                    syncedToAccount: synced, sentences: (0..<3).map {
            SentenceRecord(english: "Sentence \($0)", chinese: "Translation \($0)", isFavorite: favorite)
        })
    }

    func testRemoteFavoritesWinWhenCacheHasNoLocalEdits() {
        let state = MemorySyncState()
        let cached = memory()
        var remote = cached
        remote.sentences[0].isFavorite = true
        let result = state.merge(remote: [remote], current: [cached], queuedGuests: [], pendingFavorites: [],
                                 pendingDeletions: [], snapshot: state.snapshot(memories: [cached]))
        XCTAssertTrue(result[0].sentences[0].isFavorite)
        let plan = CloudSyncManager().makePlan(localMemories: [cached], remoteMemories: [remote],
            queuedGuestMemories: [], queuedMemoryDeletions: [], queuedFavoriteChanges: [], queuedLocalStudyProgress: [])
        XCTAssertEqual(plan.totalCount, 0)
    }

    func testPendingFavoriteSurvivesRefreshStartedAfterTheEdit() {
        let state = MemorySyncState()
        let remote = memory()
        var current = remote
        current.sentences[0].isFavorite = true
        let pending = PendingFavoriteChange(sentenceID: current.sentences[0].id, isFavorite: true)
        let result = state.merge(remote: [remote], current: [current], queuedGuests: [], pendingFavorites: [pending],
                                 pendingDeletions: [], snapshot: state.snapshot(memories: [current]))
        XCTAssertTrue(result[0].sentences[0].isFavorite)
    }

    func testAcknowledgedFavoriteChangedDuringFetchSurvivesWithoutAnOutboxEntry() {
        var state = MemorySyncState()
        let remote = memory()
        let snapshot = state.snapshot(memories: [remote])
        var current = remote
        current.sentences[0].isFavorite = true
        state.favoriteDidChange(sentenceID: current.sentences[0].id)
        let result = state.merge(remote: [remote], current: [current], queuedGuests: [], pendingFavorites: [],
                                 pendingDeletions: [], snapshot: snapshot)
        XCTAssertTrue(result[0].sentences[0].isFavorite)
    }

    func testRoundTripFavoriteChangeStillInvalidatesOldSnapshot() {
        var state = MemorySyncState()
        let current = memory()
        let snapshot = state.snapshot(memories: [current])
        var staleRemote = current
        staleRemote.sentences[0].isFavorite = true
        state.favoriteDidChange(sentenceID: current.sentences[0].id)
        state.favoriteDidChange(sentenceID: current.sentences[0].id)
        let result = state.merge(remote: [staleRemote], current: [current], queuedGuests: [], pendingFavorites: [],
                                 pendingDeletions: [], snapshot: snapshot)
        XCTAssertFalse(result[0].sentences[0].isFavorite)
    }

    func testDeletionCannotReturnAfterAcknowledgementOrFromGuestQueue() {
        var state = MemorySyncState()
        let deleted = memory(synced: false)
        let snapshot = state.snapshot(memories: [deleted])
        state.memoryWasDeleted(memoryID: deleted.id)
        let result = state.merge(remote: [deleted], current: [], queuedGuests: [deleted], pendingFavorites: [],
                                 pendingDeletions: [], snapshot: snapshot)
        XCTAssertTrue(result.isEmpty)
    }

    func testPendingDeletionSurvivesFetchStartedAfterDeletion() {
        let state = MemorySyncState()
        let deleted = memory()
        let result = state.merge(remote: [deleted], current: [], queuedGuests: [], pendingFavorites: [],
            pendingDeletions: [PendingMemoryDeletion(memoryID: deleted.id, remoteImagePath: deleted.remoteImagePath)],
            snapshot: state.snapshot(memories: []))
        XCTAssertTrue(result.isEmpty)
    }

    func testNewGenerationDuringFetchIsKeptButStaleRemoteDeletionIsNot() {
        let state = MemorySyncState()
        let stale = memory(), fresh = memory(), guest = memory(synced: false)
        let snapshot = state.snapshot(memories: [stale, guest])
        let result = state.merge(remote: [], current: [stale, fresh, guest], queuedGuests: [], pendingFavorites: [],
                                 pendingDeletions: [], snapshot: snapshot)
        XCTAssertEqual(Set(result.map(\.id)), [fresh.id, guest.id])
    }

    func testCachedImageIsKeptWhileRemoteMetadataUpdates() {
        let state = MemorySyncState()
        let cached = memory()
        let remote = MemoryEntry(id: cached.id, imageData: Data(), remoteImagePath: cached.remoteImagePath,
                                 syncedToAccount: true, tags: ["food_and_drinks"], sentences: cached.sentences)
        let result = state.merge(remote: [remote], current: [cached], queuedGuests: [], pendingFavorites: [],
                                 pendingDeletions: [], snapshot: state.snapshot(memories: [cached]))
        XCTAssertEqual(result[0].imageData, cached.imageData)
        XCTAssertEqual(result[0].tags, remote.tags)
    }

    func testOldOutboxDecodesAndNewOperationsHaveDistinctIDs() throws {
        let id = UUID()
        let old = Data("{\"sentenceID\":\"\(id)\",\"isFavorite\":true}".utf8)
        let decoded = try JSONDecoder().decode(PendingFavoriteChange.self, from: old)
        XCTAssertEqual(decoded.sentenceID, id)
        XCTAssertTrue(decoded.isFavorite)
        let next = PendingFavoriteChange(sentenceID: id, isFavorite: true)
        XCTAssertNotEqual(decoded.id, next.id)
        XCTAssertEqual(try JSONDecoder().decode(PendingFavoriteChange.self,
                                              from: JSONEncoder().encode(next)), next)
        let oldDeletion = Data("{\"memoryID\":\"\(id)\"}".utf8)
        let decodedDeletion = try JSONDecoder().decode(PendingMemoryDeletion.self, from: oldDeletion)
        XCTAssertEqual(decodedDeletion.memoryID, id)
        XCTAssertNil(decodedDeletion.remoteImagePath)
        XCTAssertNotEqual(decodedDeletion.id, PendingMemoryDeletion(memoryID: id, remoteImagePath: nil).id)
    }

    func testAnonymousFavoriteUpdatesTheDurableMigrationCopy() async {
        let model = AppModel()
        await model.ensureRemoteSessionRestoreCompleted()
        let guest = memory(synced: false)
        model.memories = [guest]
        model.upsertPendingGuestMemoryMigrationIfNeeded(guest)
        model.toggleFavorite(sentenceID: guest.sentences[0].id)
        XCTAssertTrue(model.pendingGuestMemoryMigrationQueue[0].sentences[0].isFavorite)
        model.loadPendingGuestMemoryMigrationQueue()
        XCTAssertTrue(model.pendingGuestMemoryMigrationQueue[0].sentences[0].isFavorite)
        model.clearPendingGuestMemoryMigrationQueue()
        model.clearPersistedMemories()
        model.memories = []
    }

    func testDeletedAnonymousMemoryDoesNotReturnOnLoginMerge() async {
        let model = AppModel()
        await model.ensureRemoteSessionRestoreCompleted()
        let guest = memory(synced: false)
        model.memories = [guest]
        model.upsertPendingGuestMemoryMigrationIfNeeded(guest)
        model.deleteMemory(memoryID: guest.id)
        XCTAssertTrue(model.pendingGuestMemoryMigrationQueue.isEmpty)
        model.mergePendingGuestMemoriesIntoCurrentMemoriesIfNeeded()
        XCTAssertTrue(model.memories.isEmpty)
        model.clearPendingGuestMemoryMigrationQueue()
        model.clearPersistedMemories()
    }

    func testSignOutIsBlockedForEachKindOfUnsentDataEvenAfterSyncFailed() async {
        let model = AppModel()
        await model.ensureRemoteSessionRestoreCompleted()
        // Disable preference/history services before installing a synthetic session: no network calls.
        model.generationPreferenceSync = nil
        model.speechPreferenceSync = nil
        model.albumFlipHistorySync = nil
        model.supabaseSession = SupabaseSession(accessToken: "test", refreshToken: "test",
            userID: UUID().uuidString, expiresAt: .distantFuture, isAnonymous: false)
        model.isSyncingPendingCloudChanges = false
        let guest = memory(synced: false)
        model.memories = [guest]
        model.pendingGuestMemoryMigrationQueue = [guest]
        model.signOut()
        XCTAssertEqual(model.memories, [guest])
        XCTAssertNotNil(model.supabaseSession)
        model.memories = []
        model.pendingGuestMemoryMigrationQueue = []
        model.pendingFavoriteChanges = [PendingFavoriteChange(sentenceID: UUID(), isFavorite: true)]
        XCTAssertTrue(model.shouldPreventSignOutForCloudChanges)
        model.pendingFavoriteChanges = []
        model.pendingMemoryDeletions = [PendingMemoryDeletion(memoryID: UUID(), remoteImagePath: nil)]
        XCTAssertTrue(model.shouldPreventSignOutForCloudChanges)
        model.pendingMemoryDeletions = []
        model.pendingMemoryImageUploads = [PendingMemoryImageUpload(memoryID: UUID(), remoteImagePath: "test")]
        XCTAssertTrue(model.shouldPreventSignOutForCloudChanges)
        model.pendingMemoryImageUploads = []
        XCTAssertFalse(model.shouldPreventSignOutForCloudChanges)
        model.signOut()
        XCTAssertNil(model.supabaseSession)
        model.clearPendingGuestMemoryMigrationQueue()
        model.clearPersistedMemories()
    }
}

@MainActor
final class FavoriteChangeSyncTests: XCTestCase {
    func testRapidTogglesUploadInOrderAndOldAckDoesNotClearNewOperation() async {
        let sync = FavoriteChangeSync(), sentenceID = UUID(), revision = UUID()
        let first = PendingFavoriteChange(sentenceID: sentenceID, isFavorite: true)
        let last = PendingFavoriteChange(sentenceID: sentenceID, isFavorite: false)
        var queue = [first]
        var uploaded: [Bool] = [], acknowledged: [UUID] = []
        var releaseFirst: CheckedContinuation<Void, Never>?
        let started = expectation(description: "first upload started")
        let operation = Task {
            await sync.sync(revision: revision, next: { attempted in queue.first { !attempted.contains($0.id) } },
                upload: { change in
                    uploaded.append(change.isFavorite)
                    if change.id == first.id {
                        await withCheckedContinuation { releaseFirst = $0; started.fulfill() }
                    }
                }, acknowledge: { change in
                    acknowledged.append(change.id)
                    queue.removeAll { $0.id == change.id }
                }, failed: { _ in XCTFail("unexpected failure") })
        }
        await fulfillment(of: [started], timeout: 2)
        queue = [last]
        let overlapStarted = expectation(description: "second caller joined")
        let overlapping = Task {
            overlapStarted.fulfill()
            await sync.sync(revision: revision, next: { _ in XCTFail("must share the writer"); return nil },
                            upload: { _ in XCTFail() }, acknowledge: { _ in XCTFail() }, failed: { _ in XCTFail() })
        }
        await fulfillment(of: [overlapStarted], timeout: 2)
        releaseFirst?.resume()
        await operation.value
        await overlapping.value
        XCTAssertEqual(uploaded, [true, false])
        XCTAssertEqual(acknowledged, [first.id, last.id])
        XCTAssertTrue(queue.isEmpty)
    }

    func testFailureKeepsOutboxAndDoesNotRetryForever() async {
        let sync = FavoriteChangeSync()
        let change = PendingFavoriteChange(sentenceID: UUID(), isFavorite: true)
        var queue = [change], attempts = 0
        await sync.sync(revision: UUID(), next: { attempted in queue.first { !attempted.contains($0.id) } },
            upload: { _ in attempts += 1; throw URLError(.notConnectedToInternet) },
            acknowledge: { _ in queue = [] }, failed: { _ in })
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(queue, [change])
    }

    func testCancelledOldAccountCannotAcknowledgeNewAccountData() async {
        let sync = FavoriteChangeSync()
        let change = PendingFavoriteChange(sentenceID: UUID(), isFavorite: true)
        var release: CheckedContinuation<Void, Never>?
        var acknowledgements = 0
        let started = expectation(description: "old account upload started")
        let operation = Task {
            await sync.sync(revision: UUID(), next: { _ in change }, upload: { _ in
                await withCheckedContinuation { release = $0; started.fulfill() }
            }, acknowledge: { _ in acknowledgements += 1 }, failed: { _ in })
        }
        await fulfillment(of: [started], timeout: 2)
        sync.cancel()
        release?.resume()
        await operation.value
        XCTAssertEqual(acknowledgements, 0)
    }
}
