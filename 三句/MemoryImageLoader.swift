import Foundation

struct MemoryImageLoadRequest: Hashable {
    let userID: String
    let isAnonymous: Bool
    let memoryID: UUID
    let remoteImagePath: String

    init?(memory: MemoryEntry?, session: SupabaseSession?) {
        guard let memory, let session,
              memory.imageData.isEmpty,
              let path = memory.remoteImagePath, !path.isEmpty else {
            return nil
        }
        userID = session.userID
        isAnonymous = session.isAnonymous
        memoryID = memory.id
        remoteImagePath = path
    }
}

@MainActor
final class MemoryImageLoader {
    private var tasks: [MemoryImageLoadRequest: Task<Data, Error>] = [:]

    func load(
        request: MemoryImageLoadRequest,
        download: @escaping @MainActor () async throws -> Data
    ) async throws -> Data {
        if let task = tasks[request] {
            return try await task.value
        }

        // A disappearing card must not cancel a download shared by other views.
        let task = Task { try await download() }
        tasks[request] = task
        defer { tasks[request] = nil }
        return try await task.value
    }
}
