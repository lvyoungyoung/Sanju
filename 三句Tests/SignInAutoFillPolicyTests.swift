import XCTest
@testable import 三句

@MainActor
final class SignInAutoFillPolicyTests: XCTestCase {
    private let empty = SignInCredentials(email: "", password: "")
    private let complete = SignInCredentials(email: "person@example.com", password: "example-password")

    func testPairedFillSubmitsOnlyOnce() {
        var policy = SignInAutoFillPolicy()
        XCTAssertTrue(policy.shouldSubmit(from: empty, to: complete, emailFieldIsFocused: true, isEligible: true, now: 1))
        XCTAssertFalse(policy.shouldSubmit(from: complete, to: complete, emailFieldIsFocused: false, isEligible: true, now: 1.1))
    }

    func testTwoFillEventsInEitherOrder() {
        for intermediate in [
            SignInCredentials(email: complete.email, password: ""),
            SignInCredentials(email: "", password: complete.password)
        ] {
            var policy = SignInAutoFillPolicy()
            XCTAssertFalse(policy.shouldSubmit(from: empty, to: intermediate, emailFieldIsFocused: false, isEligible: true, now: 1))
            XCTAssertTrue(policy.shouldSubmit(from: intermediate, to: complete, emailFieldIsFocused: false, isEligible: true, now: 1.1))
        }
    }

    func testExistingEmailAndPasswordFilledFromEmailField() {
        var policy = SignInAutoFillPolicy()
        let previous = SignInCredentials(email: complete.email, password: "")
        XCTAssertTrue(policy.shouldSubmit(from: previous, to: complete, emailFieldIsFocused: true, isEligible: true, now: 1))
    }

    func testPastingIntoActivePasswordFieldDoesNotSubmit() {
        var policy = SignInAutoFillPolicy()
        let previous = SignInCredentials(email: complete.email, password: "")
        XCTAssertFalse(policy.shouldSubmit(from: previous, to: complete, emailFieldIsFocused: false, isEligible: true, now: 1))
    }

    func testTypingAndDeletingNeverSubmit() {
        var policy = SignInAutoFillPolicy()
        var previous = SignInCredentials(email: complete.email, password: "")
        for character in complete.password {
            let next = SignInCredentials(email: complete.email, password: previous.password + String(character))
            XCTAssertFalse(policy.shouldSubmit(from: previous, to: next, emailFieldIsFocused: false, isEligible: true, now: 1))
            previous = next
        }
        XCTAssertFalse(policy.shouldSubmit(from: complete, to: empty, emailFieldIsFocused: true, isEligible: true, now: 2))
    }

    func testOrdinaryEditCancelsPendingPair() {
        var policy = SignInAutoFillPolicy()
        let emailOnly = SignInCredentials(email: complete.email, password: "")
        let typed = SignInCredentials(email: complete.email, password: "x")
        XCTAssertFalse(policy.shouldSubmit(from: empty, to: emailOnly, emailFieldIsFocused: false, isEligible: true, now: 1))
        XCTAssertFalse(policy.shouldSubmit(from: emailOnly, to: typed, emailFieldIsFocused: false, isEligible: true, now: 1.1))
        XCTAssertFalse(policy.shouldSubmit(from: typed, to: complete, emailFieldIsFocused: false, isEligible: true, now: 1.2))
    }

    func testExpiredPairDoesNotSubmit() {
        var policy = SignInAutoFillPolicy()
        let emailOnly = SignInCredentials(email: complete.email, password: "")
        XCTAssertFalse(policy.shouldSubmit(from: empty, to: emailOnly, emailFieldIsFocused: false, isEligible: true, now: 1))
        XCTAssertFalse(policy.shouldSubmit(from: emailOnly, to: complete, emailFieldIsFocused: false, isEligible: true, now: 2))
    }

    func testIncompleteOrInvalidCredentialsDoNotSubmit() {
        for credentials in [
            SignInCredentials(email: "", password: complete.password),
            SignInCredentials(email: "not-an-email", password: complete.password),
            SignInCredentials(email: "person @example.com", password: complete.password),
            SignInCredentials(email: complete.email, password: "")
        ] {
            var policy = SignInAutoFillPolicy()
            XCTAssertFalse(policy.shouldSubmit(from: empty, to: credentials, emailFieldIsFocused: true, isEligible: true, now: 1))
        }
    }

    func testOtherModesAndInFlightSubmissionDoNotTrigger() {
        var policy = SignInAutoFillPolicy()
        XCTAssertFalse(policy.shouldSubmit(from: empty, to: complete, emailFieldIsFocused: true, isEligible: false, now: 1))
        XCTAssertFalse(policy.shouldSubmit(from: complete, to: complete, emailFieldIsFocused: false, isEligible: true, now: 1.1))
    }

    func testResetDropsIncompleteFill() {
        var policy = SignInAutoFillPolicy()
        let emailOnly = SignInCredentials(email: complete.email, password: "")
        XCTAssertFalse(policy.shouldSubmit(from: empty, to: emailOnly, emailFieldIsFocused: false, isEligible: true, now: 1))
        policy.reset()
        XCTAssertFalse(policy.shouldSubmit(from: emailOnly, to: complete, emailFieldIsFocused: false, isEligible: true, now: 1.1))
    }
}
