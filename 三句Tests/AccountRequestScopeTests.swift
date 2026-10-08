import XCTest
@testable import 三句

@MainActor
final class AccountRequestScopeTests: XCTestCase {
    func testLogoutInvalidatesAnInFlightResponseEvenAfterSameAccountReturns() async throws {
        let scope = AccountRequestScope()
        let revision = scope.revision
        let started = expectation(description: "Request started")
        var continuation: CheckedContinuation<Void, Never>?
        var applied = false
        let task = Task {
            await withCheckedContinuation { continuation = $0; started.fulfill() }
            try scope.check(revision)
            applied = true
        }
        await fulfillment(of: [started], timeout: 2)
        scope.invalidate()
        scope.invalidate()
        continuation?.resume()
        do { try await task.value; XCTFail("An old response must be rejected") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(applied)
        XCTAssertNoThrow(try scope.check(scope.revision))
    }

    func testConcurrentRefreshesShareOneNetworkRequest() async throws {
        let coordinator = SessionRefreshCoordinator()
        var calls = 0
        let refreshed = SupabaseSession(accessToken: "new", refreshToken: "new-refresh", userID: "alice", expiresAt: .distantFuture, isAnonymous: false)
        let operation = {
            calls += 1
            try await Task.sleep(for: .milliseconds(30))
            return refreshed
        }
        let first = Task { try await coordinator.refresh(token: "old", operation: operation) }
        let second = Task { try await coordinator.refresh(token: "old", operation: operation) }
        let a = try await first.value
        let b = try await second.value
        XCTAssertEqual(a.accessToken, "new")
        XCTAssertEqual(b.accessToken, "new")
        XCTAssertEqual(calls, 1)
    }

    func testCancellingOldRefreshDoesNotClearNewAccountRequest() async throws {
        let coordinator = SessionRefreshCoordinator()
        let started = expectation(description: "Old request started")
        let old = Task {
            try await coordinator.refresh(token: "alice") {
                started.fulfill()
                try await Task.sleep(for: .seconds(10))
                throw URLError(.unknown)
            }
        }
        await fulfillment(of: [started], timeout: 2)
        coordinator.cancel()
        var calls = 0
        let operation = {
            calls += 1
            try await Task.sleep(for: .milliseconds(30))
            return SupabaseSession(accessToken: "bob", refreshToken: "bob-refresh", userID: "bob", expiresAt: .distantFuture, isAnonymous: false)
        }
        let first = Task { try await coordinator.refresh(token: "bob", operation: operation) }
        _ = await old.result
        let second = Task { try await coordinator.refresh(token: "bob", operation: operation) }
        _ = try await first.value
        _ = try await second.value
        XCTAssertEqual(calls, 1)
    }
}
