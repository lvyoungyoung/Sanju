import Foundation

/// Allows the first guest session to establish an owner without accepting later account changes.
@MainActor
struct GenerationAccountScope {
    let revision: UUID
    let invalidationCount: UInt64
    let owner: String?
    let isAnonymous: Bool?

    init(accountRequests: AccountRequestScope, session: SupabaseSession?) {
        revision = accountRequests.revision
        invalidationCount = accountRequests.invalidationCount
        owner = session?.userID
        isAnonymous = session?.isAnonymous
    }

    func resolvedRevision(
        session: SupabaseSession,
        currentSession: SupabaseSession?,
        accountRequests: AccountRequestScope
    ) throws -> UUID {
        try Task.checkCancellation()
        guard currentSession?.userID == session.userID,
              currentSession?.isAnonymous == session.isAnonymous else { throw CancellationError() }

        if accountRequests.revision == revision {
            guard owner == session.userID, isAnonymous == session.isAnonymous else { throw CancellationError() }
            return revision
        }

        // More than one invalidation may include sign-out/relogin, even with the same final owner.
        guard owner == nil, session.isAnonymous,
              accountRequests.invalidationCount == invalidationCount &+ 1 else { throw CancellationError() }
        return accountRequests.revision
    }
}
