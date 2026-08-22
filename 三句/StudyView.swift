import SwiftUI

struct StudyView: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var errorMessage: String?
    @State private var isShowingCreateScene = false
    @State private var newSceneName = ""
    @State private var displayedSceneSuggestions: [String] = []
    @State private var isCreatingScene = false
    @State private var scenePendingDeletion: UserStudySceneSummary?
    @State private var isDeletingScene = false

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: AppSpacing.large) {
                LazyVStack(spacing: AppSpacing.medium) {
                    topicCard(.favorites)

                    if !appModel.userStudySceneSummaries.isEmpty {
                        Text(L10n.string("study.scene.my_scenes", "我的学习主题"))
                            .font(.system(size: AppFontSize.sectionLabel, weight: .semibold))
                            .foregroundStyle(AppTextColor.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, AppSpacing.small)

                        ForEach(appModel.userStudySceneSummaries) { scene in
                            userStudySceneCard(scene)
                        }
                    }
                }

                createSceneButton
            }
            .padding(.horizontal, AppSpacing.xLarge)
            .padding(.top, AppSpacing.xLarge)
            .padding(.bottom, 120)
        }
        .background(AppSurfaceColor.page)
        .toolbar(.hidden, for: .navigationBar)
        .task {
            await appModel.refreshUserStudySceneSummaries()
        }
        .refreshable {
            await appModel.refreshUserStudySceneSummaries()
        }
        .alert(L10n.string("study.alert.title", "学习提醒"), isPresented: errorAlertBinding) {
            Button(L10n.string("common.got_it", "知道了"), role: .cancel) {
                errorMessage = nil
            }
        } message: {
            Text(errorMessage ?? "")
        }
        .alert(
            L10n.string("study.scene.delete_confirmation_title", "删除这个学习主题？"),
            isPresented: sceneDeletionAlertBinding,
            presenting: scenePendingDeletion
        ) { scene in
            Button(L10n.string("common.delete", "删除"), role: .destructive) {
                Task { await deleteScene(scene) }
            }
            Button(L10n.string("common.cancel", "取消"), role: .cancel) {}
        } message: { _ in
            Text(
                L10n.string(
                    "study.scene.delete_confirmation_message",
                    "删除后，该主题的匹配结果和学习记录将被清除，原始回忆和句子不会受到影响。"
                )
            )
        }
        .sheet(isPresented: $isShowingCreateScene) {
            CreateStudySceneSheet(
                sceneName: $newSceneName,
                suggestedSceneNames: $displayedSceneSuggestions,
                isCreating: isCreatingScene,
                onRefreshSuggestions: refreshSceneSuggestions,
                onCreate: createScene
            )
            .presentationDetents([.height(460)])
            .presentationBackground(AppSurfaceColor.page)
            .presentationDragIndicator(.visible)
        }
    }

    private func topicCard(_ topic: SentenceStudyTopic) -> some View {
        let summary = appModel.sentenceStudyTopicSummaries[topic] ?? .empty

        return NavigationLink(value: StudySceneDetailRoute.favorites) {
            sceneCardContent(
                title: topic.title,
                iconName: topic.iconName,
                tint: topic.tintColor,
                summary: summary
            )
        }
        .buttonStyle(.plain)
    }

    private var availableSceneNames: [String] {
        let counts = appModel.memories
            .flatMap(\.sentences)
            .map(\.sceneHint)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .reduce(into: [String: Int]()) { counts, hint in
                counts[hint, default: 0] += 1
            }

        return Array(counts.keys)
    }

    private func refreshSceneSuggestions() {
        let availableNames = availableSceneNames
        guard !availableNames.isEmpty else {
            displayedSceneSuggestions = []
            return
        }

        var suggestions = Array(availableNames.shuffled().prefix(4))

        // With more than four choices, avoid showing the exact same batch again.
        if availableNames.count > 4,
           Set(suggestions) == Set(displayedSceneSuggestions),
           let replacement = availableNames.first(where: { !displayedSceneSuggestions.contains($0) }) {
            suggestions = Array(displayedSceneSuggestions.dropLast()) + [replacement]
        }

        displayedSceneSuggestions = suggestions
    }

    private func userStudySceneCard(_ scene: UserStudySceneSummary) -> some View {
        let tint = Color(red: 0.53, green: 0.40, blue: 0.73)

        return NavigationLink(value: StudySceneDetailRoute.userScene(scene)) {
            sceneCardContent(
                title: scene.name,
                iconName: "bookmark.fill",
                tint: tint,
                summary: scene.summary
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) {
                scenePendingDeletion = scene
            } label: {
                Label(
                    L10n.string("study.scene.delete", "删除学习主题"),
                    systemImage: "trash"
                )
            }
        }
        .disabled(isDeletingScene)
    }

    private func sceneCardContent(
        title: String,
        iconName: String,
        tint: Color,
        summary: SentenceStudyTopicSummary
    ) -> some View {
        HStack(spacing: AppSpacing.large) {
            Image(systemName: iconName)
                .font(.system(size: AppFontSize.cardTitle, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 44, height: 44)
                .background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous))

            VStack(alignment: .leading, spacing: AppSpacing.small) {
                Text(title)
                    .font(.system(size: AppFontSize.bodyProminent, weight: .semibold))
                    .foregroundStyle(AppTextColor.primary)

                VStack(alignment: .leading, spacing: 5) {
                    Text(
                        L10n.string(
                            "study.topic.mastery",
                            "掌握度 %d%%",
                            summary.masteryScore
                        )
                    )
                    .font(.system(size: AppFontSize.metadata, weight: .medium))
                    .foregroundStyle(AppTextColor.secondary)

                    GeometryReader { proxy in
                        Capsule()
                            .fill(AppSurfaceColor.secondaryFill)
                            .overlay(alignment: .leading) {
                                Capsule()
                                    .fill(tint)
                                    .frame(width: proxy.size.width * CGFloat(summary.masteryScore) / 100)
                            }
                    }
                    .frame(height: 5)
                }
            }

            Spacer(minLength: AppSpacing.small)

            Image(systemName: "chevron.right")
                .font(.system(size: AppIconSize.regular, weight: .semibold))
                .foregroundStyle(AppTextColor.tertiary)
        }
        .padding(AppSpacing.large)
        .background(AppSurfaceColor.card, in: RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous)
                .stroke(AppStroke.subtle, lineWidth: 1)
        }
    }

    private var createSceneButton: some View {
        Button {
            guard appModel.isSignedIn else {
                appModel.isShowingSignInSheet = true
                return
            }
            newSceneName = ""
            refreshSceneSuggestions()
            isShowingCreateScene = true
        } label: {
            Label(
                L10n.string("study.scene.create", "创建我的学习主题"),
                systemImage: "plus.circle.fill"
            )
            .font(.system(size: AppFontSize.bodyProminent, weight: .semibold))
            .foregroundStyle(AppTextColor.primary)
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background(AppSurfaceColor.card, in: RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous)
                    .stroke(AppStroke.highlight, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }

    private var errorAlertBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { isPresented in
                if !isPresented { errorMessage = nil }
            }
        )
    }

    private var sceneDeletionAlertBinding: Binding<Bool> {
        Binding(
            get: { scenePendingDeletion != nil },
            set: { isPresented in
                if !isPresented {
                    scenePendingDeletion = nil
                }
            }
        )
    }

    @MainActor
    private func createScene() async {
        let name = newSceneName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        isCreatingScene = true
        defer { isCreatingScene = false }

        do {
            let scene = try await appModel.createUserStudyScene(named: name)
            isShowingCreateScene = false
            newSceneName = ""
            appModel.studyNavigationPath.append(.userScene(scene))
        } catch {
            errorMessage = error.localizedDescription.isEmpty
                ? L10n.string("study.scene.create_failed", "暂时无法创建学习主题，请稍后再试。")
                : error.localizedDescription
        }
    }

    @MainActor
    private func deleteScene(_ scene: UserStudySceneSummary) async {
        scenePendingDeletion = nil
        isDeletingScene = true
        defer { isDeletingScene = false }

        do {
            try await appModel.deleteUserStudyScene(scene)
        } catch {
            errorMessage = error.localizedDescription.isEmpty
                ? L10n.string("study.scene.delete_failed", "暂时无法删除学习主题，请稍后再试。")
                : error.localizedDescription
        }
    }
}

private struct CreateStudySceneSheet: View {
    @EnvironmentObject private var appModel: AppModel
    @Binding var sceneName: String
    @Binding var suggestedSceneNames: [String]
    let isCreating: Bool
    let onRefreshSuggestions: () -> Void
    let onCreate: () async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.large) {
            Text(L10n.string("study.scene.create_title", "创建我的学习主题"))
                .font(.system(size: AppFontSize.field, weight: .bold))
                .foregroundStyle(AppTextColor.title)

            Text(L10n.string("study.scene.create_hint", "例如：海边度假、和朋友聚会、雨天通勤"))
                .font(.system(size: AppFontSize.body))
                .foregroundStyle(AppTextColor.secondary)

            if !suggestedSceneNames.isEmpty {
                VStack(alignment: .leading, spacing: AppSpacing.small) {
                    HStack(spacing: AppSpacing.small) {
                        Text(L10n.string("study.scene.suggestions_title", "根据你的句子推荐"))
                            .font(.system(size: AppFontSize.metadata, weight: .medium))
                            .foregroundStyle(AppTextColor.secondary)

                        Spacer(minLength: AppSpacing.small)

                        Button(action: onRefreshSuggestions) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: AppIconSize.compact, weight: .semibold))
                                .foregroundStyle(AppTextColor.secondary)
                                .frame(width: 32, height: 28)
                                .background(AppSurfaceColor.secondaryFill, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L10n.string("study.scene.refresh_suggestions", "换一批推荐"))
                    }

                    StudyFlowLayout(horizontalSpacing: 8, verticalSpacing: 8) {
                        ForEach(suggestedSceneNames, id: \.self) { topicName in
                            Button {
                                sceneName = topicName
                            } label: {
                                Text(topicName)
                                    .font(.system(size: AppFontSize.metadata, weight: .medium))
                                    .foregroundStyle(sceneName == topicName ? Color.orange : AppTextColor.primary)
                                    .padding(.horizontal, AppSpacing.medium)
                                    .frame(height: 32)
                                    .background(
                                        sceneName == topicName ? Color.orange.opacity(0.14) : AppSurfaceColor.secondaryFill,
                                        in: Capsule()
                                    )
                                    .overlay {
                                        Capsule()
                                            .stroke(sceneName == topicName ? Color.orange.opacity(0.38) : AppStroke.subtle, lineWidth: 1)
                                    }
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint(L10n.string("study.scene.suggestion_fill_hint", "填入学习主题"))
                        }
                    }
                }
            }

            TextField(
                L10n.string("study.scene.name_placeholder", "输入你想学习的主题"),
                text: $sceneName
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .padding(.horizontal, AppSpacing.large)
            .frame(height: 50)
            .background(AppSurfaceColor.elevated, in: RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous))

            Button {
                Task { await onCreate() }
            } label: {
                Group {
                    if isCreating {
                        HStack(spacing: AppSpacing.small) {
                            ProgressView().tint(AppTextColor.inverse)
                            Text(L10n.string("study.scene.creating", "正在整理主题..."))
                                .font(.system(size: AppFontSize.bodyProminent, weight: .semibold))
                        }
                    } else {
                        Text(L10n.string("common.create", "创建"))
                            .font(.system(size: AppFontSize.bodyProminent, weight: .semibold))
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .foregroundStyle(AppTextColor.inverse)
                .background(sceneName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? AppSurfaceColor.subtleFill : Color.orange, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(isCreating || sceneName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(AppSpacing.xLarge)
        .onAppear {
            if suggestedSceneNames.isEmpty {
                onRefreshSuggestions()
            }
        }
        .onChange(of: sceneHintSignature) { _ in
            // The sheet can appear before the first remote-memory sync finishes.
            guard suggestedSceneNames.isEmpty else { return }
            onRefreshSuggestions()
        }
    }

    private var sceneHintSignature: [String] {
        appModel.memories
            .flatMap(\.sentences)
            .map(\.sceneHint)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .sorted()
    }
}
