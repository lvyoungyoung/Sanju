import SwiftUI
import UIKit
import Combine

private let signInThemeAccent = Color(red: 0.98, green: 0.65, blue: 0.00)
private let signInThemeAccentSoft = Color(red: 1.00, green: 0.96, blue: 0.89)
private let signInThemeAccentText = Color(red: 0.45, green: 0.31, blue: 0.10)
private let signInThemeMutedText = Color(red: 0.56, green: 0.47, blue: 0.34)
private let signInThemeBorder = Color(red: 0.87, green: 0.80, blue: 0.69)

private struct SignInSheetContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

fileprivate enum SignInField: Hashable {
    case nickname
    case email
    case password
    case verificationCode
    case newPassword
    case confirmPassword
}

struct SignInView: View {
    private enum Mode {
        case signIn
        case signUp
        case resetPassword

        var title: String {
            switch self {
            case .signIn:
                return L10n.string("auth.mode.sign_in.title", "邮箱登录")
            case .signUp:
                return L10n.string("auth.mode.sign_up.title", "注册账号")
            case .resetPassword:
                return L10n.string("auth.mode.reset_password.title", "重置密码")
            }
        }

        var actionTitle: String {
            switch self {
            case .signIn:
                return L10n.string("auth.mode.sign_in.action", "登录")
            case .signUp:
                return L10n.string("auth.mode.sign_up.action", "注册并登录")
            case .resetPassword:
                return L10n.string("auth.mode.reset_password.action", "确认重置")
            }
        }

        var helperText: String {
            switch self {
            case .signIn:
                return L10n.string("auth.mode.sign_in.helper", "还没有账号？")
            case .signUp:
                return L10n.string("auth.mode.sign_up.helper", "已经有账号了？")
            case .resetPassword:
                return L10n.string("auth.mode.reset_password.helper", "想起密码了？")
            }
        }

        var switchTitle: String {
            switch self {
            case .signIn:
                return L10n.string("auth.mode.sign_in.switch", "去注册")
            case .signUp:
                return L10n.string("auth.mode.sign_up.switch", "去登录")
            case .resetPassword:
                return L10n.string("auth.mode.reset_password.switch", "返回登录")
            }
        }
    }

    @EnvironmentObject private var appModel: AppModel
    @Environment(\.dismiss) private var dismiss
    @Binding var preferredSheetHeight: CGFloat
    let maxSheetHeight: CGFloat
    @State private var mode: Mode = .signIn
    @State private var nickname = ""
    @State private var email = ""
    @State private var password = ""
    @State private var verificationCode = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var verificationCodeCooldownSeconds = 0
    @State private var emailSignInLockoutRemainingSeconds = 0
    @State private var passwordResetSuccessMessage = ""
    @State private var isShowingPasswordResetSuccessAlert = false
    @FocusState private var focusedField: SignInField?
    private let verificationCodeCooldownTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            Color(red: 0.98, green: 0.95, blue: 0.91)
                .ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack {
                    signInBottomSection
                        .padding(.top, 28)
                        .padding(.bottom, 28)
                }
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .preference(key: SignInSheetContentHeightKey.self, value: proxy.size.height)
                }
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onPreferenceChange(SignInSheetContentHeightKey.self) { measuredHeight in
            guard measuredHeight > 0 else { return }
            preferredSheetHeight = min(max(measuredHeight + 24, 280), maxSheetHeight)
        }
        .onChange(of: appModel.isSignedIn) { _, isSignedIn in
            if isSignedIn {
                dismiss()
            }
        }
        .onReceive(verificationCodeCooldownTimer) { _ in
            refreshEmailSignInLockoutCountdown()
            guard verificationCodeCooldownSeconds > 0 else { return }
            verificationCodeCooldownSeconds -= 1
        }
        .task {
            refreshEmailSignInLockoutCountdown()
            await focusPrimaryFieldAfterPresentation()
        }
        .alert(
            L10n.string("common.notice", "提示"),
            isPresented: $isShowingPasswordResetSuccessAlert
        ) {
            Button(L10n.string("common.got_it", "知道了"), role: .cancel) {}
        } message: {
            Text(passwordResetSuccessMessage)
        }
    }

    private var signInBottomSection: some View {
        VStack(spacing: 0) {
            Text(mode.title)
                .font(.system(size: AppFontSize.panelTitle, weight: .semibold))
                .foregroundStyle(signInThemeAccentText)
                .padding(.bottom, 14)

            formSection

            if !appModel.isAuthenticating && !appModel.isRequestingPasswordReset {
                Button(action: submit) {
                    Text(mode.actionTitle)
                        .font(.system(size: AppFontSize.field, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: AppControlHeight.prominent)
                        .background(
                            LinearGradient(
                                colors: [
                                    signInThemeAccent,
                                    Color(red: 0.94, green: 0.57, blue: 0.00)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                                .stroke(Color.white.opacity(0.18), lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous))
                        .appAccentShadow(signInThemeAccent, opacity: 0.24)
                }
                .buttonStyle(.plain)
                .disabled(isSubmitDisabled)
                .opacity(isSubmitDisabled ? 0.55 : 1)
                .frame(maxWidth: 322)
                .padding(.top, 28)
            }

            if appModel.isAuthenticating || appModel.isRequestingPasswordReset {
                HStack(spacing: 10) {
                    ThinkingIndicator()
                    Text(progressTitle)
                        .font(.system(size: AppFontSize.sectionLabel, weight: .medium))
                        .foregroundStyle(signInThemeMutedText)
                }
                .padding(.top, 28)
            }

            if mode == .signIn {
                Button {
                    switchToResetPassword()
                } label: {
                    Text(L10n.string("auth.forgot_password", "忘记密码？"))
                        .font(.system(size: AppFontSize.body))
                        .foregroundStyle(signInThemeAccentText)
                }
                .buttonStyle(.plain)
                .disabled(appModel.isAuthenticating || appModel.isRequestingPasswordReset)
                .padding(.top, 24)
            }

            HStack(spacing: 4) {
                Text(mode.helperText)
                    .foregroundStyle(signInThemeMutedText)
                Button {
                    toggleMode()
                } label: {
                    Text(mode.switchTitle)
                        .foregroundStyle(signInThemeAccentText)
                        .fontWeight(.medium)
                }
                .buttonStyle(.plain)
            }
            .font(.system(size: AppFontSize.body))
            .padding(.top, 24)

            if !appModel.isNetworkAvailable {
                Text(L10n.string("auth.network_unavailable", "当前网络不可用，请连接网络后再登录。"))
                    .font(.system(size: AppFontSize.metadata))
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.top, 14)
            }

            if mode != .resetPassword,
               let authFlowMessage = appModel.authFlowMessage,
               !authFlowMessage.isEmpty {
                Text(authFlowMessage)
                    .font(.system(size: AppFontSize.metadata))
                    .foregroundStyle(signInThemeAccentText)
                    .multilineTextAlignment(.center)
                    .padding(.top, 12)
            }

            if let authErrorMessage = appModel.authErrorMessage,
               !authErrorMessage.isEmpty {
                Text(authErrorMessage)
                    .font(.system(size: AppFontSize.metadata))
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.top, 12)
            }

        }
        .onDisappear {
        }
        .padding(.horizontal, 26)
    }

    private var formSection: some View {
        VStack(spacing: 16) {
            if mode == .signUp {
                LabeledTextField(
                    title: L10n.string("auth.field.nickname", "昵称"),
                    text: $nickname,
                    placeholder: L10n.string("auth.placeholder.nickname", "请输入昵称，最多 20 个字符"),
                    textContentType: .nickname,
                    submitLabel: .next,
                    focusedField: $focusedField,
                    equals: .nickname
                )
            }

            LabeledTextField(
                title: L10n.string("auth.field.email", "邮箱"),
                text: $email,
                placeholder: "name@example.com",
                keyboardType: .emailAddress,
                textContentType: .emailAddress,
                submitLabel: mode == .resetPassword ? .next : .next,
                focusedField: $focusedField,
                equals: .email
            )

            switch mode {
            case .signIn:
                LabeledSecureField(
                    title: L10n.string("auth.field.password", "密码"),
                    text: $password,
                    placeholder: L10n.string("auth.placeholder.password", "请输入密码"),
                    textContentType: .password,
                    submitLabel: .go,
                    showsVisibilityToggle: true,
                    focusedField: $focusedField,
                    equals: .password
                )
            case .signUp:
                LabeledSecureField(
                    title: L10n.string("auth.field.password", "密码"),
                    text: $password,
                    placeholder: L10n.string("auth.placeholder.password_min", "至少 6 位"),
                    textContentType: .oneTimeCode,
                    submitLabel: .go,
                    showsVisibilityToggle: true,
                    focusedField: $focusedField,
                    equals: .password
                )
            case .resetPassword:
                LabeledTextField(
                    title: L10n.string("auth.field.verification_code", "验证码"),
                    text: $verificationCode,
                    placeholder: L10n.string("auth.placeholder.verification_code", "请输入邮件中的验证码"),
                    keyboardType: .numberPad,
                    textContentType: .oneTimeCode,
                    submitLabel: .next,
                    focusedField: $focusedField,
                    equals: .verificationCode
                )

                Button(action: requestPasswordReset) {
                    Text(verificationCodeButtonTitle)
                        .font(.system(size: AppFontSize.body, weight: .medium))
                        .foregroundStyle(isVerificationCodeRequestDisabled ? Color.black.opacity(0.38) : signInThemeAccentText)
                        .frame(maxWidth: .infinity)
                        .frame(height: AppControlHeight.compact)
                        .background(
                            RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                                .fill(
                                    isVerificationCodeRequestDisabled
                                    ? AnyShapeStyle(Color.white.opacity(0.92))
                                    : AnyShapeStyle(
                                        LinearGradient(
                                            colors: [
                                                signInThemeAccentSoft,
                                                Color.white.opacity(0.98)
                                            ],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                                )
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                                .stroke(
                                    isVerificationCodeRequestDisabled ? signInThemeBorder.opacity(0.7) : signInThemeAccent.opacity(0.28),
                                    lineWidth: 1
                                )
                        )
                        .shadow(
                            color: isVerificationCodeRequestDisabled ? .clear : signInThemeAccent.opacity(0.10),
                            radius: 12,
                            x: 0,
                            y: 6
                        )
                }
                .buttonStyle(.plain)
                .disabled(isVerificationCodeRequestDisabled)

                if let authFlowMessage = appModel.authFlowMessage,
                   !authFlowMessage.isEmpty {
                    Text(authFlowMessage)
                        .font(.system(size: AppFontSize.metadata))
                        .foregroundStyle(signInThemeAccentText)
                        .multilineTextAlignment(.center)
                        .padding(.top, 4)
                }

                if let passwordResetErrorMessage = appModel.passwordResetErrorMessage,
                   !passwordResetErrorMessage.isEmpty {
                    Text(passwordResetErrorMessage)
                        .font(.system(size: AppFontSize.metadata))
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.top, 4)
                }

                LabeledSecureField(
                    title: L10n.string("auth.field.new_password", "新密码"),
                    text: $newPassword,
                    placeholder: L10n.string("auth.placeholder.password_min", "至少 6 位"),
                    textContentType: .newPassword,
                    submitLabel: .next,
                    focusedField: $focusedField,
                    equals: .newPassword
                )

                LabeledSecureField(
                    title: L10n.string("auth.field.confirm_password", "确认密码"),
                    text: $confirmPassword,
                    placeholder: L10n.string("auth.placeholder.confirm_password", "再次输入新密码"),
                    textContentType: .newPassword,
                    submitLabel: .go,
                    focusedField: $focusedField,
                    equals: .confirmPassword
                )
            }
        }
        .frame(maxWidth: 322)
    }

    private var isSubmitDisabled: Bool {
        if appModel.isAuthenticating || appModel.isRequestingPasswordReset || appModel.isUpdatingPassword || !appModel.isNetworkAvailable {
            return true
        }

        if mode == .signIn, emailSignInLockoutRemainingSeconds > 0 {
            return true
        }

        switch mode {
        case .signIn:
            return email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .signUp:
            return nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .resetPassword:
            return email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            verificationCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            newPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            confirmPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private var progressTitle: String {
        if appModel.isRequestingPasswordReset {
            return L10n.string("auth.progress.sending_reset_email", "正在发送重置邮件...")
        }
        if appModel.isUpdatingPassword {
            return L10n.string("auth.progress.updating_password", "正在更新密码...")
        }
        return mode == .signUp
        ? L10n.string("auth.progress.creating_account", "正在创建账号...")
        : L10n.string("auth.progress.signing_in", "正在登录...")
    }

    private var verificationCodeButtonTitle: String {
        if appModel.isRequestingPasswordReset {
            return L10n.string("auth.verification_code.sending", "正在发送...")
        }

        if verificationCodeCooldownSeconds > 0 {
            return L10n.string("auth.verification_code.cooldown", "发送验证码 (%ds)", verificationCodeCooldownSeconds)
        }

        return L10n.string("auth.verification_code.send", "发送验证码")
    }

    private var isVerificationCodeRequestDisabled: Bool {
        appModel.isRequestingPasswordReset ||
        verificationCodeCooldownSeconds > 0 ||
        email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func toggleMode() {
        switch mode {
        case .signIn:
            transition(to: .signUp)
        case .signUp, .resetPassword:
            transition(to: .signIn)
        }
    }

    private func submit() {
        let currentMode = mode
        if currentMode == .signIn {
            refreshEmailSignInLockoutCountdown()
            guard emailSignInLockoutRemainingSeconds == 0 else {
                appModel.authErrorMessage = L10n.string("rate_limit.email_sign_in", "尝试次数过多，请1分钟后再试")
                return
            }
        }

        Task {
            switch currentMode {
            case .signIn, .signUp:
                let outcome = await appModel.handleEmailAuthentication(
                    email: email,
                    password: password,
                    nickname: currentMode == .signUp ? nickname : nil,
                    shouldCreateAccount: currentMode == .signUp
                )
                if currentMode == .signUp, outcome == .requiresEmailConfirmation {
                    transition(to: .signIn, preserveEmail: true, preserveAuthFlowMessage: true)
                }
                refreshEmailSignInLockoutCountdown()
            case .resetPassword:
                let outcome = await appModel.completePasswordReset(
                    email: email,
                    verificationCode: verificationCode,
                    newPassword: newPassword,
                    confirmPassword: confirmPassword
                )
                if outcome == .updated {
                    passwordResetSuccessMessage = L10n.string(
                        "auth.reset_password.success",
                        "密码修改成功，请重新登录"
                    )
                    isShowingPasswordResetSuccessAlert = true
                    transition(to: .signIn, preserveEmail: true, preserveAuthFlowMessage: true)
                }
            }
        }
    }

    private func refreshEmailSignInLockoutCountdown() {
        emailSignInLockoutRemainingSeconds = appModel.emailSignInLockoutRemainingSeconds
    }

    private func requestPasswordReset() {
        Task {
            let didSendVerificationCode = await appModel.requestPasswordReset(email: email)
            if didSendVerificationCode {
                verificationCodeCooldownSeconds = 60
            }
        }
    }
    
    private func switchToResetPassword() {
        transition(to: .resetPassword)
    }

    private func transition(
        to targetMode: Mode,
        preserveEmail: Bool = true,
        preserveAuthFlowMessage: Bool = false
    ) {
        let retainedEmail = preserveEmail ? email : ""
        let retainedAuthFlowMessage = preserveAuthFlowMessage ? appModel.authFlowMessage : nil

        mode = targetMode
        email = retainedEmail
        nickname = targetMode == .signUp ? nickname : ""
        password = ""
        verificationCode = ""
        newPassword = ""
        confirmPassword = ""
        appModel.authErrorMessage = nil
        appModel.authFlowMessage = retainedAuthFlowMessage
        appModel.credentialWarningMessage = nil
        appModel.passwordResetErrorMessage = nil
        focusedField = nil
        Task {
            await focusPrimaryFieldAfterPresentation()
        }
    }

    @MainActor
    private func focusPrimaryFieldAfterPresentation() async {
        try? await Task.sleep(for: .milliseconds(220))
        guard focusedField == nil else { return }
        focusedField = primaryField(for: mode)
    }

    private func primaryField(for mode: Mode) -> SignInField {
        switch mode {
        case .signIn:
            return email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .email : .password
        case .signUp:
            if nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .nickname
            }
            if email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .email
            }
            return .password
        case .resetPassword:
            if email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .email
            }
            if verificationCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .verificationCode
            }
            if newPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .newPassword
            }
            return .confirmPassword
        }
    }
}

private struct LabeledTextField: View {
    let title: String
    @Binding var text: String
    let placeholder: String
    var keyboardType: UIKeyboardType = .default
    var textContentType: UITextContentType? = nil
    var submitLabel: SubmitLabel = .done
    let focusedField: FocusState<SignInField?>.Binding
    let equals: SignInField

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: AppFontSize.body, weight: .medium))
                .foregroundStyle(isFocused ? signInThemeAccentText : signInThemeMutedText)

            TextField(placeholder, text: $text)
                .font(.system(size: AppFontSize.field))
                .keyboardType(keyboardType)
                .textContentType(textContentType)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(submitLabel)
                .focused(focusedField, equals: equals)
                .padding(.horizontal, AppControlPadding.regular)
                .frame(height: AppControlHeight.prominent)
                .background(
                    RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                        .fill(isFocused ? Color.white.opacity(0.98) : Color.white)
                        .overlay(
                            RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                                .stroke(
                                    isFocused ? signInThemeAccent.opacity(0.78) : signInThemeBorder.opacity(0.72),
                                    lineWidth: isFocused ? 1.5 : 1
                                )
                        )
                        .overlay {
                            if isFocused {
                                RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                                    .stroke(signInThemeAccent.opacity(0.20), lineWidth: 6)
                                    .blur(radius: 4)
                                    .mask(
                                        RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                                            .fill(
                                                LinearGradient(
                                                    colors: [.black, .clear, .black],
                                                    startPoint: .top,
                                                    endPoint: .bottom
                                                )
                                            )
                                    )
                            }
                        }
                )
        }
    }

    private var isFocused: Bool {
        focusedField.wrappedValue == equals
    }
}

private struct LabeledSecureField: View {
    let title: String
    @Binding var text: String
    let placeholder: String
    var textContentType: UITextContentType? = nil
    var submitLabel: SubmitLabel = .done
    var showsVisibilityToggle = false
    let focusedField: FocusState<SignInField?>.Binding
    let equals: SignInField
    @State private var isPasswordVisible = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: AppFontSize.body, weight: .medium))
                .foregroundStyle(isFocused ? signInThemeAccentText : signInThemeMutedText)

            HStack(spacing: 8) {
                Group {
                    if isPasswordVisible {
                        TextField(placeholder, text: $text)
                            .textContentType(.oneTimeCode)
                    } else {
                        SecureField(placeholder, text: $text)
                            .textContentType(textContentType)
                    }
                }
                .font(.system(size: AppFontSize.field))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(submitLabel)
                .focused(focusedField, equals: equals)

                if showsVisibilityToggle {
                    Button {
                        isPasswordVisible.toggle()
                    } label: {
                        Image(systemName: isPasswordVisible ? "eye.slash.fill" : "eye.fill")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(isFocused ? signInThemeAccentText : signInThemeMutedText.opacity(0.78))
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        isPasswordVisible
                        ? L10n.string("auth.accessibility.hide_password", "隐藏密码")
                        : L10n.string("auth.accessibility.show_password", "显示密码")
                    )
                }
            }
                .padding(.leading, AppControlPadding.regular)
                .padding(.trailing, showsVisibilityToggle ? 10 : AppControlPadding.regular)
                .frame(height: AppControlHeight.prominent)
                .background(
                    RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                        .fill(isFocused ? Color.white.opacity(0.98) : Color.white)
                        .overlay(
                            RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                                .stroke(
                                    isFocused ? signInThemeAccent.opacity(0.78) : signInThemeBorder.opacity(0.72),
                                    lineWidth: isFocused ? 1.5 : 1
                                )
                        )
                        .overlay {
                            if isFocused {
                                RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                                    .stroke(signInThemeAccent.opacity(0.20), lineWidth: 6)
                                    .blur(radius: 4)
                                    .mask(
                                        RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                                            .fill(
                                                LinearGradient(
                                                    colors: [.black, .clear, .black],
                                                    startPoint: .top,
                                                    endPoint: .bottom
                                                )
                                            )
                                    )
                            }
                        }
                )
        }
    }

    private var isFocused: Bool {
        focusedField.wrappedValue == equals
    }
}
