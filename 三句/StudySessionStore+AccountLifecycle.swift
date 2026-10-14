import Foundation

extension StudySessionStore {
    func hasPendingEvents(ownerID: String) -> Bool {
        // Block retryable events, not permanently rejected receipts retained for this owner's next login.
        receipts(ownerID: ownerID).contains { $0.delivery == .pending }
    }
}
