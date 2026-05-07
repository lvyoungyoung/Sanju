import Foundation

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

final class LocalRateLimiter {
    private struct Policy {
        let limit: Int
        let interval: TimeInterval
    }

    enum Action {
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

    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func consumeAllowance(for action: Action, now: Date = .now) throws {
        let trimmed = normalizedAttemptTimestamps(for: action, now: now)

        if let error = currentError(for: action, now: now, pretrimmedTimestamps: trimmed) {
            throw error
        }

        saveAttemptTimestamps(trimmed + [now], for: action)
    }

    func currentError(
        for action: Action,
        now: Date = .now,
        pretrimmedTimestamps: [Date]? = nil
    ) -> LocalRateLimitError? {
        let trimmed = pretrimmedTimestamps ?? normalizedAttemptTimestamps(for: action, now: now)
        var retryAfter: TimeInterval?

        for policy in policies(for: action) {
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

    @discardableResult
    func recordAttempt(for action: Action, now: Date = .now) -> LocalRateLimitError? {
        let updatedTimestamps = normalizedAttemptTimestamps(for: action, now: now) + [now]
        saveAttemptTimestamps(updatedTimestamps, for: action)
        return currentError(for: action, now: now, pretrimmedTimestamps: updatedTimestamps)
    }

    func clearAttempts(for action: Action) {
        defaults.removeObject(forKey: action.storageKey)
    }

    private func normalizedAttemptTimestamps(for action: Action, now: Date = .now) -> [Date] {
        let timestamps = loadAttemptTimestamps(for: action)
        let maxInterval = policies(for: action).map(\.interval).max() ?? 0
        return timestamps
            .filter { now.timeIntervalSince($0) < maxInterval }
            .sorted()
    }

    private func policies(for action: Action) -> [Policy] {
        switch action {
        case .generation:
            return [
                Policy(limit: 10, interval: 60),
                Policy(limit: 100, interval: 60 * 60)
            ]
        case .passwordReset:
            return [
                Policy(limit: 3, interval: 5 * 60)
            ]
        case .emailSignInFailure:
            return [
                Policy(limit: 3, interval: 60)
            ]
        }
    }

    private func loadAttemptTimestamps(for action: Action) -> [Date] {
        guard let data = defaults.data(forKey: action.storageKey) else {
            return []
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([Date].self, from: data)) ?? []
    }

    private func saveAttemptTimestamps(_ timestamps: [Date], for action: Action) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try? encoder.encode(timestamps)
        defaults.set(data, forKey: action.storageKey)
    }
}
