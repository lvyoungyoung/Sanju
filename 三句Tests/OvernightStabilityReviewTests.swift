import Foundation
import XCTest
@testable import 三句

@MainActor
final class OvernightStabilityReviewTests: XCTestCase {
    func testDistinctPhotosMustNotBeDiscardedBecauseGeneratedSentencesMatch() {
        let local = makeMemory(image: Data([1, 2]), path: "guest/new-photo.jpg", synced: false)
        let remote = makeMemory(image: Data([3, 4]), path: "owner/old-photo.jpg", synced: true)
        XCTAssertNotEqual(local.id, remote.id)
        XCTAssertNotEqual(local.sentences.map(\.id), remote.sentences.map(\.id))
        XCTAssertNotEqual(local.imageData, remote.imageData)

        let result = CloudSyncManager().reconcileLocalMemories(
            localMemories: [local], remoteMemories: [remote], sessionUserID: "owner"
        )
        XCTAssertEqual(result.memories.map(\.id), [local.id])
        XCTAssertFalse(result.memories[0].syncedToAccount)
        XCTAssertFalse(result.didChange)
    }

    func testRepeatedRecoveryKeepsStableIdentityDespiteMissingPhotoAndChangedSentences() {
        let local = makeMemory(image: Data([1, 2]), path: "guest/photo.jpg", synced: false)
        let recovered = MemoryEntry(
            id: local.id, createdAt: local.createdAt, imageData: Data(),
            remoteImagePath: "owner/photo.jpg", syncedToAccount: true,
            sentences: local.sentences.reversed()
        )
        XCTAssertTrue(MemoryIdentity.matches(local, recovered))
        let result = CloudSyncManager().reconcileLocalMemories(
            localMemories: [local], remoteMemories: [recovered], sessionUserID: "owner"
        )
        XCTAssertTrue(result.memories.isEmpty, "The remote copy replaces only this exact guest memory")
    }

    func testSamePhotoAndSentenceIDsDoNotMergeDifferentGenerations() {
        let first = makeMemory(image: Data([1, 2]), path: "owner/photo.jpg", synced: false)
        let second = MemoryEntry(imageData: first.imageData, remoteImagePath: first.remoteImagePath,
                                 sentences: first.sentences)
        XCTAssertFalse(MemoryIdentity.matches(first, second))
        XCTAssertFalse(MemoryIdentity.matches(MemoryEntry(imageData: Data(), sentences: []),
                                             MemoryEntry(imageData: Data(), sentences: [])))
    }

    func testUnrelatedRemoteContentKeepsGuestPhotoPendingForMigration() {
        let local = makeMemory(image: Data([1, 2]), path: "guest/new-photo.jpg", synced: false)
        var remote = makeMemory(image: Data([3, 4]), path: "owner/old-photo.jpg", synced: true)
        remote.sentences[0] = SentenceRecord(english: "A completely different scene.", chinese: "Different translation.")
        let result = CloudSyncManager().reconcileLocalMemories(
            localMemories: [local], remoteMemories: [remote], sessionUserID: "owner"
        )
        XCTAssertEqual(result.memories.map(\.id), [local.id])
        XCTAssertFalse(result.memories[0].syncedToAccount)
    }

    func testCorruptDiskAudioCanBeReplacedByCompleteRetryWithoutCrossAccountReuse() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let key = SpeechAudioCache.key(text: "A calm morning.", scope: "offline|alice")
        let otherKey = SpeechAudioCache.key(text: "A calm morning.", scope: "offline|bob")
        try Data([0]).write(to: directory.appendingPathComponent(key).appendingPathExtension("pcm"))
        let cache = SpeechAudioCache(directory: directory)
        let damaged = await cache.load(key)
        XCTAssertNil(damaged)
        await cache.save(Data([0, 1, 2, 3]), key: key)
        let repaired = await cache.load(key)
        let otherAccount = await cache.load(otherKey)
        XCTAssertEqual(repaired, Data([0, 1, 2, 3]))
        XCTAssertNil(otherAccount)
    }

    private func makeMemory(image: Data, path: String, synced: Bool) -> MemoryEntry {
        MemoryEntry(
            id: UUID(), createdAt: Date(), imageData: image,
            remoteImagePath: path, syncedToAccount: synced,
            sentences: (0..<6).map { index in
                SentenceRecord(
                    english: "A quiet scene number \(index).", chinese: "Translation \(index).",
                    presentationGroup: index < 3 ? .whatISee : .whatIDSay
                )
            }
        )
    }
}
