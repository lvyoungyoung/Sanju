import SwiftUI
import UIKit

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
            VStack(alignment: .leading, spacing: AppSpacing.section) {
                favoriteTopicCard

                Text(L10n.string("study.scene.my_scenes", "我的学习主题"))
                    .font(.system(size: AppFontSize.sectionLabel, weight: .semibold))
                    .foregroundStyle(AppTextColor.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                LazyVStack(spacing: AppSpacing.medium) {
                    ForEach(appModel.userStudySceneSummaries) { scene in
                        userStudySceneCard(scene)
                    }

                    createSceneTile
                }
            }
            .padding(.horizontal, AppSpacing.xLarge)
            .padding(.top, AppSpacing.xLarge)
            .padding(.bottom, 120)
        }
        .background(AppSurfaceColor.page)
        .navigationTitle(L10n.string("study.topic.page_title", "学习"))
        .navigationBarTitleDisplayMode(.large)
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(AppSurfaceColor.page, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
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

    private var favoriteTopicCard: some View {
        let cachedSummary = appModel.sentenceStudyTopicSummaries[.favorites] ?? .empty
        let summary = SentenceStudyTopicSummary(
            totalCount: appModel.favorites.count,
            dueCount: cachedSummary.dueCount,
            studiedCount: cachedSummary.studiedCount,
            reviewableTodayCount: cachedSummary.reviewableTodayCount,
            masteryScore: cachedSummary.masteryScore
        )
        let tint = SentenceStudyTopic.favorites.tintColor

        return NavigationLink(value: StudySceneDetailRoute.favorites) {
            ZStack {
                topicPhotoBackground(image: nil, fallbackTint: tint)

                HStack(alignment: .top, spacing: AppSpacing.large) {
                    Image(systemName: "heart.fill")
                        .font(.system(size: AppFontSize.cardTitle, weight: .semibold))
                        .foregroundStyle(tint)
                        .frame(width: 48, height: 48)
                        .background(
                            Color.white.opacity(0.72),
                            in: RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                        )

                    VStack(alignment: .leading, spacing: AppSpacing.small) {
                        Text(SentenceStudyTopic.favorites.title)
                            .font(.system(size: AppFontSize.panelTitle, weight: .bold))
                            .foregroundStyle(AppTextColor.primary)

                        Text(
                            L10n.string(
                                "study.scene.detail.sentence_count",
                                "共 %d 句",
                                summary.totalCount
                            )
                        )
                        .font(.system(size: AppFontSize.metadata, weight: .medium))
                        .foregroundStyle(AppTextColor.secondary)

                        masteryProgress(
                            summary: summary,
                            textColor: AppTextColor.secondary
                        )
                    }

                    Spacer(minLength: 0)

                    Image(systemName: "arrow.up.right")
                        .font(.system(size: AppIconSize.regular, weight: .semibold))
                        .foregroundStyle(AppTextColor.tertiary)
                        .padding(.top, AppSpacing.xSmall)
                }
                .padding(AppSpacing.xLarge)
            }
            .frame(maxWidth: .infinity, minHeight: 142, maxHeight: 142)
            .contentShape(RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous)
                    .stroke(tint.opacity(0.18), lineWidth: 1)
            }
            .appAccentShadow(tint, opacity: 0.08)
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
        let tint = sceneTint(for: scene)

        return NavigationLink(value: StudySceneDetailRoute.userScene(scene)) {
            sceneListCardContent(scene: scene, tint: tint)
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

    private func sceneListCardContent(
        scene: UserStudySceneSummary,
        tint: Color
    ) -> some View {
        let coverImage = scene.coverMemoryID.flatMap(memoryImage(for:))

        return HStack(spacing: AppSpacing.medium) {
            sceneCover(image: coverImage, tint: tint)

            VStack(alignment: .leading, spacing: AppSpacing.small) {
                HStack(alignment: .firstTextBaseline, spacing: AppSpacing.small) {
                    Text(scene.name)
                        .font(.system(size: AppFontSize.bodyProminent, weight: .semibold))
                        .foregroundStyle(AppTextColor.primary)
                        .lineLimit(1)

                    Spacer(minLength: 0)

                    Image(systemName: "chevron.right")
                        .font(.system(size: AppIconSize.compact, weight: .semibold))
                        .foregroundStyle(AppTextColor.tertiary)
                }

                Text(
                    L10n.string(
                        "study.scene.detail.sentence_count",
                        "共 %d 句",
                        scene.summary.totalCount
                    )
                )
                .font(.system(size: AppFontSize.metadata, weight: .medium))
                .foregroundStyle(AppTextColor.secondary)

                Spacer(minLength: AppSpacing.xSmall)

                masteryProgress(
                    summary: scene.summary,
                    textColor: AppTextColor.secondary
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(AppSpacing.medium)
        .frame(maxWidth: .infinity, minHeight: 128, maxHeight: 128, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous))
        .background(AppSurfaceColor.card, in: RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous)
                .stroke(AppStroke.subtle, lineWidth: 1)
        }
        .appCardShadow()
    }

    @ViewBuilder
    private func sceneCover(image: UIImage?, tint: Color) -> some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: AppIconSize.regular, weight: .medium))
                    .foregroundStyle(tint)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(tint.opacity(0.14))
            }
        }
        .frame(width: 96, height: 104)
        .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous))
        .allowsHitTesting(false)
    }

    private func masteryProgress(
        summary: SentenceStudyTopicSummary,
        textColor: Color
    ) -> some View {
        Text(
            L10n.string(
                "study.topic.mastery",
                "掌握度 %d%%",
                summary.masteryScore
            )
        )
        .font(.system(size: AppFontSize.caption, weight: .medium))
        .foregroundStyle(textColor)
    }

    private func sceneTint(for scene: UserStudySceneSummary) -> Color {
        let palette: [Color] = [
            Color(red: 0.29, green: 0.56, blue: 0.86),
            Color(red: 0.24, green: 0.58, blue: 0.40),
            Color(red: 0.86, green: 0.45, blue: 0.18),
            Color(red: 0.56, green: 0.40, blue: 0.78),
            Color(red: 0.76, green: 0.38, blue: 0.45),
            Color(red: 0.40, green: 0.45, blue: 0.60)
        ]
        let index = scene.id.uuidString.unicodeScalars.reduce(0) { $0 + Int($1.value) } % palette.count
        return palette[index]
    }

    private func memoryImage(for memoryID: UUID) -> UIImage? {
        guard let imageData = appModel.memories.first(where: { $0.id == memoryID })?.imageData,
              !imageData.isEmpty else {
            return nil
        }
        return UIImage(data: imageData)
    }

    @ViewBuilder
    private func topicPhotoBackground(image: UIImage?, fallbackTint: Color) -> some View {
        GeometryReader { proxy in
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()
                    .blur(radius: 0.5)
                    .scaleEffect(1.14)
                    .overlay(Color.black.opacity(0.24))
            } else {
                fallbackTint.opacity(0.13)
                    .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
        .allowsHitTesting(false)
    }

    private var createSceneTile: some View {
        Button {
            guard appModel.isSignedIn else {
                appModel.isShowingSignInSheet = true
                return
            }
            newSceneName = ""
            refreshSceneSuggestions()
            isShowingCreateScene = true
        } label: {
            HStack(spacing: AppSpacing.medium) {
                Image(systemName: "plus")
                    .font(.system(size: AppFontSize.cardTitle, weight: .semibold))
                    .foregroundStyle(AppTextColor.secondary)
                    .frame(width: 42, height: 42)
                    .background(AppSurfaceColor.secondaryFill, in: Circle())

                Text(L10n.string("study.scene.create", "创建我的学习主题"))
                    .font(.system(size: AppFontSize.bodyProminent, weight: .semibold))
                    .foregroundStyle(AppTextColor.primary)

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: AppIconSize.compact, weight: .semibold))
                    .foregroundStyle(AppTextColor.tertiary)
            }
            .padding(AppSpacing.medium)
            .frame(maxWidth: .infinity, minHeight: 104)
            .background(AppSurfaceColor.card, in: RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous)
                    .stroke(AppStroke.soft, style: StrokeStyle(lineWidth: 1, dash: [6, 5]))
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
