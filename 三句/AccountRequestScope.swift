import Foundation

/// Invalidates in-flight work even when the same account signs in again.
@MainActor
final class AccountRequestScope {
    nonisolated deinit {}

    private(set) var revision = UUID()

    func invalidate() { revision = UUID() }

    func check(_ revision: UUID) throws {
        try Task.checkCancellation()
        guard self.revision == revision else { throw CancellationError() }
    }
}

@MainActor
final class SessionRefreshCoordinator {
    nonisolated deinit {}

    private var pending: (id: UUID, token: String, task: Task<SupabaseSession, Error>)?

    func refresh(token: String, operation: @escaping () async throws -> SupabaseSession) async throws -> SupabaseSession {
        if let pending, pending.token == token { return try await pending.task.value }
        let id = UUID()
        let task = Task { try await operation() }
        pending = (id, token, task)
        defer { if pending?.id == id { pending = nil } }
        return try await task.value
    }

    func cancel() {
        pending?.task.cancel()
        pending = nil
    }
}
