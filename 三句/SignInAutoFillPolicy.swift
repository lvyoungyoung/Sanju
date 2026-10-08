import Foundation

struct SignInCredentials: Hashable {
    let email: String
    let password: String

    var isComplete: Bool {
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = address.split(separator: "@", omittingEmptySubsequences: false)
        return parts.count == 2 && !parts[0].isEmpty && !parts[1].isEmpty
            && !address.contains(where: { $0.isWhitespace }) && !password.isEmpty
    }
}

// SwiftUI exposes value changes, not a definitive Password AutoFill callback.
// Require paired bulk replacements or a password filled while the email field is active.
// A password pasted into the active password field alone must not submit the form.
struct SignInAutoFillPolicy {
    private var emailReplacementTime: TimeInterval?
    private var passwordReplacementTime: TimeInterval?
    private let pairingWindow: TimeInterval = 0.35

    mutating func shouldSubmit(
        from old: SignInCredentials,
        to new: SignInCredentials,
        emailFieldIsFocused: Bool,
        isEligible: Bool,
        now: TimeInterval
    ) -> Bool {
        guard isEligible else {
            reset()
            return false
        }
        let emailChanged = old.email != new.email
        let passwordChanged = old.password != new.password
        let emailReplaced = emailChanged && isBulkInsertion(from: old.email, to: new.email)
        let passwordReplaced = passwordChanged && isBulkInsertion(from: old.password, to: new.password)

        if (emailChanged && !emailReplaced) || (passwordChanged && !passwordReplaced) {
            reset()
            return false
        }
        if emailReplaced { emailReplacementTime = now }
        if passwordReplaced { passwordReplacementTime = now }
        guard new.isComplete else { return false }

        let paired = emailReplacementTime.map { now - $0 <= pairingWindow } == true
            && passwordReplacementTime.map { now - $0 <= pairingWindow } == true
        let filledInactivePassword = passwordReplaced && emailFieldIsFocused
        guard paired || filledInactivePassword else { return false }
        reset()
        return true
    }

    mutating func reset() {
        emailReplacementTime = nil
        passwordReplacementTime = nil
    }

    private func isBulkInsertion(from old: String, to new: String) -> Bool {
        new.difference(from: old).reduce(0) { count, change in
            if case .insert = change { return count + 1 }
            return count
        } > 1
    }
}
