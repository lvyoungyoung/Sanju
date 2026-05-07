import Foundation

extension AppModel {
    func consumeGenerationAttemptIfAllowed() throws {
        try localRateLimiter.consumeAllowance(for: .generation)
    }

    func consumePasswordResetAttemptIfAllowed() throws {
        try localRateLimiter.consumeAllowance(for: .passwordReset)
    }

    var emailSignInLockoutRemainingSeconds: Int {
        guard case let .emailSignIn(retryAfter)? = localRateLimiter.currentError(for: .emailSignInFailure) else {
            return 0
        }
        return max(Int(ceil(retryAfter)), 1)
    }

    func assertEmailSignInAllowed() throws {
        if let error = localRateLimiter.currentError(for: .emailSignInFailure) {
            throw error
        }
    }

    @discardableResult
    func recordEmailSignInFailure() -> LocalRateLimitError? {
        localRateLimiter.recordAttempt(for: .emailSignInFailure)
    }

    func clearEmailSignInFailures() {
        localRateLimiter.clearAttempts(for: .emailSignInFailure)
    }
}
