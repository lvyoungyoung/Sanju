import XCTest
@testable import 三句

@MainActor
final class PurchaseConfirmationScopeTests: XCTestCase {
    func testLateConfirmationCannotApplyOrFinishAfterAccountSwitch() async throws {
        try await assertLateResponseRejected(returnToSameOwner: false, serverFails: false)
    }

    func testLogoutAndLoginToSameAccountStillRejectsOldConfirmation() async throws {
        try await assertLateResponseRejected(returnToSameOwner: true, serverFails: false)
    }

    func testLateServerFailureIsCancellationNotNewAccountsPurchaseError() async throws {
        try await assertLateResponseRejected(returnToSameOwner: false, serverFails: true)
    }

    func testTokenRefreshDoesNotInvalidateSameAccountConfirmation() async throws {
        let scope = PurchaseConfirmationScope()
        let original = session("alice")
        scope.activate(original)
        let balance = try await scope.perform(session: original) {
            scope.activate(session("alice", token: "refreshed"))
            return 210
        }
        XCTAssertEqual(balance, 210)
    }

    func testWrongOwnerNeverStartsConfirmation() async {
        let scope = PurchaseConfirmationScope()
        scope.activate(session("bob"))
        var requested = false
        do {
            _ = try await scope.perform(session: session("alice")) { requested = true; return 210 }
            XCTFail("Mismatched owner must be rejected")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(requested)
    }

    func testRetryInOriginalAccountCanApplyConfirmedBalanceAndFinish() async throws {
        let scope = PurchaseConfirmationScope()
        scope.activate(session("alice"))
        let credits = try await scope.perform(session: session("alice")) { 210 }
        XCTAssertEqual(credits, 210, "The server's idempotent result is not added a second time")
    }

    private func assertLateResponseRejected(returnToSameOwner: Bool, serverFails: Bool) async throws {
        let scope = PurchaseConfirmationScope()
        let alice = session("alice")
        scope.activate(alice)
        let started = expectation(description: "Confirmation in flight")
        var resume: CheckedContinuation<Void, Never>?
        var balance = 30
        var finished = false
        let request = Task {
            let result = try await scope.perform(session: alice) {
                await withCheckedContinuation { resume = $0; started.fulfill() }
                if serverFails { throw URLError(.timedOut) }
                return 210
            }
            balance = result
            finished = true
        }
        await fulfillment(of: [started], timeout: 2)
        scope.activate(nil)
        scope.activate(session(returnToSameOwner ? "alice" : "bob"))
        resume?.resume()
        do { try await request.value; XCTFail("Stale response must be rejected") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(balance, 30)
        XCTAssertFalse(finished)
    }

    private func session(_ owner: String, token: String = "test") -> SupabaseSession {
        SupabaseSession(accessToken: token, refreshToken: "test", userID: owner,
                        expiresAt: .distantFuture, isAnonymous: false)
    }
}
