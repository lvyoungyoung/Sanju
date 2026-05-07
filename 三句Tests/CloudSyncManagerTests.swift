//
//  CloudSyncManagerTests.swift
//  三句Tests
//
//  Created by Codex.
//

import Foundation
import XCTest
@testable import 三句

@MainActor
final class CloudSyncManagerTests: XCTestCase {
    private let manager = CloudSyncManager()

    func testMakeRemoteMemoriesSortsSentencesAndDropsInvalidRecords() {
        let validMemoryID = UUID()
        let firstSentenceID = UUID()
        let secondSentenceID = UUID()
        let thirdSentenceID = UUID()
        let records = [
            makeRemoteRecord(
                id: validMemoryID.uuidString,
                sentences: [
                    makeRemoteSentence(id: thirdSentenceID.uuidString, sortOrder: 2, english: "Third sentence."),
                    makeRemoteSentence(id: firstSentenceID.uuidString, sortOrder: 0, english: "First sentence."),
                    makeRemoteSentence(id: secondSentenceID.uuidString, sortOrder: 1, english: "Second sentence.")
                ]
            ),
            makeRemoteRecord(id: "not-a-uuid"),
            makeRemoteRecord(sentences: [
                makeRemoteSentence(sortOrder: 0),
                makeRemoteSentence(sortOrder: 1)
            ])
        ]

        let memories = manager.makeRemoteMemories(from: records)

        XCTAssertEqual(memories.count, 1)
        XCTAssertEqual(memories.first?.id, validMemoryID)
        XCTAssertEqual(memories.first?.sentences.map(\.id), [firstSentenceID, secondSentenceID, thirdSentenceID])
        XCTAssertEqual(memories.first?.sentences.map(\.english), [
            "First sentence.",
            "Second sentence.",
            "Third sentence."
        ])
        XCTAssertEqual(memories.first?.remoteImagePath, "remote/path.jpg")
        XCTAssertTrue(memories.first?.syncedToAccount == true)
    }

    func testReconcileLocalMemoriesMarksExistingRemoteMemoryAsSynced() {
        let localMemory = makeMemory(syncedToAccount: false)
        let remoteMemory = makeMemory(id: UUID(), sentences: localMemory.sentences, syncedToAccount: true)

        let result = manager.reconcileLocalMemories(
            localMemories: [localMemory],
            remoteMemories: [remoteMemory],
            sessionUserID: "current-user"
        )

        XCTAssertTrue(result.didChange)
        XCTAssertEqual(result.memories.count, 1)
        XCTAssertTrue(result.memories[0].syncedToAccount)
    }

    func testReconcileLocalMemoriesKeepsReconciledMemoryForCurrentAccount() {
        let localMemory = makeMemory(syncedToAccount: false)
        let remoteMemory = makeMemory(id: UUID(), sentences: localMemory.sentences, syncedToAccount: true)

        let result = manager.reconcileLocalMemories(
            localMemories: [localMemory],
            remoteMemories: [remoteMemory],
            sessionUserID: "current-user"
        )

        XCTAssertTrue(result.didChange)
        XCTAssertEqual(result.memories.count, 1)
        XCTAssertTrue(result.memories[0].syncedToAccount)
    }

    func testReconcileLocalMemoriesPrunesSyncedMemoryOwnedByAnotherAccount() {
        let localMemory = makeMemory(remoteImagePath: "other-user/memory.jpg", syncedToAccount: true)
        let remoteMemory = makeMemory(id: localMemory.id, syncedToAccount: true)

        let result = manager.reconcileLocalMemories(
            localMemories: [localMemory],
            remoteMemories: [remoteMemory],
            sessionUserID: "current-user"
        )

        XCTAssertTrue(result.didChange)
        XCTAssertTrue(result.memories.isEmpty)
        XCTAssertEqual(result.recordedMemoriesCount, 0)
        XCTAssertEqual(result.favoriteSentencesCount, 0)
    }

    func testMakePlanSkipsFavoriteDiffAlreadyQueuedForRetry() {
        let favoriteSentenceID = UUID()
        let localMemory = makeMemory(sentences: [
            SentenceRecord(id: favoriteSentenceID, english: "A", chinese: "甲", isFavorite: true),
            SentenceRecord(english: "B", chinese: "乙"),
            SentenceRecord(english: "C", chinese: "丙")
        ], syncedToAccount: true)
        let remoteMemory = makeMemory(id: localMemory.id, sentences: [
            SentenceRecord(id: favoriteSentenceID, english: "A", chinese: "甲", isFavorite: false),
            SentenceRecord(id: localMemory.sentences[1].id, english: "B", chinese: "乙"),
            SentenceRecord(id: localMemory.sentences[2].id, english: "C", chinese: "丙")
        ], syncedToAccount: true)

        let plan = manager.makePlan(
            localMemories: [localMemory],
            remoteMemories: [remoteMemory],
            queuedGuestMemories: [],
            queuedMemoryDeletions: [],
            queuedFavoriteChanges: [PendingFavoriteChange(sentenceID: favoriteSentenceID, isFavorite: true)],
            queuedLocalStudyProgress: []
        )

        XCTAssertEqual(plan.favoriteDifferenceCount, 0)
        XCTAssertEqual(plan.totalCount, 1)
    }

    private func makeRemoteRecord(
        id: String = UUID().uuidString,
        imagePath: String = "remote/path.jpg",
        createdAt: Date = Date(timeIntervalSince1970: 1_000),
        sentences: [SupabaseMemorySentenceRecord]? = nil
    ) -> SupabaseMemoryRecord {
        SupabaseMemoryRecord(
            id: id,
            imagePath: imagePath,
            createdAt: createdAt,
            sentences: sentences ?? [
                makeRemoteSentence(sortOrder: 0),
                makeRemoteSentence(sortOrder: 1),
                makeRemoteSentence(sortOrder: 2)
            ]
        )
    }

    private func makeRemoteSentence(
        id: String = UUID().uuidString,
        sortOrder: Int,
        english: String = "A quiet sentence.",
        chinese: String = "一句安静的话。",
        isFavorite: Bool = false
    ) -> SupabaseMemorySentenceRecord {
        SupabaseMemorySentenceRecord(
            id: id,
            sortOrder: sortOrder,
            english: english,
            chinese: chinese,
            isFavorite: isFavorite
        )
    }

    private func makeMemory(
        id: UUID = UUID(),
        remoteImagePath: String? = "current-user/memory.jpg",
        sentences: [SentenceRecord]? = nil,
        syncedToAccount: Bool
    ) -> MemoryEntry {
        MemoryEntry(
            id: id,
            createdAt: Date(timeIntervalSince1970: 1_000),
            imageData: Data(),
            remoteImagePath: remoteImagePath,
            syncedToAccount: syncedToAccount,
            sentences: sentences ?? [
                SentenceRecord(english: "A quiet street.", chinese: "一条安静的街。"),
                SentenceRecord(english: "A small tree grows.", chinese: "一棵小树在生长。"),
                SentenceRecord(english: "Soft light fills the air.", chinese: "柔和的光充满空气。")
            ]
        )
    }
}
