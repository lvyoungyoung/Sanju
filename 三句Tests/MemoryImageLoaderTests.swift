import Foundation
import XCTest
@testable import 三句

@MainActor
final class MemoryImageLoaderTests: XCTestCase {
    func testRequestBecomesAvailableWhenMemoryMetadataArrives() throws {
        let session = makeSession()
        XCTAssertNil(MemoryImageLoadRequest(memory: nil, session: session))

        let memory = makeMemory()
        let request = try XCTUnwrap(MemoryImageLoadRequest(memory: memory, session: session))
        XCTAssertEqual(request.memoryID, memory.id)
        XCTAssertEqual(request.remoteImagePath, memory.remoteImagePath)

        let cachedMemory = makeMemory(id: memory.id, imageData: Data([1]))
        XCTAssertNil(MemoryImageLoadRequest(memory: cachedMemory, session: session))
    }

    func testMissingSessionOrImagePathDoesNotRequestDownload() {
        XCTAssertNil(MemoryImageLoadRequest(memory: makeMemory(), session: nil))
        XCTAssertNil(MemoryImageLoadRequest(memory: makeMemory(path: nil), session: makeSession()))
        XCTAssertNil(MemoryImageLoadRequest(memory: makeMemory(path: ""), session: makeSession()))
    }

    func testRequestIdentityProtectsAgainstAccountOrImageChanges() throws {
        let memory = makeMemory()
        let request = try XCTUnwrap(MemoryImageLoadRequest(memory: memory, session: makeSession()))

        XCTAssertNotEqual(request, MemoryImageLoadRequest(memory: memory, session: makeSession(userID: "other-user")))
        XCTAssertNotEqual(request, MemoryImageLoadRequest(memory: memory, session: makeSession(isAnonymous: true)))
        XCTAssertNotEqual(request, MemoryImageLoadRequest(memory: makeMemory(id: memory.id, path: "replacement.jpg"), session: makeSession()))
        XCTAssertNotEqual(request, MemoryImageLoadRequest(memory: nil, session: makeSession()))
        XCTAssertEqual(request, MemoryImageLoadRequest(memory: memory, session: makeSession(accessToken: "refreshed-token")))
    }

    func testConcurrentCoverAndMemoryLoadsShareOneDownload() async throws {
        let loader = MemoryImageLoader()
        let request = try XCTUnwrap(MemoryImageLoadRequest(memory: makeMemory(), session: makeSession()))
        let download = SuspendedDownload(started: expectation(description: "Download started"))
        let coverTask = Task {
            try await loader.load(request: request) { await download.run() }
        }
        await fulfillment(of: [download.started], timeout: 2)

        let secondStarted = expectation(description: "Second consumer started")
        var duplicateDownloads = 0
        let memoryTask = Task {
            secondStarted.fulfill()
            return try await loader.load(request: request) {
                duplicateDownloads += 1
                return Data([2])
            }
        }
        await fulfillment(of: [secondStarted], timeout: 2)
        download.complete(with: Data([1]))

        let coverData = try await coverTask.value
        let memoryData = try await memoryTask.value
        XCTAssertEqual(coverData, Data([1]))
        XCTAssertEqual(memoryData, coverData)
        XCTAssertEqual(duplicateDownloads, 0)
    }

    func testDisappearingCardDoesNotCancelSharedDownload() async throws {
        let loader = MemoryImageLoader()
        let request = try XCTUnwrap(MemoryImageLoadRequest(memory: makeMemory(), session: makeSession()))
        let download = SuspendedDownload(started: expectation(description: "Download started"))
        let coverTask = Task {
            try await loader.load(request: request) { await download.run() }
        }
        await fulfillment(of: [download.started], timeout: 2)
        coverTask.cancel()

        let secondStarted = expectation(description: "Second consumer started")
        let memoryTask = Task {
            secondStarted.fulfill()
            return try await loader.load(request: request) {
                XCTFail("The shared image should not be downloaded again")
                return Data()
            }
        }
        await fulfillment(of: [secondStarted], timeout: 2)
        download.complete(with: Data([3]))

        let memoryData = try await memoryTask.value
        _ = try await coverTask.value
        XCTAssertEqual(memoryData, Data([3]))
        XCTAssertFalse(download.wasCancelled)
    }

    func testDifferentAccountsDoNotShareInFlightDownload() async throws {
        let loader = MemoryImageLoader()
        let memory = makeMemory()
        let firstRequest = try XCTUnwrap(MemoryImageLoadRequest(memory: memory, session: makeSession()))
        let secondRequest = try XCTUnwrap(MemoryImageLoadRequest(memory: memory, session: makeSession(userID: "other-user")))
        let download = SuspendedDownload(started: expectation(description: "First account download started"))
        let firstTask = Task {
            try await loader.load(request: firstRequest) { await download.run() }
        }
        await fulfillment(of: [download.started], timeout: 2)

        var secondDownloadCount = 0
        let secondData = try await loader.load(request: secondRequest) {
            secondDownloadCount += 1
            return Data([2])
        }
        download.complete(with: Data([1]))
        let firstData = try await firstTask.value
        XCTAssertEqual(secondDownloadCount, 1)
        XCTAssertEqual(firstData, Data([1]))
        XCTAssertEqual(secondData, Data([2]))
    }

    func testFailedDownloadCanBeRetried() async throws {
        let loader = MemoryImageLoader()
        let request = try XCTUnwrap(MemoryImageLoadRequest(memory: makeMemory(), session: makeSession()))
        do {
            _ = try await loader.load(request: request) { throw URLError(.notConnectedToInternet) }
            XCTFail("The network error should be propagated")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet)
        }

        let data = try await loader.load(request: request) { Data([4]) }
        XCTAssertEqual(data, Data([4]))
    }

    private func makeMemory(id: UUID = UUID(), path: String? = "user/image.jpg", imageData: Data = Data()) -> MemoryEntry {
        MemoryEntry(id: id, imageData: imageData, remoteImagePath: path, syncedToAccount: true, sentences: [])
    }

    private func makeSession(userID: String = "user", isAnonymous: Bool = false, accessToken: String = "token") -> SupabaseSession {
        SupabaseSession(
            accessToken: accessToken,
            refreshToken: "refresh",
            userID: userID,
            expiresAt: .distantFuture,
            isAnonymous: isAnonymous
        )
    }
}

@MainActor
private final class SuspendedDownload {
    let started: XCTestExpectation
    private var continuation: CheckedContinuation<Data, Never>?
    private(set) var wasCancelled = false

    init(started: XCTestExpectation) {
        self.started = started
    }

    func run() async -> Data {
        let data = await withCheckedContinuation { continuation in
            self.continuation = continuation
            started.fulfill()
        }
        wasCancelled = Task.isCancelled
        return data
    }

    func complete(with data: Data) {
        continuation?.resume(returning: data)
        continuation = nil
    }
}
