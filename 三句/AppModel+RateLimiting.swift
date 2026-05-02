import Foundation

extension AppModel {
    private struct LocalRateLimitPolicy {
        let limit: Int
        let interval: TimeInterval
    }

    private enum LocalRateLimitedAction {
        case generation
        case passwordReset
        case emailSignInFailure

        var storageKey: String {
            switch self {
            case .generation:
                return AppStorageKey.generationAttemptTimestamps
            case .passwordReset:
                return AppStorageKey.passwordResetAttemptTimestamps
            case .emailSignInFailure:
                return AppStorageKey.emailSignInFailureTimestamps
            }
        }

        var policies: [LocalRateLimitPolicy] {
            switch self {
            case .generation:
                return [
                    LocalRateLimitPolicy(limit: 10, interval: 60),
                    LocalRateLimitPolicy(limit: 100, interval: 60 * 60)
                ]
            case .passwordReset:
                return [
                    LocalRateLimitPolicy(limit: 3, interval: 5 * 60)
                ]
            case .emailSignInFailure:
                return [
                    LocalRateLimitPolicy(limit: 3, interval: 60)
                ]
            }
        }
    }

    enum LocalRateLimitError: LocalizedError {
        case generation(retryAfter: TimeInterval)
        case passwordReset
        case emailSignIn(retryAfter: TimeInterval)

        var errorDescription: String? {
            switch self {
            case .generation:
                return "操作频繁，请稍后再试。"
            case .passwordReset:
                return "操作频繁，请稍后再试。"
            case .emailSignIn:
                return "尝试次数过多，请1分钟后再试"
            }
        }

    }

    func consumeGenerationAttemptIfAllowed() throws {
        try consumeLocalRateLimitAllowance(for: .generation)
    }

    func consumePasswordResetAttemptIfAllowed() throws {
        try consumeLocalRateLimitAllowance(for: .passwordReset)
    }

    var emailSignInLockoutRemainingSeconds: Int {
        guard case let .emailSignIn(retryAfter)? = currentLocalRateLimitError(for: .emailSignInFailure) else {
            return 0
        }
        return max(Int(ceil(retryAfter)), 1)
    }

    func assertEmailSignInAllowed() throws {
        if let error = currentLocalRateLimitError(for: .emailSignInFailure) {
            throw error
        }
    }

    @discardableResult
    func recordEmailSignInFailure() -> LocalRateLimitError? {
        let now = Date()
        let updatedTimestamps = normalizedAttemptTimestamps(for: .emailSignInFailure, now: now) + [now]
        saveAttemptTimestamps(updatedTimestamps, for: .emailSignInFailure)
        return currentLocalRateLimitError(
            for: .emailSignInFailure,
            now: now,
            pretrimmedTimestamps: updatedTimestamps
        )
    }

    func clearEmailSignInFailures() {
        defaults.removeObject(forKey: LocalRateLimitedAction.emailSignInFailure.storageKey)
    }

    private func consumeLocalRateLimitAllowance(
        for action: LocalRateLimitedAction,
        now: Date = .now
    ) throws {
        let trimmed = normalizedAttemptTimestamps(for: action, now: now)

        if let error = currentLocalRateLimitError(for: action, now: now, pretrimmedTimestamps: trimmed) {
            throw error
        }

        saveAttemptTimestamps(trimmed + [now], for: action)
    }

    private func currentLocalRateLimitError(
        for action: LocalRateLimitedAction,
        now: Date = .now,
        pretrimmedTimestamps: [Date]? = nil
    ) -> LocalRateLimitError? {
        let trimmed = pretrimmedTimestamps ?? normalizedAttemptTimestamps(for: action, now: now)
        var retryAfter: TimeInterval?

        for policy in action.policies {
            let recent = trimmed.filter { now.timeIntervalSince($0) < policy.interval }
            guard recent.count >= policy.limit else { continue }

            let blockingIndex = max(recent.count - policy.limit, 0)
            let blockingTimestamp = recent[blockingIndex]
            let candidateRetryAfter = max(
                blockingTimestamp.addingTimeInterval(policy.interval).timeIntervalSince(now),
                1
            )
            retryAfter = max(retryAfter ?? 0, candidateRetryAfter)
        }

        guard let retryAfter else { return nil }

        switch action {
        case .generation:
            return .generation(retryAfter: retryAfter)
        case .passwordReset:
            return .passwordReset
        case .emailSignInFailure:
            return .emailSignIn(retryAfter: retryAfter)
        }
    }

    private func normalizedAttemptTimestamps(
        for action: LocalRateLimitedAction,
        now: Date = .now
    ) -> [Date] {
        let timestamps = loadAttemptTimestamps(for: action)
        let maxInterval = action.policies.map(\.interval).max() ?? 0
        return timestamps
            .filter { now.timeIntervalSince($0) < maxInterval }
            .sorted()
    }

    private func loadAttemptTimestamps(for action: LocalRateLimitedAction) -> [Date] {
        guard let data = defaults.data(forKey: action.storageKey) else {
            return []
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([Date].self, from: data)) ?? []
    }

    private func saveAttemptTimestamps(_ timestamps: [Date], for action: LocalRateLimitedAction) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try? encoder.encode(timestamps)
        defaults.set(data, forKey: action.storageKey)
    }
}
