import StoreKit
import SwiftUI

struct ProfileView: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var isShowingPurchaseSheet = false
    @State private var isShowingWidgetSetupSheet = false
    @State private var isShowingSignOutAlert = false
    @State private var isShowingDeleteAccountAlert = false
    @State private var isShowingNicknameEditor = false
    @State private var deleteAccountErrorMessage: String?
    @State private var deleteAccountConfirmationText = ""
    @State private var nicknameDraft = ""
    @State private var nicknameEditErrorMessage: String?
    @State private var isUpdatingNickname = false
    @State private var transientHintMessage: String?
    @State private var transientHintStyle: TopHintStyle = .normal
    @State private var transientHintTask: Task<Void, Never>?
    @State private var learningReminderTime = Date()
    @State private var isShowingLearningReminderTimePicker = false
    @State private var isSavingLearningReminder = false
    @State private var learningReminderStatusMessage: String?
    @State private var learningReminderStatusIsError = false
#if DEBUG || STAGING
    @State private var isShowingLocalTestResetAlert = false
#endif

    private var deleteAccountConfirmationPhrase: String {
        L10n.string("account.delete.confirmation_phrase", "我已知晓后果，确定删除账号")
    }

    private var generationGuardMessage: String {
        L10n.string("profile.guard.generation_in_progress", "正在为您生成描述，请稍后操作。")
    }

    private var pendingCloudSyncGuardMessage: String {
        L10n.string("profile.guard.pending_cloud_sync", "正在同步数据到云端，请勿退出登录。")
    }
    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: AppSpacing.large) {
                if let profile = authenticatedProfile {
                    profileHero(profile: profile)
                } else if shouldShowAuthenticatedRestoreSkeleton {
                    restoringAuthenticatedSkeleton
                } else {
                    guestHero
                }

                if shouldShowAuthenticatedRestoreSkeleton {
                    ProfileCreditCardSkeleton()
                } else {
                    ProfileCreditCard(
                        credits: appModel.remainingCredits,
                        isPurchaseDisabled: appModel.isPurchaseSessionPreparing,
                        onPurchase: {
                            guard !appModel.isPurchaseSessionPreparing else { return }
                            isShowingPurchaseSheet = true
                        }
                    )
                }

                VStack(alignment: .leading, spacing: 14) {
                    Text("生成偏好")
                        .font(.system(size: AppFontSize.sectionLabel, weight: .semibold))
                        .foregroundStyle(.secondary)

                    PreferenceCard(title: "英语水平", systemImage: "gauge.with.dots.needle.33percent") {
                        Picker("英语水平", selection: englishLevelBinding) {
                            ForEach(EnglishLevel.allCases) { level in
                                Text(level.displayTitle).tag(level)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    PreferenceCard(title: "语言风格", systemImage: "paintpalette") {
                        Picker("语言风格", selection: languageStyleBinding) {
                            ForEach(LanguageStyle.allCases) { style in
                                Text(style.displayTitle)
                                    .tag(style)
                                    .disabled(!style.isAvailable(for: appModel.englishLevel))
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                }

                widgetSection

                learningReminderSection

                accountSection
            }
            .padding(.horizontal, AppSpacing.xLarge)
            .padding(.top, AppSpacing.xLarge)
            .padding(.bottom, 120)
        }
        .background(Color(.systemGroupedBackground))
        .toolbar(.hidden, for: .navigationBar)
        .overlay(alignment: .top) {
            if let transientHintMessage {
                LightweightTopHint(message: transientHintMessage, style: transientHintStyle)
                    .padding(.top, AppSpacing.medium)
                    .padding(.horizontal, AppSpacing.xLarge)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.22), value: transientHintMessage != nil)
        .refreshable {
            await appModel.refreshRemoteContent()
        }
        .sheet(isPresented: $isShowingPurchaseSheet) {
            PurchaseSheet()
                .environmentObject(appModel)
        }
        .sheet(isPresented: $isShowingWidgetSetupSheet) {
            WidgetSetupSheet()
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $isShowingNicknameEditor) {
            NicknameEditorSheet(
                nickname: $nicknameDraft,
                errorMessage: nicknameEditErrorMessage,
                isSaving: isUpdatingNickname,
                onSave: saveNickname
            )
            .presentationDetents([.height(348)])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $isShowingLearningReminderTimePicker) {
            LearningReminderTimePickerSheet(
                reminderTime: learningReminderTime,
                isSaving: isSavingLearningReminder
            ) { selectedTime in
                learningReminderTime = selectedTime
                saveLearningReminder()
            }
            .presentationDetents([.height(396)])
            .presentationBackground(Color(.systemGroupedBackground))
            .presentationDragIndicator(.visible)
        }
        .alert(L10n.string("profile.sign_out.alert_title", "确定要退出登录吗？"), isPresented: $isShowingSignOutAlert) {
            Button(L10n.string("profile.sign_out.action", "退出登录"), role: .destructive) {
                guard !interceptIfGenerationInProgress() else { return }
                guard !interceptIfPendingCloudSyncInProgress() else { return }
                appModel.signOut()
            }
            Button(L10n.string("common.cancel", "取消"), role: .cancel) { }
        } message: {
            Text(L10n.string(
                "profile.sign_out.alert_message",
                "退出登录后，当前设备上的本地回忆与收藏会被清空，但云端账号和数据仍会保留。如果您想永久删除云端账号和所有数据，请使用「删除账号」功能。"
            ))
        }
        .alert(L10n.string("account.delete.alert_title", "确认删除账号？"), isPresented: $isShowingDeleteAccountAlert) {
            TextField(L10n.string("account.delete.confirmation_placeholder", "请输入指定内容"), text: $deleteAccountConfirmationText)
            Button(L10n.string("common.cancel", "取消"), role: .cancel) {
                deleteAccountConfirmationText = ""
            }
            Button(L10n.string("account.delete.confirm_action", "确定删除"), role: .destructive) {
                Task {
                    do {
                        guard !interceptIfGenerationInProgress() else { return }
                        try await appModel.deleteAccount()
                    } catch {
                        await MainActor.run {
                            deleteAccountErrorMessage = error.localizedDescription
                        }
                    }
                }
            }
            .disabled(deleteAccountConfirmationText != deleteAccountConfirmationPhrase)
        } message: {
            Text(L10n.string(
                "account.delete.alert_message",
                "删除后，你的账号资料、云端数据、当前设备上的本地回忆与收藏，以及未使用次数都会被永久删除且无法恢复。\n如果确定删除，请在下方输入框中输入“%@”。",
                deleteAccountConfirmationPhrase
            ))
        }
        .alert(L10n.string("account.delete.failed_title", "删除失败"), isPresented: deleteAccountErrorAlertBinding) {
            Button(L10n.string("common.got_it", "知道了"), role: .cancel) {
                deleteAccountErrorMessage = nil
            }
        } message: {
            Text(deleteAccountErrorMessage ?? "")
        }
#if DEBUG || STAGING
        .alert("清理本机测试数据？", isPresented: $isShowingLocalTestResetAlert) {
            Button("清理并恢复首次安装状态", role: .destructive) {
                appModel.resetLocalTestDataForFreshInstall()
                showTransientHint("已清理本机测试数据，现在是首次安装状态。")
            }
            Button(L10n.string("common.cancel", "取消"), role: .cancel) { }
        } message: {
            Text("这会清空本机登录态、Keychain、回忆缓存、学习记录、购买记录缓存和可用次数，然后重新发放首次安装的 5 次生成机会。仅用于测试。")
        }
#endif
        .onDisappear {
            transientHintTask?.cancel()
            transientHintTask = nil
        }
    }

    private var deleteAccountErrorAlertBinding: Binding<Bool> {
        Binding(
            get: { deleteAccountErrorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    deleteAccountErrorMessage = nil
                }
            }
        )
    }

    private var englishLevelBinding: Binding<EnglishLevel> {
        Binding(
            get: { appModel.englishLevel },
            set: { appModel.updateEnglishLevel($0) }
        )
    }

    private var languageStyleBinding: Binding<LanguageStyle> {
        Binding(
            get: { appModel.languageStyle },
            set: { appModel.updateLanguageStyle($0) }
        )
    }

    private var accountSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if shouldShowAuthenticatedRestoreSkeleton {
                Text("账户")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.black.opacity(0.5))

                RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                    .fill(Color.black.opacity(0.06))
                    .frame(height: AppControlHeight.prominent)

                RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                    .fill(Color.black.opacity(0.06))
                    .frame(height: AppControlHeight.prominent)

                Divider()
                    .padding(.vertical, 4)
            } else if authenticatedProfile != nil {
                Text("账户")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.black.opacity(0.5))

                Button(role: .destructive) {
                    guard !interceptIfGenerationInProgress() else { return }
                    guard !interceptIfPendingCloudSyncInProgress() else { return }
                    isShowingSignOutAlert = true
                } label: {
                    HStack {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                            .font(.system(size: 16, weight: .semibold))
                        Text("退出登录")
                            .font(.system(size: 16, weight: .semibold))
                        Spacer()
                    }
                    .foregroundStyle(Color(red: 0.81, green: 0.29, blue: 0.20))
                    .padding(18)
                    .background(
                        RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                            .fill(Color(.secondarySystemGroupedBackground))
                    )
                }
                .buttonStyle(.plain)
                .disabled(appModel.isDeletingAccount)

                Button {
                    guard !interceptIfGenerationInProgress() else { return }
                    deleteAccountConfirmationText = ""
                    isShowingDeleteAccountAlert = true
                } label: {
                    HStack {
                        Image(systemName: "person.crop.circle.badge.xmark")
                            .font(.system(size: 16, weight: .semibold))
                        Text("删除账号")
                            .font(.system(size: 16, weight: .semibold))
                        Spacer()
                    }
                    .foregroundStyle(Color(.secondaryLabel))
                    .padding(18)
                    .background(
                        RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                            .fill(Color(.secondarySystemGroupedBackground))
                    )
                }
                .buttonStyle(.plain)
                .disabled(appModel.isDeletingAccount)
                Divider()
                    .padding(.vertical, 4)
            }

            if let termsOfServiceURL = AppLinks.termsOfService {
                Link(destination: termsOfServiceURL) {
                    HStack {
                        Image(systemName: "doc.text")
                            .font(.system(size: 16, weight: .semibold))
                        Text("用户服务协议")
                            .font(.system(size: 16, weight: .semibold))
                        Spacer()
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 14, weight: .medium))
                    }
                    .foregroundStyle(Color(.secondaryLabel))
                    .padding(18)
                    .background(
                        RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                            .fill(Color(.secondarySystemGroupedBackground))
                    )
                }
                .buttonStyle(.plain)
                .disabled(appModel.isDeletingAccount)
            }

            if let privacyPolicyURL = AppLinks.privacyPolicy {
                Link(destination: privacyPolicyURL) {
                    HStack {
                        Image(systemName: "hand.raised")
                            .font(.system(size: 16, weight: .semibold))
                        Text("隐私协议")
                            .font(.system(size: 16, weight: .semibold))
                        Spacer()
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 14, weight: .medium))
                    }
                    .foregroundStyle(Color(.secondaryLabel))
                    .padding(18)
                    .background(
                        RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                            .fill(Color(.secondarySystemGroupedBackground))
                    )
                }
                .buttonStyle(.plain)
                .disabled(appModel.isDeletingAccount)
            }

#if DEBUG || STAGING
            Button(role: .destructive) {
                isShowingLocalTestResetAlert = true
            } label: {
                HStack {
                    Image(systemName: "wrench.and.screwdriver")
                        .font(.system(size: 16, weight: .semibold))
                    Text("清理本机测试数据")
                        .font(.system(size: 16, weight: .semibold))
                    Spacer()
                    Text("测试")
                        .font(.system(size: 12, weight: .bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.orange.opacity(0.16)))
                }
                .foregroundStyle(Color.orange)
                .padding(18)
                .background(
                    RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                        .fill(Color(.secondarySystemGroupedBackground))
                )
            }
            .buttonStyle(.plain)
            .disabled(appModel.isDeletingAccount)
#endif
        }
    }

    private var widgetSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("桌面小组件")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.black.opacity(0.5))

            WidgetSetupLinkCard {
                isShowingWidgetSetupSheet = true
            }
        }
    }

    private var learningReminderSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("学习提醒")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.black.opacity(0.5))

            LearningReminderSetupCard(
                reminderTime: $learningReminderTime,
                isEnabled: appModel.isLearningReminderEnabled,
                isSaving: isSavingLearningReminder,
                statusMessage: learningReminderStatusMessage,
                statusIsError: learningReminderStatusIsError,
                onSave: saveLearningReminder,
                onDisable: disableLearningReminder,
                onEditTime: {
                    learningReminderTime = appModel.learningReminderDate
                    isShowingLearningReminderTimePicker = true
                }
            )
        }
        .onAppear {
            learningReminderTime = appModel.learningReminderDate
        }
    }

    private var authenticatedProfile: UserProfile? {
        guard appModel.isSignedIn else { return nil }
        return appModel.profile
    }

    private var shouldShowAuthenticatedRestoreSkeleton: Bool {
        appModel.isRestoringAuthenticatedSession && authenticatedProfile == nil
    }

    @ViewBuilder
    private func profileHero(profile: UserProfile) -> some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 1.00, green: 0.96, blue: 0.89),
                            Color(red: 0.94, green: 0.97, blue: 0.94)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            VStack(alignment: .leading, spacing: AppSpacing.large) {
                HStack(alignment: .center, spacing: AppSpacing.medium) {
                    ProfileAvatarView()

                    VStack(alignment: .leading, spacing: AppSpacing.small) {
                        HStack(alignment: .center, spacing: AppSpacing.xLarge) {
                            Text(profile.nickname)
                                .font(.system(size: AppFontSize.heroStat + 1, weight: .bold))
                                .foregroundStyle(AppTextColor.title)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .layoutPriority(1)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            Button {
                                nicknameDraft = profile.nickname
                                nicknameEditErrorMessage = nil
                                isShowingNicknameEditor = true
                            } label: {
                                Image(systemName: "square.and.pencil")
                                    .font(.system(size: AppFontSize.body, weight: .semibold))
                                    .foregroundStyle(Color(red: 0.45, green: 0.31, blue: 0.10))
                                    .padding(7)
                                    .background(
                                        RoundedRectangle(cornerRadius: AppCornerRadius.small, style: .continuous)
                                            .fill(Color.white.opacity(0.68))
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        if let email = profile.email, !email.isEmpty {
                            Text(email)
                                .font(.system(size: AppFontSize.metadata))
                                .foregroundStyle(AppTextColor.tertiary)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                    Text("在这里管理你的可用次数、调整生成偏好，也可以继续购买新的生成次数。")
                        .font(.system(size: 14))
                        .foregroundStyle(AppTextColor.secondary)
                        .lineSpacing(3)
            }
            .padding(AppSpacing.xLarge)
        }
        .appHeroShadow()
    }

    private var guestHero: some View {
        VStack(alignment: .leading, spacing: AppSpacing.medium) {
            HStack(spacing: AppSpacing.medium) {
                ProfileAvatarView(isMonochrome: true)

                VStack(alignment: .leading, spacing: 6) {
                    Text("未登录")
                        .font(.system(size: AppFontSize.stat, weight: .bold))
                        .foregroundStyle(AppTextColor.primary)

                    Text("登录后可以跨设备同步回忆和收藏")
                        .font(.system(size: AppFontSize.metadata))
                        .foregroundStyle(AppTextColor.tertiary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Button {
                    guard !interceptIfGenerationInProgress() else { return }
                    appModel.isShowingSignInSheet = true
                } label: {
                    Text("登录")
                        .font(.system(size: AppFontSize.body, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, AppSpacing.xLarge)
                        .padding(.vertical, AppSpacing.small + 2)
                        .background(Color.black, in: Capsule())
                }
                .buttonStyle(.plain)
            }

            if appModel.hasPurchaseHistory {
                Text("请尽快登录，以免换设备时丢失您购买的可用次数。")
                    .font(.system(size: AppFontSize.caption, weight: .medium))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(AppSpacing.xLarge)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous)
                .fill(Color.white)
        )
        .appHeroShadow()
    }

    private var restoringAuthenticatedSkeleton: some View {
        VStack(alignment: .leading, spacing: AppSpacing.medium) {
            HStack(spacing: AppSpacing.medium) {
                RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous)
                    .fill(Color.black.opacity(0.08))
                    .frame(width: 92, height: 92)
                    .overlay {
                        Image(systemName: "person.crop.circle")
                            .font(.system(size: 34, weight: .medium))
                            .foregroundStyle(Color.black.opacity(0.14))
                    }

                VStack(alignment: .leading, spacing: AppSpacing.medium) {
                    RoundedRectangle(cornerRadius: AppCornerRadius.small, style: .continuous)
                        .fill(Color.black.opacity(0.08))
                        .frame(width: 128, height: 20)

                    RoundedRectangle(cornerRadius: AppCornerRadius.small, style: .continuous)
                        .fill(Color.black.opacity(0.06))
                        .frame(maxWidth: .infinity)
                        .frame(height: 13)

                    RoundedRectangle(cornerRadius: AppCornerRadius.small, style: .continuous)
                        .fill(Color.black.opacity(0.06))
                        .frame(width: 168, height: 13)
                }

                Spacer(minLength: 8)

                ProgressView()
                    .controlSize(.regular)
                    .tint(.black.opacity(0.65))
            }

            HStack(spacing: AppSpacing.small) {
                Text("正在恢复账号信息")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.black.opacity(0.48))

                Spacer(minLength: 0)

                RoundedRectangle(cornerRadius: AppCornerRadius.small, style: .continuous)
                    .fill(Color.black.opacity(0.06))
                    .frame(width: 84, height: 10)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous)
                .fill(Color.white)
        )
        .appHeroShadow()
    }

    private func interceptIfGenerationInProgress() -> Bool {
        guard appModel.hasActiveGenerationTask else { return false }
        showTransientHint(generationGuardMessage, style: .warning)
        return true
    }

    private func interceptIfPendingCloudSyncInProgress() -> Bool {
        guard appModel.isSyncingPendingCloudChanges else { return false }
        showTransientHint(pendingCloudSyncGuardMessage, style: .warning)
        return true
    }

    private func showTransientHint(_ message: String, style: TopHintStyle = .normal) {
        transientHintTask?.cancel()
        transientHintMessage = message
        transientHintStyle = style
        transientHintTask = Task {
            try? await Task.sleep(for: .seconds(1.8))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                transientHintMessage = nil
                transientHintStyle = .normal
                transientHintTask = nil
            }
        }
    }

    private func saveNickname() {
        Task {
            await MainActor.run {
                nicknameEditErrorMessage = nil
                isUpdatingNickname = true
            }

            do {
                try await appModel.updateNickname(nicknameDraft)
                await MainActor.run {
                    isUpdatingNickname = false
                    isShowingNicknameEditor = false
                    showTransientHint("昵称已更新。")
                }
            } catch {
                await MainActor.run {
                    isUpdatingNickname = false
                    nicknameEditErrorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }
        }
    }

    private func saveLearningReminder() {
        guard !isSavingLearningReminder else { return }
        isSavingLearningReminder = true
        learningReminderStatusMessage = nil

        Task { @MainActor in
            do {
                try await appModel.configureLearningReminder(at: learningReminderTime)
                learningReminderStatusIsError = false
                learningReminderStatusMessage = nil
            } catch {
                appModel.disableLearningReminder()
                learningReminderStatusIsError = true
                learningReminderStatusMessage = (error as? LocalizedError)?.errorDescription ?? "提醒设置失败，请稍后再试。"
            }
            isSavingLearningReminder = false
        }
    }

    private func disableLearningReminder() {
        appModel.disableLearningReminder()
        learningReminderStatusIsError = false
        learningReminderStatusMessage = nil
    }
}

private struct NicknameEditorSheet: View {
    @Binding var nickname: String
    let errorMessage: String?
    let isSaving: Bool
    let onSave: () -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isNicknameFocused: Bool

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: AppSpacing.xLarge) {
                Text("修改昵称")
                    .font(.system(size: AppFontSize.panelTitle, weight: .semibold))
                    .foregroundStyle(Color(red: 0.30, green: 0.30, blue: 0.28))

                VStack(alignment: .leading, spacing: 8) {
                    Text("昵称")
                        .font(.system(size: AppFontSize.body, weight: .medium))
                        .foregroundStyle(isNicknameFocused ? Color(red: 0.45, green: 0.31, blue: 0.10) : Color.black.opacity(0.55))

                    TextField("请输入昵称，最多 20 个字符", text: $nickname)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($isNicknameFocused)
                        .font(.system(size: AppFontSize.field))
                        .padding(.horizontal, 16)
                        .frame(height: AppControlHeight.prominent)
                        .background(
                            RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                                .fill(Color.white)
                                .overlay(
                                    RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                                        .stroke(
                                            isNicknameFocused ? Color(red: 0.98, green: 0.65, blue: 0.00).opacity(0.78) : Color.black.opacity(0.10),
                                            lineWidth: isNicknameFocused ? 1.5 : 1
                                        )
                                )
                        )
                }

                Text("昵称最长 20 个字符。")
                    .font(.system(size: AppFontSize.metadata))
                    .foregroundStyle(AppTextColor.secondary)

                if let errorMessage, !errorMessage.isEmpty {
                    Text(errorMessage)
                        .font(.system(size: AppFontSize.metadata))
                        .foregroundStyle(.red)
                }

                HStack(spacing: 12) {
                    Button("取消") {
                        dismiss()
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity)
                    .frame(height: AppControlHeight.regular)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous))

                    Button(action: onSave) {
                        Text(isSaving ? "保存中..." : "保存")
                            .font(.system(size: AppFontSize.field, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: AppControlHeight.regular)
                            .background(Color(red: 0.98, green: 0.65, blue: 0.00), in: RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(isSaving)
                    .opacity(isSaving ? 0.7 : 1)
                }
                .padding(.top, 4)

                Spacer(minLength: 0)
            }
            .padding(24)
        }
        .task {
            try? await Task.sleep(for: .milliseconds(200))
            isNicknameFocused = true
        }
    }
}

private enum TopHintStyle {
    case normal
    case warning
}

private struct LightweightTopHint: View {
    let message: String
    let style: TopHintStyle

    var body: some View {
        HStack(spacing: 10) {
            if style == .warning {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color(red: 0.88, green: 0.35, blue: 0.10))
            }

            Text(message)
                .font(.system(size: AppFontSize.sectionLabel, weight: .semibold))
                .foregroundStyle(textColor)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, style == .warning ? 13 : 12)
        .frame(maxWidth: .infinity)
        .background(backgroundShape)
        .overlay(borderShape)
        .shadow(
            color: shadowColor,
            radius: style == .warning ? 18 : 14,
            x: 0,
            y: style == .warning ? 10 : 8
        )
    }

    private var textColor: Color {
        switch style {
        case .normal:
            return AppTextColor.primary
        case .warning:
            return Color(red: 0.52, green: 0.20, blue: 0.06)
        }
    }

    private var backgroundShape: some View {
        Capsule(style: .continuous)
            .fill(backgroundFill)
    }

    private var borderShape: some View {
        Capsule(style: .continuous)
            .strokeBorder(borderColor, lineWidth: style == .warning ? 1.5 : 0)
    }

    private var backgroundFill: LinearGradient {
        switch style {
        case .normal:
            return LinearGradient(
                colors: [Color.white.opacity(0.96), Color.white.opacity(0.96)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .warning:
            return LinearGradient(
                colors: [
                    Color(red: 1.00, green: 0.93, blue: 0.78),
                    Color(red: 1.00, green: 0.82, blue: 0.60)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    private var borderColor: Color {
        switch style {
        case .normal:
            return .clear
        case .warning:
            return Color(red: 0.96, green: 0.55, blue: 0.18).opacity(0.75)
        }
    }

    private var shadowColor: Color {
        switch style {
        case .normal:
            return Color.black.opacity(0.10)
        case .warning:
            return Color(red: 0.90, green: 0.40, blue: 0.10).opacity(0.24)
        }
    }
}

private struct WidgetSetupLinkCard: View {
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(red: 1.00, green: 0.96, blue: 0.89),
                                    Color(red: 0.94, green: 0.97, blue: 0.94)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )

                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color(red: 0.35, green: 0.30, blue: 0.22))
                }
                .frame(width: 50, height: 50)

                VStack(alignment: .leading, spacing: 6) {
                    Text("添加桌面小组件")
                        .font(.system(size: AppFontSize.bodyProminent, weight: .semibold))
                        .foregroundStyle(AppTextColor.primary)

                    Text("把随机回忆放到桌面，点开就能继续学习。")
                        .font(.system(size: AppFontSize.metadata))
                        .foregroundStyle(AppTextColor.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 10)

                Image(systemName: "chevron.right")
                    .font(.system(size: AppFontSize.metadata, weight: .semibold))
                    .foregroundStyle(AppTextColor.subtle)
            }
            .padding(18)
            .background(
                RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
        }
        .buttonStyle(.plain)
    }
}

private struct WidgetSetupSheet: View {
    @EnvironmentObject private var appModel: AppModel

    private struct PreviewContent {
        let imageData: Data
        let english: String
        let createdAt: Date
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 18) {
                previewSection
                stepsCard
            }
            .padding(.horizontal, AppSpacing.xLarge)
            .padding(.top, AppSpacing.xLarge + 2)
            .padding(.bottom, AppSpacing.xxLarge)
        }
        .background(Color(.systemGroupedBackground))
        .task {
            await MemoryWidgetSnapshotStore.refreshImmediately(with: appModel.memories)
        }
    }

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("效果预览")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.black.opacity(0.5))

            previewCard
        }
    }

    private var previewCard: some View {
        let preview = previewContent

        return HStack(spacing: 12) {
            previewImage(for: preview)
                .frame(width: 86, height: 86)
                .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous))

            VStack(alignment: .leading, spacing: 8) {
                Text(preview.english)
                    .font(.callout)
                    .foregroundStyle(Color(red: 0.24, green: 0.22, blue: 0.18))
                    .lineLimit(5)
                    .multilineTextAlignment(.leading)

                Spacer(minLength: 0)

                Text(preview.createdAt, style: .date)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

        }
        .padding(16)
        .frame(height: 118)
        .background(
            RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.98, green: 0.97, blue: 0.93),
                            Color(red: 0.95, green: 0.94, blue: 0.90)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
    }

    private var stepsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("添加步骤")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.black.opacity(0.5))

            WidgetSetupMethodCard(
                title: nil,
                steps: [
                    "长按桌面空白处，直到 App 开始晃动，再点击左上角的“编辑”或“+”。",
                    "在小组件列表里搜索“三句”。",
                    "选择“随机回忆”小组件并点击“添加小组件”。",
                    "把它放到你想要的位置后，再点“完成”。"
                ]
            )
        }
    }

    private var previewContent: PreviewContent {
        if let memory = appModel.memories
            .filter({ !$0.sentences.isEmpty })
            .max(by: { $0.createdAt < $1.createdAt }),
           let sentence = memory.sentences.first {
            return PreviewContent(
                imageData: memory.imageData,
                english: sentence.english,
                createdAt: memory.createdAt
            )
        }

        return PreviewContent(
            imageData: Data(),
            english: "A warm cup of coffee sits beside a quiet window.",
            createdAt: .now
        )
    }

    @ViewBuilder
    private func previewImage(for preview: PreviewContent) -> some View {
        if let image = UIImage(data: preview.imageData), !preview.imageData.isEmpty {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.92, green: 0.88, blue: 0.80),
                        Color(red: 0.84, green: 0.78, blue: 0.68)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                Image(systemName: "photo")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.white.opacity(0.92))
            }
        }
    }
}

private struct WidgetSetupMethodCard: View {
    let title: String?
    let steps: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color(red: 0.21, green: 0.21, blue: 0.20))
            }

            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .top, spacing: 12) {
                        Text("\(index + 1)")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 24, height: 24)
                            .background(Color.black, in: Circle())

                        Text(step)
                            .font(.system(size: 13))
                            .foregroundStyle(Color.black.opacity(0.48))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }
}

private struct ProfileAvatarView: View {
    var isMonochrome: Bool = false

    var body: some View {
        Image("ProfileAvatar")
            .resizable()
            .scaledToFill()
            .frame(width: 92, height: 92)
            .saturation(isMonochrome ? 0 : 1)
            .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous))
    }
}

private struct LearningReminderTimePickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTime: Date
    let isSaving: Bool
    let onSave: (Date) -> Void

    init(
        reminderTime: Date,
        isSaving: Bool,
        onSave: @escaping (Date) -> Void
    ) {
        _selectedTime = State(initialValue: reminderTime)
        self.isSaving = isSaving
        self.onSave = onSave
    }

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Text("选择提醒时间")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color.black.opacity(0.84))
                    .padding(.top, 32)

                DatePicker(
                    "提醒时间",
                    selection: $selectedTime,
                    displayedComponents: .hourAndMinute
                )
                .labelsHidden()
                .datePickerStyle(.wheel)
                .scaleEffect(1.08)
                .frame(maxWidth: .infinity)
                .frame(height: 236)
                .clipped()
                .padding(.top, 19)

                Button {
                    onSave(selectedTime)
                    dismiss()
                } label: {
                    HStack(spacing: AppSpacing.small) {
                        if isSaving {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white)
                        }
                        Text(isSaving ? "正在保存" : "保存")
                            .font(.system(size: AppFontSize.body, weight: .semibold))
                    }
                    .frame(width: 228)
                    .frame(height: 46)
                    .foregroundStyle(.white)
                    .background(
                        RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                            .fill(Color(red: 0.91, green: 0.52, blue: 0.17))
                    )
                }
                .buttonStyle(.plain)
                .disabled(isSaving)
                .padding(.top, 19)
            }
            .padding(.horizontal, AppSpacing.xLarge)
            .padding(.bottom, 5)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}

private struct ProfileCreditCard: View {
    let credits: Int
    let isPurchaseDisabled: Bool
    let onPurchase: () -> Void

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 6) {
                Text("可用次数")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.black.opacity(0.48))

                Text("\(credits)")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(Color(red: 0.25, green: 0.25, blue: 0.26))
            }

            Spacer()

            Button(action: onPurchase) {
                Text(isPurchaseDisabled ? "账号恢复中" : "购买次数")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(
                        isPurchaseDisabled ? Color.black.opacity(0.18) : Color(red: 0.98, green: 0.65, blue: 0.00),
                        in: Capsule()
                    )
            }
            .buttonStyle(.plain)
            .disabled(isPurchaseDisabled)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white, in: RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous))
        .appCardShadow()
    }
}

private struct ProfileCreditCardSkeleton: View {
    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 8) {
                RoundedRectangle(cornerRadius: AppCornerRadius.small, style: .continuous)
                    .fill(Color.black.opacity(0.06))
                    .frame(width: 58, height: 14)

                RoundedRectangle(cornerRadius: AppCornerRadius.small, style: .continuous)
                    .fill(Color.black.opacity(0.08))
                    .frame(width: 72, height: 34)
            }

            Spacer()

            RoundedRectangle(cornerRadius: AppCornerRadius.pill, style: .continuous)
                .fill(Color.black.opacity(0.06))
                .frame(width: 96, height: 38)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white, in: RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous))
        .appCardShadow()
    }
}

private struct PreferenceCard<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(title == "英语水平" ? Color(red: 0.17, green: 0.73, blue: 0.76) : Color(red: 0.18, green: 0.53, blue: 1.00))
                    .frame(width: 20, height: 20)

                Text(title)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.primary)
            }

            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous))
        .appCardShadow()
    }
}

struct PurchaseSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appModel: AppModel
    @State private var hasLoadedOffers = false

    var body: some View {
        NavigationStack {
            Group {
                if appModel.purchaseManager.offers.isEmpty && (!hasLoadedOffers || appModel.purchaseManager.isLoading) {
                    SyncLoadingState(
                        title: "正在准备购买方案...",
                        subtitle: "马上就好，正在同步最新价格"
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(purchaseSheetBackground)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            purchaseHero

                            if appModel.purchaseManager.offers.isEmpty {
                                PurchaseEmptyState(message: appModel.purchaseErrorMessage ?? "暂时没有可购买商品。")
                            } else {
                                VStack(spacing: 16) {
                                    ForEach(Array(appModel.purchaseManager.offers.enumerated()), id: \.element.id) { index, offer in
                                        PurchaseOfferCard(
                                            offer: offer,
                                            isRecommended: index == appModel.purchaseManager.offers.count - 1,
                                            isPreparingPurchaseSession: appModel.isPurchaseSessionPreparing,
                                            isConnectingToAppStore: appModel.isStartingPurchase || appModel.purchaseManager.isPurchasing,
                                            isCompletingPurchase: appModel.isCompletingPurchase
                                        ) {
                                            Task {
                                                await appModel.purchaseProduct(productID: offer.product.id)
                                                if appModel.purchaseErrorMessage == nil {
                                                    dismiss()
                                                }
                                            }
                                        }
                                    }
                                }
                            }

                            if let purchaseErrorMessage = appModel.purchaseErrorMessage {
                                Text(purchaseErrorMessage)
                                    .font(.footnote)
                                    .foregroundStyle(.red)
                                    .padding(.horizontal, 4)
                            }

                            Text("购买后次数会同步到你的账号，可在多设备继续使用。")
                                .font(.system(size: 12))
                                .foregroundStyle(Color.black.opacity(0.42))
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.top, 4)
                        }
                        .padding(20)
                        .padding(.bottom, 32)
                    }
                }
            }
            .background(purchaseSheetBackground)
            .navigationTitle("购买次数")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                if appModel.purchaseManager.offers.isEmpty {
                    await appModel.loadPurchaseOffers()
                    hasLoadedOffers = true
                } else {
                    hasLoadedOffers = true
                    Task {
                        await appModel.loadPurchaseOffers()
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") {
                        dismiss()
                    }
                }
            }
        }
    }

    private var purchaseHero: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 1.00, green: 0.96, blue: 0.88),
                            Color(red: 0.99, green: 0.89, blue: 0.72)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay {
                    RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous)
                        .stroke(AppStroke.highlight, lineWidth: 1)
                }

            Circle()
                .fill(Color.white.opacity(0.26))
                .frame(width: 136, height: 136)
                .offset(x: 28, y: -28)

            VStack(alignment: .leading, spacing: 16) {
                Text("继续记录你的生活\n也继续积累你的英语表达")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(Color(red: 0.30, green: 0.23, blue: 0.14))
                    .lineSpacing(4)

                Text("每次上传一张照片，都会生成三句适合学习的英文描述与中文翻译。")
                    .font(.system(size: 14))
                    .foregroundStyle(Color(red: 0.39, green: 0.31, blue: 0.20))
                    .lineSpacing(3)

                HStack(spacing: 10) {
                    PurchaseMiniPill(text: "当前剩余 \(appModel.remainingCredits) 次")
                }
            }
            .padding(AppSpacing.xLarge)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 188)
    }

    private var purchaseSheetBackground: some View {
        LinearGradient(
            colors: [
                Color(red: 0.98, green: 0.96, blue: 0.92),
                Color(red: 0.95, green: 0.95, blue: 0.97)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }
}

private struct PurchaseMiniPill: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color(red: 0.45, green: 0.31, blue: 0.10))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.84), in: Capsule())
    }
}

private struct PurchaseOfferCard: View {
    let offer: StoreProductOffer
    let isRecommended: Bool
    let isPreparingPurchaseSession: Bool
    let isConnectingToAppStore: Bool
    let isCompletingPurchase: Bool
    let onPurchase: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(offer.product.displayName)
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(Color(red: 0.23, green: 0.23, blue: 0.23))

                        if isRecommended {
                            Text("推荐")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Color(red: 0.98, green: 0.65, blue: 0.00), in: Capsule())
                        }
                    }

                    Text("增加 \(offer.credits) 次生成机会")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.black.opacity(0.5))
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    Text(normalizedPriceText)
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(Color(red: 0.98, green: 0.65, blue: 0.00))
                }
            }

            Button(action: onPurchase) {
                HStack {
                    Spacer()
                    Text(buttonTitle)
                        .font(.system(size: 16, weight: .semibold))
                    Spacer()
                }
                .padding(.vertical, 12)
                .foregroundStyle(isRecommended ? .white : Color(red: 0.98, green: 0.65, blue: 0.00))
                .background(
                    RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                        .fill(isRecommended ? Color(red: 0.98, green: 0.65, blue: 0.00) : Color.white)
                )
                .overlay {
                    if !isRecommended {
                        RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                            .stroke(Color(red: 0.98, green: 0.65, blue: 0.00).opacity(0.35), lineWidth: 1)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(isBusy)
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous)
                .fill(isRecommended ? Color.white : Color.white.opacity(0.9))
        )
        .overlay {
            RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous)
                .stroke(isRecommended ? Color(red: 0.98, green: 0.65, blue: 0.00).opacity(0.28) : AppStroke.highlight, lineWidth: 1)
        }
        .appCardShadow()
    }

    private var normalizedPriceText: String {
        offer.product.displayPrice
    }

    private var isBusy: Bool {
        isPreparingPurchaseSession || isConnectingToAppStore || isCompletingPurchase
    }

    private var buttonTitle: String {
        if isPreparingPurchaseSession {
            return "正在恢复账号..."
        }

        if isCompletingPurchase {
            return "正在完成购买..."
        }

        if isConnectingToAppStore {
            return "正在连接 App Store..."
        }

        return "立即购买"
    }
}

private struct PurchaseEmptyState: View {
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "cart")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(Color(red: 0.98, green: 0.65, blue: 0.00))

            Text(message)
                .font(.system(size: 14))
                .foregroundStyle(Color.black.opacity(0.5))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .background(Color.white.opacity(0.82), in: RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous))
    }
}
