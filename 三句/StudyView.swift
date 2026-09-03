import SwiftUI
import UIKit

struct StudyView: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var errorMessage: String?
    @State private var isShowingCreateScene = false
    @State private var newSceneName = ""
    @State private var selectedSuggestedTopicID: String?
    @State private var displayedSceneSuggestions: [LearningTopic] = []
    @State private var isCreatingScene = false
    @State private var scenePendingDeletion: UserStudySceneSummary?
    @State private var isDeletingScene = false
    @State private var isStartingFavoriteStudy = false
    @State private var favoriteStudySession: SentenceStudyTopicSession?
    @State private var pageTitleOriginY: CGFloat?
    @State private var pageTitleMinY: CGFloat = 0

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: AppSpacing.section) {
                pageHeader

                favoriteStudySection

                topicSectionHeader

                LazyVStack(spacing: AppSpacing.xLarge) {
                    ForEach(appModel.userStudySceneSummaries) { scene in
                        userStudySceneCard(scene)
                    }
                }
            }
            .padding(.horizontal, AppSpacing.xLarge)
            .padding(.top, AppSpacing.xLarge)
            .padding(.bottom, 120)
        }
        .coordinateSpace(name: StudyPageScrollMetrics.coordinateSpaceName)
        .background(AppSurfaceColor.page)
        .toolbar(.hidden, for: .navigationBar)
        .onPreferenceChange(StudyPageTitleMinYPreferenceKey.self) { minY in
            if pageTitleOriginY == nil {
                pageTitleOriginY = minY
            }
            pageTitleMinY = minY
        }
        .task {
            await appModel.refreshSentenceStudyDueCount()
        }
        .refreshable {
            await appModel.refreshSentenceStudyDueCount()
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
                selectedSuggestedTopicID: $selectedSuggestedTopicID,
                suggestedSceneNames: $displayedSceneSuggestions,
                isCreating: isCreatingScene,
                onRefreshSuggestions: refreshSceneSuggestions,
                onCreate: createScene
            )
            .presentationDetents([.height(320)])
            .presentationBackground(AppSurfaceColor.page)
            .presentationDragIndicator(.visible)
        }
        .fullScreenCover(item: $favoriteStudySession) { session in
            SentenceStudySessionView(
                queue: session.queue,
                studyTopic: session.topic,
                startsInReviewMode: session.startsInReviewMode,
                repeatsActiveQueueOnCompletion: true,
                onDismiss: {
                    favoriteStudySession = nil
                    Task {
                        await appModel.refreshSentenceStudyDueCount()
                        await appModel.refreshUserStudySceneSummaries()
                    }
                }
            )
            .environmentObject(appModel)
        }
    }

    private var pageHeader: some View {
        Text(L10n.string("study.topic.page_title", "学习"))
            .font(.system(size: 34, weight: .bold))
            .foregroundStyle(AppTextColor.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(pageTitleOpacity)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: StudyPageTitleMinYPreferenceKey.self,
                        value: proxy.frame(in: .named(StudyPageScrollMetrics.coordinateSpaceName)).minY
                    )
                }
            }
    }

    private var pageTitleOpacity: Double {
        guard let pageTitleOriginY else { return 1 }
        let fadeDistance: CGFloat = 64
        return min(1, max(0, Double((pageTitleMinY - pageTitleOriginY + fadeDistance) / fadeDistance)))
    }

    private var favoriteSummary: SentenceStudyTopicSummary {
        let cachedSummary = appModel.sentenceStudyTopicSummaries[.favorites] ?? .empty
        return SentenceStudyTopicSummary(
            totalCount: appModel.favorites.count,
            dueCount: cachedSummary.dueCount,
            studiedCount: cachedSummary.studiedCount,
            reviewableTodayCount: cachedSummary.reviewableTodayCount,
            masteryScore: cachedSummary.masteryScore
        )
    }

    private var favoriteStudySection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.medium) {
            HStack(alignment: .firstTextBaseline) {
                Text(
                    L10n.string(
                        "study.topic.favorites_count",
                        "收藏（%d）",
                        appModel.favorites.count
                    )
                )
                .font(.system(size: AppFontSize.cardTitle, weight: .semibold))
                .foregroundStyle(AppTextColor.primary)

                Spacer(minLength: AppSpacing.small)

                NavigationLink(value: StudySceneDetailRoute.favorites) {
                    Text(L10n.string("study.topic.view_all", "查看全部"))
                        .font(.system(size: AppFontSize.body, weight: .medium))
                        .foregroundStyle(Color.orange)
                }
                .buttonStyle(.plain)
            }

            favoriteStudyOverview(summary: favoriteSummary)
        }
    }

    private var topicSectionHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: AppSpacing.small) {
            Text(L10n.string("study.topic.section_title", "按主题学习"))
                .font(.system(size: AppFontSize.cardTitle, weight: .semibold))
                .foregroundStyle(AppTextColor.primary)

            Spacer(minLength: AppSpacing.small)

            NavigationLink {
                StudyTopicMapView()
            } label: {
                Text(L10n.string("study.topic.map.entry", "主题地图"))
                    .font(.system(size: AppFontSize.metadata, weight: .semibold))
                    .foregroundStyle(Color.orange)
            }
            .buttonStyle(.plain)

            Button(action: showCreateScene) {
                Text(L10n.string("study.topic.create_short", "+ 创建"))
                    .font(.system(size: AppFontSize.metadata, weight: .semibold))
                    .foregroundStyle(Color.orange)
                    .padding(.horizontal, AppSpacing.medium)
                    .frame(height: 32)
                    .background(AppSurfaceColor.card, in: RoundedRectangle(cornerRadius: AppCornerRadius.small, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: AppCornerRadius.small, style: .continuous)
                            .stroke(Color.orange, lineWidth: 1)
                    }
            }
            .buttonStyle(.plain)
        }
    }

    private var availableSceneTopics: [LearningTopic] {
        let assignedTopicIDs = Set(
            appModel.memories
                .flatMap(\.sentences)
                .flatMap(\.learningTopicIDs)
        )
        return LearningTopic.all.filter { assignedTopicIDs.contains($0.id) }
    }

    private func refreshSceneSuggestions() {
        let availableTopics = availableSceneTopics
        guard !availableTopics.isEmpty else {
            displayedSceneSuggestions = []
            return
        }

        var suggestions = Array(availableTopics.shuffled().prefix(3))

        // With more than three choices, avoid showing the exact same batch again.
        if availableTopics.count > 3,
           Set(suggestions) == Set(displayedSceneSuggestions),
           let replacement = availableTopics.first(where: { !displayedSceneSuggestions.contains($0) }) {
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

        return topicListCardContent(
            title: scene.name,
            summary: scene.summary,
            coverImage: coverImage,
            tint: tint
        )
    }

    private func topicListCardContent(
        title: String,
        summary: SentenceStudyTopicSummary,
        coverImage: UIImage?,
        tint: Color
    ) -> some View {
        HStack(spacing: AppSpacing.xLarge) {
            sceneCover(image: coverImage, tint: tint)

            VStack(alignment: .leading, spacing: AppSpacing.small) {
                Text(title)
                    .font(.system(size: AppFontSize.bodyProminent, weight: .regular))
                    .foregroundStyle(AppTextColor.primary)
                    .lineLimit(1)

                Text(
                    L10n.string(
                        "study.scene.detail.sentence_count",
                        "共 %d 句",
                        summary.totalCount
                    )
                )
                .font(.system(size: AppFontSize.metadata, weight: .medium))
                .foregroundStyle(AppTextColor.secondary)

                Spacer(minLength: 0)

                ProgressView(value: Double(summary.masteryScore), total: 100)
                    .tint(Color.orange)
                    .frame(maxWidth: 110)
                    .accessibilityLabel(
                        L10n.string(
                            "study.topic.mastery",
                            "掌握度 %d%%",
                            summary.masteryScore
                        )
                    )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(AppSpacing.medium)
        .frame(maxWidth: .infinity, minHeight: 100, maxHeight: 100, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous))
        .background(AppSurfaceColor.card, in: RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous))
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
        .frame(width: 120, height: 80)
        .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous))
        .allowsHitTesting(false)
    }

    private func favoriteStudyOverview(summary: SentenceStudyTopicSummary) -> some View {
        HStack(spacing: AppSpacing.large) {
            HStack(spacing: AppSpacing.medium) {
                StudyTopicOverviewMetric(
                    value: summary.dueCount,
                    label: L10n.string("study.metric.due_today", "今日待学")
                )

                Rectangle()
                    .fill(AppStroke.subtle)
                    .frame(width: 1, height: 34)

                StudyTopicOverviewMetric(
                    value: summary.reviewableTodayCount,
                    label: L10n.string("study.metric.studied_today", "今日已学")
                )
            }
            .padding(.leading, AppSpacing.xSmall)

            Spacer(minLength: 0)

            Button {
                Task { await startFavoriteStudy() }
            } label: {
                HStack(spacing: AppSpacing.small) {
                    if isStartingFavoriteStudy {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    }

                    Text(favoriteStudyButtonTitle)
                        .font(.system(size: AppFontSize.body, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, AppControlPadding.prominent)
                .frame(height: AppControlHeight.regular)
                .background(
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: canStartFavoriteStudy ? [
                                    Color(red: 0.98, green: 0.67, blue: 0.18),
                                    Color(red: 0.91, green: 0.52, blue: 0.17)
                                ] : [
                                    Color(red: 0.86, green: 0.79, blue: 0.72),
                                    Color(red: 0.82, green: 0.75, blue: 0.68)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )
            }
            .buttonStyle(.plain)
            .disabled(!canStartFavoriteStudy || isStartingFavoriteStudy)
        }
        .padding(.horizontal, AppSpacing.xLarge)
        .padding(.vertical, AppSpacing.medium)
        .background(
            RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            AppSurfaceColor.card,
                            AppSurfaceColor.elevated
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay {
            RoundedRectangle(cornerRadius: AppCornerRadius.large, style: .continuous)
                .stroke(AppStroke.highlight, lineWidth: 1)
        }
        .appCardShadow()
    }

    private var canStartFavoriteStudy: Bool {
        favoriteSummary.dueCount > 0 || favoriteSummary.reviewableTodayCount > 0
    }

    private var favoriteStudyButtonTitle: String {
        if isStartingFavoriteStudy {
            return L10n.string("study.button.preparing", "正在准备学习内容...")
        }
        if favoriteSummary.dueCount > 0 {
            return L10n.string("study.button.start", "开始学习")
        }
        if favoriteSummary.reviewableTodayCount > 0 {
            return L10n.string("study.button.review_again", "再学一遍")
        }
        return L10n.string("study.button.done_today", "今天学完了")
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

    private func showCreateScene() {
        guard appModel.isSignedIn else {
            appModel.isShowingSignInSheet = true
            return
        }
        newSceneName = ""
        selectedSuggestedTopicID = nil
        refreshSceneSuggestions()
        isShowingCreateScene = true
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
            let learningTopicID =
                selectedSuggestedTopicID ?? LearningTopic.topic(matchingName: name)?.id
            let scene = try await appModel.createUserStudyScene(
                named: name,
                learningTopicID: learningTopicID
            )
            isShowingCreateScene = false
            newSceneName = ""
            selectedSuggestedTopicID = nil
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

    @MainActor
    private func startFavoriteStudy() async {
        isStartingFavoriteStudy = true
        defer { isStartingFavoriteStudy = false }

        do {
            guard let session = try await appModel.loadSentenceStudyTopicSession(for: .favorites) else {
                errorMessage = L10n.string("study.topic.empty.action_hint", "这个主题暂时没有可学习的句子。")
                return
            }
            favoriteStudySession = session
        } catch {
            errorMessage = error.localizedDescription.isEmpty
                ? L10n.string("study.error.load_failed", "暂时无法加载学习内容，请稍后再试。")
                : error.localizedDescription
        }
    }
}

private struct StudyTopicOverviewMetric: View {
    let value: Int
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xSmall) {
            Text(value, format: .number)
            .font(.system(size: AppFontSize.stat, weight: .bold))
            .foregroundStyle(AppTextColor.title)
            .monospacedDigit()

            Text(label)
                .font(.system(size: AppFontSize.caption, weight: .medium))
                .foregroundStyle(AppTextColor.tertiary)
        }
        .frame(minWidth: 54, alignment: .leading)
    }
}

private enum StudyPageScrollMetrics {
    static let coordinateSpaceName = "study-page-scroll"
}

private struct StudyPageTitleMinYPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct CreateStudySceneSheet: View {
    @EnvironmentObject private var appModel: AppModel
    @Binding var sceneName: String
    @Binding var selectedSuggestedTopicID: String?
    @Binding var suggestedSceneNames: [LearningTopic]
    @FocusState private var isSceneNameFocused: Bool
    let isCreating: Bool
    let onRefreshSuggestions: () -> Void
    let onCreate: () async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.large) {
            HStack(spacing: AppSpacing.small) {
                if let selectedTopic = LearningTopic.topic(for: selectedSuggestedTopicID) {
                    HStack(spacing: AppSpacing.xSmall) {
                        Text(selectedTopic.title)
                            .font(.system(size: AppFontSize.body, weight: .medium))
                            .foregroundStyle(Color.orange)

                        Button {
                            selectedSuggestedTopicID = nil
                            sceneName = ""
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: AppIconSize.compact, weight: .bold))
                                .foregroundStyle(Color.orange.opacity(0.78))
                                .frame(width: 28, height: 28)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(
                            L10n.string(
                                "study.scene.remove_selected_suggestion",
                                "移除已选主题"
                            )
                        )
                    }
                    .padding(.leading, AppSpacing.medium)
                    .padding(.trailing, AppSpacing.xSmall)
                    .frame(height: 34)
                    .background(Color.orange.opacity(0.14), in: Capsule())

                    Spacer(minLength: 0)
                } else {
                    TextField(
                        L10n.string("study.scene.name_placeholder", "输入你想学习的主题"),
                        text: $sceneName
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($isSceneNameFocused)
                }
            }
            .padding(.horizontal, AppSpacing.medium)
            .frame(height: 50)
            .background(
                AppSurfaceColor.elevated,
                in: RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: AppCornerRadius.medium, style: .continuous)
                    .stroke(
                        selectedSuggestedTopicID != nil || isSceneNameFocused ? Color.orange.opacity(0.72) : AppStroke.soft,
                        lineWidth: selectedSuggestedTopicID != nil || isSceneNameFocused ? 1.5 : 1
                    )
            }

            if !suggestedSceneNames.isEmpty {
                VStack(alignment: .leading, spacing: AppSpacing.small) {
                    HStack(spacing: AppSpacing.small) {
                        Text(L10n.string("study.scene.suggestions_title", "试试这些"))
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
                        ForEach(suggestedSceneNames) { topic in
                            Button {
                                sceneName = topic.title
                                selectedSuggestedTopicID = topic.id
                                isSceneNameFocused = false
                            } label: {
                                Text(topic.title)
                                    .font(.system(size: AppFontSize.metadata, weight: .medium))
                                    .foregroundStyle(selectedSuggestedTopicID == topic.id ? Color.orange : AppTextColor.primary)
                                    .padding(.horizontal, AppSpacing.medium)
                                    .frame(height: 32)
                                    .background(
                                        selectedSuggestedTopicID == topic.id ? Color.orange.opacity(0.14) : AppSurfaceColor.secondaryFill,
                                        in: Capsule()
                                    )
                                    .overlay {
                                        Capsule()
                                            .stroke(selectedSuggestedTopicID == topic.id ? Color.orange.opacity(0.38) : AppStroke.subtle, lineWidth: 1)
                                    }
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint(L10n.string("study.scene.suggestion_fill_hint", "填入学习主题"))
                        }
                    }
                }
            }

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
        .onChange(of: learningTopicSignature) { _, _ in
            // The sheet can appear before the first remote-memory sync finishes.
            guard suggestedSceneNames.isEmpty else { return }
            onRefreshSuggestions()
        }
    }

    private var learningTopicSignature: [String] {
        appModel.memories
            .flatMap(\.sentences)
            .flatMap(\.learningTopicIDs)
            .sorted()
    }
}
