import Foundation

/// A server confirmation can succeed after logout. Keep it retryable rather than
/// applying its balance (or finishing the transaction) in a different login.
@MainActor
final class PurchaseConfirmationScope {
    private(set) var revision = UUID()
    private var ownerID: String?
    private var isAnonymous: Bool?

    nonisolated deinit {}

    func activate(_ session: SupabaseSession?) {
        let ownerID = session?.userID.lowercased()
        guard self.ownerID != ownerID || isAnonymous != session?.isAnonymous else { return }
        self.ownerID = ownerID
        isAnonymous = session?.isAnonymous
        revision = UUID()
    }

    func perform<Value>(session: SupabaseSession, operation: () async throws -> Value) async throws -> Value {
        let revision = revision
        try check(session, revision: revision)
        do {
            let result = try await operation()
            try check(session, revision: revision)
            return result
        } catch {
            // Also suppress old-account failures, not just old-account successes.
            try check(session, revision: revision)
            throw error
        }
    }

    private func check(_ session: SupabaseSession, revision: UUID) throws {
        try Task.checkCancellation()
        guard self.revision == revision, ownerID == session.userID.lowercased(),
              isAnonymous == session.isAnonymous else { throw CancellationError() }
    }
}
