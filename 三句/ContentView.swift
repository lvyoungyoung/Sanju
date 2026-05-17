//
//  ContentView.swift
//  三句
//
//  Created by 吕扬 on 2026/3/31.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var appModel = AppModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var signInSheetHeight: CGFloat = 380

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                MainTabView()
                    .environmentObject(appModel)
                if appModel.isDeletingAccount {
                    GlobalBlockingLoadingOverlay(title: L10n.string("account.delete.loading", "正在删除账号，请勿关闭应用"))
                }
            }
            .alert(L10n.string("common.notice", "提示"), isPresented: credentialWarningAlertBinding) {
                Button(L10n.string("common.got_it", "知道了"), role: .cancel) {
                    appModel.credentialWarningMessage = nil
                }
            } message: {
                Text(appModel.credentialWarningMessage ?? "")
            }
            .sheet(isPresented: signInSheetBinding) {
                SignInView(
                    preferredSheetHeight: $signInSheetHeight,
                    maxSheetHeight: max(proxy.size.height * 0.88, 280)
                )
                    .environmentObject(appModel)
                    .presentationDetents([.height(signInSheetHeight)])
                    .presentationBackground(AppSurfaceColor.page)
                    .presentationDragIndicator(.visible)
            }
            .onOpenURL { url in
                appModel.handleIncomingURL(url)
            }
            .onAppear {
                openFavoritesIfNeededFromLearningReminder()
            }
            .onReceive(NotificationCenter.default.publisher(for: LearningReminderNotificationRoute.didRequestOpenFavorites)) { _ in
                openFavoritesIfNeededFromLearningReminder()
            }
            .onChange(of: scenePhase) { _, newPhase in
                guard newPhase == .active else { return }
                openFavoritesIfNeededFromLearningReminder()
                appModel.syncOnForegroundIfNeeded()
            }
        }
    }

    private func openFavoritesIfNeededFromLearningReminder() {
        guard LearningReminderNotificationRoute.consumeOpenFavoritesRequest() else {
            return
        }

        appModel.selectedTab = .favorites
    }

    private var credentialWarningAlertBinding: Binding<Bool> {
        Binding(
            get: { appModel.credentialWarningMessage != nil },
            set: { isPresented in
                if !isPresented {
                    appModel.credentialWarningMessage = nil
                }
            }
        )
    }

    private var signInSheetBinding: Binding<Bool> {
        Binding(
            get: { appModel.isShowingSignInSheet },
            set: { isPresented in
                guard isPresented else {
                    appModel.isShowingSignInSheet = false
                    return
                }

                guard !appModel.hasActiveGenerationTask else {
                    appModel.credentialWarningMessage = L10n.string(
                        "profile.guard.generation_in_progress",
                        "正在为您生成描述，请稍后操作。"
                    )
                    appModel.isShowingSignInSheet = false
                    return
                }

                appModel.isShowingSignInSheet = true
            }
        )
    }

}

struct SyncLoadingState: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: AppSpacing.large) {
            ZStack {
                RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous)
                    .fill(AppSurfaceColor.card)
                    .frame(width: 86, height: 86)
                    .appHeroShadow()

                ThinkingIndicator()
                    .scaleEffect(1.15)
            }

            Text(title)
                .font(.system(size: AppFontSize.field, weight: .semibold))
                .foregroundStyle(AppTextColor.primary)

            Text(subtitle)
                .font(.system(size: AppFontSize.sectionLabel))
                .foregroundStyle(AppTextColor.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

struct GlobalBlockingLoadingOverlay: View {
    let title: String

    var body: some View {
        ZStack {
            Color.black.opacity(0.18)
                .ignoresSafeArea()

            VStack(spacing: AppSpacing.large) {
                ZStack {
                    RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous)
                        .fill(AppSurfaceColor.card)
                        .frame(width: 86, height: 86)
                        .appHeroShadow()

                    ThinkingIndicator()
                        .scaleEffect(1.15)
                }

                Text(title)
                    .font(.system(size: AppFontSize.field, weight: .semibold))
                    .foregroundStyle(AppTextColor.primary)
            }
            .padding(.horizontal, AppSpacing.xxLarge)
            .padding(.vertical, AppSpacing.section)
            .background(
                RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous)
                    .fill(AppSurfaceColor.elevated)
            )
            .appCardShadow()
            .padding(.horizontal, AppSpacing.xxxLarge)
        }
        .transition(.opacity)
    }
}

struct ContentFooterHint: View {
    let isLoading: Bool

    var body: some View {
        HStack(spacing: AppSpacing.small) {
            if isLoading {
                ProgressView()
                    .controlSize(.small)
            }

            Text(
                isLoading
                ? L10n.string("common.status.syncing_footer", "正在同步，请稍后")
                : L10n.string("common.status.all_content_displayed", "已显示全部内容")
            )
                .font(.system(size: AppFontSize.metadata))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 6)
    }
}

struct SentenceSkeletonSection: View {
    @State private var phase: CGFloat = -0.35

    var body: some View {
        VStack(spacing: AppSpacing.medium) {
            ForEach(0..<3, id: \.self) { _ in
                RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                    .fill(AppSurfaceColor.secondaryFill)
                    .frame(height: 66)
                    .overlay {
                        GeometryReader { proxy in
                            LinearGradient(
                                colors: [
                                    Color.clear,
                                    Color(.systemBackground).opacity(0.28),
                                    Color.clear
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                            .frame(width: proxy.size.width * 0.32)
                            .offset(x: proxy.size.width * phase)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous))
                        .allowsHitTesting(false)
                    }
            }
        }
        .onAppear {
            withAnimation(.linear(duration: 1.25).repeatForever(autoreverses: false)) {
                phase = 1.05
            }
        }
    }
}

struct GenerationProgressCard: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String

    var body: some View {
        HStack(spacing: AppSpacing.medium) {
            ThinkingIndicator()

            Text(title)
                .font(.system(.body, design: .rounded))
                .foregroundStyle(colorScheme == .dark ? .white : .primary)
        }
        .padding(.horizontal, AppSpacing.large)
        .padding(.vertical, AppSpacing.medium)
        .frame(maxWidth: .infinity, alignment: .center)
        .background(
            RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                .fill(AppSurfaceColor.card)
        )
    }
}

struct ThinkingIndicator: View {
    @State private var isAnimating = false

    var body: some View {
        HStack(spacing: AppSpacing.xSmall) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Color.orange.opacity(0.82))
                    .frame(width: 6, height: 6)
                    .scaleEffect(isAnimating ? 1 : 0.52)
                    .opacity(isAnimating ? 1 : 0.3)
                    .animation(
                        .easeInOut(duration: 0.6)
                        .repeatForever()
                        .delay(Double(index) * 0.18),
                        value: isAnimating
                    )
            }
        }
        .frame(width: 26, height: 14)
        .onAppear {
            isAnimating = true
        }
    }
}

struct EmptyStateView: View {
    let title: String
    let subtitle: String
    var systemImage: String = "rectangle.stack.badge.person.crop"

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(subtitle)
        }
    }
}

#Preview {
    ContentView()
}
