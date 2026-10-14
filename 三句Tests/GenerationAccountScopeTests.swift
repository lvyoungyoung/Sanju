import Foundation
import XCTest
@testable import 三句

@MainActor
final class GenerationAccountScopeTests: XCTestCase {
    private func session(_ owner: String = "guest", anonymous: Bool = true) -> SupabaseSession {
        SupabaseSession(accessToken: "test", refreshToken: "test", userID: owner,
            expiresAt: .distantFuture, isAnonymous: anonymous)
    }

    func testFirstGuestBootstrapAdoptsNewRevisionAndKeepsFrozenSpec() throws {
        let requests = AccountRequestScope()
        let scope = GenerationAccountScope(accountRequests: requests, session: nil)
        var selection = try LearningSelection.standard(target: .japanese, support: .english)
        let frozenSpec = GenerationSpec(selection: selection, level: .beginner)
        selection = try .standard(target: .french, support: .english)
        requests.invalidate()
        let guest = session()
        let revision = try scope.resolvedRevision(session: guest, currentSession: guest, accountRequests: requests)
        XCTAssertNotEqual(revision, scope.revision)
        XCTAssertEqual(revision, requests.revision)
        XCTAssertNoThrow(try requests.check(revision))
        XCTAssertThrowsError(try requests.check(scope.revision))
        let snapshot = GenerationRequestSnapshot(owner: guest.userID, accountRevision: revision,
            requestID: UUID(), guestJobID: UUID(), spec: frozenSpec, imageDigest: "digest", createdAt: .now)
        XCTAssertEqual(snapshot.spec.targetLanguage, .japanese)
        XCTAssertEqual(selection.targetLanguage, .french)
        requests.invalidate()
        XCTAssertThrowsError(try requests.check(snapshot.accountRevision))
    }

    func testExistingSessionKeepsRevisionWithoutAccountChange() throws {
        let requests = AccountRequestScope()
        let guest = session()
        let scope = GenerationAccountScope(accountRequests: requests, session: guest)
        XCTAssertEqual(try scope.resolvedRevision(session: guest, currentSession: guest,
            accountRequests: requests), scope.revision)
    }

    func testExistingGuestRejectsReplacementAndSameOwnerRelogin() {
        for owner in ["guest", "replacement"] {
            let requests = AccountRequestScope()
            let scope = GenerationAccountScope(accountRequests: requests, session: session())
            requests.invalidate()
            let replacement = session(owner)
            XCTAssertThrowsError(try scope.resolvedRevision(session: replacement, currentSession: replacement,
                accountRequests: requests))
        }
    }

    func testBootstrapCannotAdoptRegisteredAccount() {
        let requests = AccountRequestScope()
        let scope = GenerationAccountScope(accountRequests: requests, session: nil)
        requests.invalidate()
        let registered = session("registered", anonymous: false)
        XCTAssertThrowsError(try scope.resolvedRevision(session: registered, currentSession: registered,
            accountRequests: requests))
    }

    func testBootstrapRejectsMultipleTransitionsAndStaleReturnedSession() {
        let requests = AccountRequestScope()
        let scope = GenerationAccountScope(accountRequests: requests, session: nil)
        requests.invalidate()
        let guest = session()
        XCTAssertThrowsError(try scope.resolvedRevision(session: guest, currentSession: session("other"),
            accountRequests: requests))
        XCTAssertThrowsError(try scope.resolvedRevision(session: guest, currentSession: nil,
            accountRequests: requests))
        requests.invalidate()
        XCTAssertThrowsError(try scope.resolvedRevision(session: guest, currentSession: guest,
            accountRequests: requests))
    }
}
